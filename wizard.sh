#!/usr/bin/env bash
# wizard.sh — interactive host-side helper for crowdsec-troubleshooter.
#
# Linux only (uses `hostname -I` / `ip route` for LAN-IP detection). Runs
# directly on the Docker host, NOT inside the troubleshooter's own --rm
# container: it needs a real TTY to prompt, and has to persist a
# credentials file across runs before `docker run` is ever invoked.
#
# Priority for every value it asks about: an exported env var wins, then a
# previously-saved value from the credentials file, then a
# docker-compose.yml-derived suggestion, then blank. Every prompt shows its
# resolved default; a blank Enter keeps it.
#
# Compose parsing is a best-effort regex/awk heuristic — it suggests
# values, never claims certainty, and degrades to asking normally on a
# failed parse.
#
# Safe to run as `curl -fsSL <raw-url>/wizard.sh | bash`: every prompt reads
# from /dev/tty explicitly rather than the script's own stdin, since piping
# into `bash` leaves stdin at EOF by the time a `read` runs. No controlling
# terminal at all (cron/CI) is caught explicitly below with one clear error.

set -uo pipefail

IMAGE_NAME="${WIZARD_IMAGE:-modem7/crowdsec-troubleshooter}"
CREDS_FILE="./.crowdsec-troubleshooter.env"
COMPOSE_FILE=""
ACTION=""
ACTION_ARG=""

usage() {
  cat <<'EOF'
Usage: wizard.sh [--file <credentials-file>] [--compose <docker-compose.yml>] [action]

Actions:
  wellness                  Tier-0 wellness check (default if omitted)
  check-ip <ip>              Look up an IP's ban status (needs a bouncer key)
  live-test <target-url>     Prove blocking works end-to-end (needs a machine credential)

Examples:
  ./wizard.sh
  ./wizard.sh --compose ./docker-compose.yml wellness
  ./wizard.sh check-ip 198.51.100.23
  ./wizard.sh live-test https://your-service.example.com

Re-run any time — values you've already entered are reused as defaults
from ./.crowdsec-troubleshooter.env (override the path with --file).
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) CREDS_FILE="$2"; shift 2 ;;
    --compose) COMPOSE_FILE="$2"; shift 2 ;;
    wellness) ACTION="wellness"; shift ;;
    check-ip) ACTION="check-ip"; ACTION_ARG="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    live-test) ACTION="live-test"; ACTION_ARG="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

# ---- output helpers — standalone, this runs on the host so it can't
# source lib/common.sh (that's built for inside the container) ----
note() { printf '\033[36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

# ---- prompt helpers ----
# `local -n` (nameref), not `printf -v "$1" ...`: shellcheck can trace a
# nameref assignment back to the caller's variable, avoiding false-positive
# SC2154 warnings at every call site.
prompt() {
  local -n __result="$1"
  local label="$2" default="$3"
  local input
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " input < /dev/tty
  else
    read -r -p "${label}: " input < /dev/tty
  fi
  __result="${input:-$default}"
}

# Hidden input for secrets. If a default already exists (from the shell
# env or a saved file), pressing Enter keeps it WITHOUT echoing it back —
# only a freshly typed value is ever shown as asterisk-free hidden input.
prompt_secret() {
  local -n __result="$1"
  local label="$2" default="$3"
  local input suffix="[hidden input; Enter for stdin]"
  [[ -n "$default" ]] && suffix="[press Enter to keep saved value, or type a new one, hidden]"
  read -r -s -p "${label} ${suffix}: " input < /dev/tty
  echo
  __result="${input:-$default}"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# ---- credentials file I/O ----
declare -A PREV=()
load_creds_file() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    PREV["$key"]="$value"
  done < "$file"
}

declare -A COMPOSE=()

# resolve_default <VARNAME> — env var > saved file value > compose
# suggestion > blank, in that order.
resolve_default() {
  # Two separate `local` statements, not one: bash evaluates an indirect
  # reference (${!var}) before `var` is in scope if both are declared in
  # the same `local` command, failing with "invalid indirect expansion".
  local var="$1"
  local env_val="${!var:-}"
  if [[ -n "$env_val" ]]; then echo "$env_val"; return; fi
  if [[ -n "${PREV[$var]:-}" ]]; then echo "${PREV[$var]}"; return; fi
  if [[ -n "${COMPOSE[$var]:-}" ]]; then echo "${COMPOSE[$var]}"; return; fi
  echo ""
}

# ---- host IP detection — turns a published-port suggestion into a usable
# URL. Best effort: falls back to leaving it blank for the user to fill in
# rather than guessing wrong. ----
detect_host_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
  fi
  echo "$ip"
}

# ---- compose-file auto-discovery via the running container itself ----
# Locates whichever container runs a crowdsecurity/crowdsec image (grep
# `docker ps` output for the image, never assume a container name), then
# reads the com.docker.compose.project.working_dir / .config_files labels
# Compose stamps on it. Prints nothing and returns 1 on any failure — the
# caller falls back to the existing cwd-guess-then-ask behavior.
detect_crowdsec_compose_file() {
  local container
  container="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | awk -F'\t' '$2 ~ /^crowdsecurity\/crowdsec(:|$)/ {print $1; exit}')"
  [[ -z "$container" ]] && return 1

  local working_dir
  working_dir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null)"
  [[ -z "$working_dir" || "$working_dir" == "<no value>" ]] && return 1

  # config_files can be a comma-separated list (multiple -f flags) and each
  # entry may be relative to working_dir or already absolute — take the
  # first one, falling back to the plain default filename if the label
  # itself isn't present (older Compose versions may not set it).
  local config_files first_file candidate
  config_files="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$container" 2>/dev/null)"
  first_file="${config_files%%,*}"

  if [[ -n "$first_file" && "$first_file" != "<no value>" ]]; then
    if [[ "$first_file" == /* ]]; then
      candidate="$first_file"
    else
      candidate="${working_dir}/${first_file}"
    fi
  else
    candidate="${working_dir}/docker-compose.yml"
  fi

  [[ -r "$candidate" ]] || return 1
  echo "$candidate"
}

# ---- docker-compose parsing helpers ----
# extract_service_block <file> <image-regex> — prints the full indented
# block for whichever service's `image:` line matches, by finding the
# nearest preceding same-or-lower-indent `key:` line as the block start,
# and the next such line as the block end. Fails (exit 1) if no match.
extract_service_block() {
  local file="$1" pattern="$2"
  awk -v pat="$pattern" '
    {
      line[NR] = $0
      n = match($0, /[^ ]/)
      indent = (n > 0) ? n - 1 : 0
      if ($0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/) {
        kc++
        key_line[kc] = NR
        key_indent[kc] = indent
      }
      if (!found && $0 ~ pat) { found = 1; found_line = NR }
    }
    END {
      if (!found) exit 1
      start = 1; start_indent = 0
      for (i = 1; i <= kc; i++) {
        if (key_line[i] < found_line) { start = key_line[i]; start_indent = key_indent[i] }
        else break
      }
      end = NR
      for (i = 1; i <= kc; i++) {
        if (key_line[i] > start && key_indent[i] <= start_indent) { end = key_line[i] - 1; break }
      }
      for (i = start; i <= end; i++) print line[i]
    }
  ' "$file"
}

# extract_yaml_list <key> — reads a block on stdin, prints `- item` list
# entries under <key>: (e.g. ports:), quotes stripped. Trailing ` #comment`
# is stripped for unquoted items only — a quoted value (a Traefik label's
# rule) may legitimately contain a literal `#`, and stripping there would
# corrupt it. Compose files commenting published ports (`8082:8080 #
# Dashboard`) are common enough that this matters for port matching.
extract_yaml_list() {
  local key="$1"
  awk -v key="$key" '
    BEGIN { collecting = 0 }
    {
      n = match($0, /[^ ]/)
      indent = (n > 0) ? n - 1 : 0
      if ($0 ~ ("^[[:space:]]*" key ":[[:space:]]*$")) { collecting = 1; key_indent = indent; next }
      if (collecting) {
        if ($0 ~ /^[[:space:]]*-[[:space:]]/ && indent > key_indent) {
          item = $0
          sub(/^[[:space:]]*-[[:space:]]*/, "", item)
          if (item !~ /^"/) { sub(/[[:space:]]+#.*$/, "", item) }
          gsub(/^"+|"+$/, "", item)
          print item
        } else if (indent <= key_indent && $0 !~ /^[[:space:]]*$/) {
          collecting = 0
        }
      }
    }
  '
}

# extract_yaml_child_keys <key> — reads a block on stdin, prints the
# immediate child key names under <key>: for mapping-style YAML (e.g.
# `networks:` with per-network config, not a plain `- name` list).
extract_yaml_child_keys() {
  local key="$1"
  awk -v key="$key" '
    BEGIN { collecting = 0; child_indent = -1 }
    {
      n = match($0, /[^ ]/)
      indent = (n > 0) ? n - 1 : 0
      if ($0 ~ ("^[[:space:]]*" key ":[[:space:]]*$")) { collecting = 1; key_indent = indent; next }
      if (collecting) {
        if (indent <= key_indent && $0 !~ /^[[:space:]]*$/) { collecting = 0; next }
        if (child_indent == -1 && $0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+:/) child_indent = indent
        if (indent == child_indent && $0 ~ /^[[:space:]]*[A-Za-z0-9_.-]+:/) {
          k = $0
          sub(/^[[:space:]]*/, "", k)
          sub(/:.*/, "", k)
          print k
        }
      }
    }
  '
}

# extract_env_value <key> — reads a block on stdin, prints the value of a
# literal `- KEY=value` line under environment: (skips ${VAR}-style refs
# implicitly, since those aren't resolvable from the compose file alone).
extract_env_value() {
  local key="$1"
  grep -oE "^[[:space:]]*-?[[:space:]]*${key}=[^ #]*" | sed -E "s/^[[:space:]]*-?[[:space:]]*${key}=//" | head -1
}

# extract_label_value <label-key-regex> — reads label lines on stdin (one
# per line, already quote-stripped by extract_yaml_list labels), prints the
# value after the first '=' for the first line whose key matches. Traefik
# labels are dotted (traefik.http.routers.<name>.rule=...), so the caller
# passes a regex with dots escaped rather than a plain key.
extract_label_value() {
  local key_regex="$1"
  # `|| true`: no matching label is a normal outcome here, but under
  # pipefail that grep's exit 1 becomes this pipeline's status, which would
  # trip `set -e` in a caller that has it enabled (e.g. a bats test body).
  grep -E "^${key_regex}=" | sed -E "s/^${key_regex}=//" | head -1 || true
}

# resolve_compose_vars <text> <env-file> — substitutes $VAR/${VAR}
# references in <text> using values found in <env-file> (Compose's own
# convention: a .env file in the same directory as the compose file,
# auto-loaded by `docker compose` itself, not something this tool invents).
# Anything not found in the file is left exactly as-is — an unresolved
# `$DOMAINNAME` in a suggested URL is a clearer, more honest signal to fill
# it in by hand than silently guessing a value would be.
resolve_compose_vars() {
  local text="$1" env_file="$2"
  [[ -r "$env_file" ]] || { echo "$text"; return; }
  local var val result="$text"
  for var in $(echo "$text" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | tr -d '${}' | sort -u || true); do
    val="$(grep -E "^${var}=" "$env_file" | head -1 | sed -E "s/^${var}=//" || true)"
    [[ -z "$val" ]] && continue
    # A .env value is often quoted (DOMAINNAME="example.com") — valid
    # Compose .env syntax, which Compose itself strips before substitution.
    # Only strips a pair that wraps the whole value; a stray or internal
    # quote is left alone.
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then
      val="${val#\"}"; val="${val%\"}"
    elif [[ "$val" == \'*\' && "$val" == *\' ]]; then
      val="${val#\'}"; val="${val%\'}"
    fi
    result="${result//\$\{${var}\}/$val}"
    result="${result//\$${var}/$val}"
  done
  echo "$result"
}

parse_compose() {
  local file="$1"
  [[ -r "$file" ]] || { warn "Can't read compose file: $file"; return 1; }

  local host_ip; host_ip="$(detect_host_ip)"
  [[ -z "$host_ip" ]] && warn "Couldn't auto-detect this host's LAN IP (hostname -I / ip route both came up empty) — published-port suggestions below will be incomplete; fill the host part in yourself."

  local cs_block
  if cs_block="$(extract_service_block "$file" 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$')"; then
    note "Found a crowdsecurity/crowdsec service in ${file}"
    local ports lapi_port metrics_port svc_name
    ports="$(echo "$cs_block" | extract_yaml_list ports)"
    lapi_port="$(echo "$ports" | awk -F: '$2==8080 {print $1}' | head -1)"
    metrics_port="$(echo "$ports" | awk -F: '$2==6060 {print $1}' | head -1)"
    svc_name="$(echo "$cs_block" | head -1 | sed -E 's/^[[:space:]]*//; s/:.*//')"

    if [[ -n "$lapi_port" && -n "$host_ip" ]]; then
      COMPOSE[CROWDSEC_LAPI_URL]="http://${host_ip}:${lapi_port}"
    elif [[ -n "$lapi_port" ]]; then
      warn "Found LAPI's published port (${lapi_port}) but couldn't detect this host's LAN IP — no suggestion to offer, fill in http://<this-host-ip>:${lapi_port} yourself"
    else
      COMPOSE[CROWDSEC_LAPI_URL]="http://${svc_name}:8080"
      warn "No published port found for the crowdsec service (port 8080 isn't in its ports: list) — suggesting the internal service name instead. That only resolves if this wizard's docker run joins the same docker network: pass --network ${svc_name%%[!a-zA-Z0-9_.-]*} manually, or edit the printed command before it runs."
    fi

    if [[ -n "$metrics_port" && -n "$host_ip" ]]; then
      COMPOSE[CROWDSEC_METRICS_URL]="http://${host_ip}:${metrics_port}"
    fi

    local nets
    nets="$(echo "$cs_block" | extract_yaml_child_keys networks)"
    [[ -n "$nets" ]] && note "crowdsec is attached to docker network(s): $(echo "$nets" | tr '\n' ' ')"
  else
    warn "No crowdsecurity/crowdsec service found in ${file} — nothing to auto-detect from it. Double check the image: line matches (tags/comments can throw simple pattern matching off)."
  fi

  local tb_block
  if tb_block="$(extract_service_block "$file" 'image:.*traefik-crowdsec-bouncer')"; then
    note "Found a Traefik bouncer service in ${file}"
    local ports host_port svc_name internal_port
    ports="$(echo "$tb_block" | extract_yaml_list ports)"
    host_port="$(echo "$ports" | head -1 | cut -d: -f1)"
    svc_name="$(echo "$tb_block" | head -1 | sed -E 's/^[[:space:]]*//; s/:.*//')"
    internal_port="$(echo "$tb_block" | extract_env_value PORT)"
    internal_port="${internal_port:-8080}"
    if [[ -n "$host_port" && -n "$host_ip" ]]; then
      COMPOSE[TRAEFIK_BOUNCER_URL]="http://${host_ip}:${host_port}"
    else
      COMPOSE[TRAEFIK_BOUNCER_URL]="http://${svc_name}:${internal_port}"
    fi
  fi

  if extract_service_block "$file" 'image:.*crowdsecurity/cloudflare-worker-bouncer' >/dev/null 2>&1; then
    note "Found a Cloudflare Worker bouncer service — this tool has no check tied to it yet, nothing to configure there."
  fi

  # `image: traefik:` (with the colon) specifically, not
  # `traefik-crowdsec-bouncer` — that one's already handled above as a
  # completely different service.
  local tf_block
  if tf_block="$(extract_service_block "$file" 'image:[[:space:]]*"?traefik:')"; then
    note "Found a Traefik service in ${file}"
    local svc_name ports cmds labels
    svc_name="$(echo "$tf_block" | head -1 | sed -E 's/^[[:space:]]*//; s/:.*//')"
    ports="$(echo "$tf_block" | extract_yaml_list ports)"
    cmds="$(echo "$tf_block" | extract_yaml_list command)"
    labels="$(echo "$tf_block" | extract_yaml_list labels)"

    # The dashboard/API router is identifiable by Traefik's own convention
    # regardless of what the operator named it: whichever router's
    # `service=` points at the special built-in `api@internal` service IS
    # the dashboard. Everything else in this file (arbitrary app routers)
    # is too ambiguous to guess a security-check target from safely.
    local dash_router=""
    # `|| true`: no dashboard router is a normal outcome (most compose files
    # won't have one) — same pipefail/set -e concern as extract_label_value.
    dash_router="$(echo "$labels" | grep -E '\.service=api@internal$' | sed -E 's/^traefik\.http\.routers\.([^.]+)\.service=api@internal$/\1/' | head -1 || true)"

    local api_port=""
    if [[ -n "$dash_router" ]]; then
      local entrypoints_label first_ep rule host_expr scheme resolved_host env_file dash_middlewares
      entrypoints_label="$(echo "$labels" | extract_label_value "traefik\\.http\\.routers\\.${dash_router}\\.entrypoints")"
      first_ep="${entrypoints_label%%,*}"
      if [[ -n "$first_ep" ]]; then
        api_port="$(echo "$cmds" | grep -iE "^--entrypoints\\.${first_ep}\\.address=" | sed -E 's/.*:([0-9]+).*/\1/' | head -1 || true)"
      fi

      # A dashboard router with an auth/SSO middleware attached (a common
      # hardening pattern) means check_bouncer_type.sh's unauthenticated
      # API confirmation can never succeed through it, regardless of which
      # URL is suggested — worth flagging rather than suggesting a URL
      # that's fated to fail.
      dash_middlewares="$(echo "$labels" | extract_label_value "traefik\\.http\\.routers\\.${dash_router}\\.middlewares")"
      if [[ -n "$dash_middlewares" ]]; then
        warn "Dashboard router '${dash_router}' has middlewares=${dash_middlewares} attached (auth/SSO?) — check_bouncer_type.sh's Traefik-API confirmation needs UNauthenticated access, so it likely can't succeed through this router regardless of which URL is used. Only relevant if you rely on that specific check; everything else in this tool is unaffected."
      fi

      rule="$(echo "$labels" | extract_label_value "traefik\\.http\\.routers\\.${dash_router}\\.rule")"
      if [[ "$rule" == *"Host("* ]]; then
        host_expr="$(echo "$rule" | sed -E 's/.*Host\(`?([^`)]*)`?\).*/\1/')"
        env_file="$(dirname "$file")/.env"
        resolved_host="$(resolve_compose_vars "$host_expr" "$env_file")"
        scheme="http"; [[ "$first_ep" == *https* ]] && scheme="https"
        COMPOSE[TRAEFIK_PROTECTED_URL]="${scheme}://${resolved_host}"
        if [[ "$resolved_host" == *'$'* ]]; then
          warn "TRAEFIK_PROTECTED_URL suggestion (${scheme}://${resolved_host}) still has an unresolved variable — no .env found next to ${file} with a matching value (or it's set some other way: shell export, host env, a different .env location). Fill it in by hand."
        fi
      fi
    else
      note "No dashboard router (service=api@internal label) found in the Traefik service — TRAEFIK_PROTECTED_URL/TRAEFIK_DIRECT_URL need a specific target this tool can't guess safely, skipping both."
    fi
    api_port="${api_port:-8080}"

    # TRAEFIK_API_URL and TRAEFIK_DIRECT_URL share the same address on
    # purpose: one confirms the plugin bouncer is registered, the other is
    # what TRAEFIK_PROTECTED_URL gets compared against for the auth-bypass
    # check. Always http:// — this is the container's own internal
    # listener, never TLS-wrapped, regardless of the public router's scheme.
    local api_host_port
    api_host_port="$(echo "$ports" | awk -F: -v p="$api_port" '$2==p {print $1}' | head -1)"
    if [[ -n "$api_host_port" && -n "$host_ip" ]]; then
      COMPOSE[TRAEFIK_API_URL]="http://${host_ip}:${api_host_port}"
      if [[ -n "$dash_router" ]]; then COMPOSE[TRAEFIK_DIRECT_URL]="http://${host_ip}:${api_host_port}"; fi
    else
      COMPOSE[TRAEFIK_API_URL]="http://${svc_name}:${api_port}"
      if [[ -n "$dash_router" ]]; then COMPOSE[TRAEFIK_DIRECT_URL]="http://${svc_name}:${api_port}"; fi
      if [[ -z "$api_host_port" ]]; then warn "No published port found for Traefik's API/dashboard port (${api_port}) — suggesting the internal service name instead. That only resolves if this wizard's docker run joins the same docker network."; fi
    fi
  fi
  # Explicit return: guarantees success regardless of which branch above ran
  # last, rather than leaking whatever that branch's final statement happened
  # to exit with (same class of bug as troubleshoot.sh's tier_status tracking).
  return 0
}

# ---------------------------------------------------------------------
# main flow — guarded so tests can `source` this file to exercise the pure
# helper functions above without triggering interactive prompts or
# requiring docker to be installed on the test machine.
#
# `(return 0 2>/dev/null)` rather than a BASH_SOURCE[0]-vs-$0 comparison:
# when bash reads this script from stdin (`curl ... | bash`), BASH_SOURCE
# has zero elements, which is a hard crash under `set -u` if indexed
# directly, and comparing "" to $0 ("bash" in that mode) would also
# misdetect curl|bash as "sourced". `return` is only legal inside a
# function or a sourced script in any invocation mode, so probing that
# directly in a subshell works regardless.
# ---------------------------------------------------------------------
if (return 0 2>/dev/null); then
  return 0
fi

# wizard.sh itself launches the troubleshooter container, so docker is
# required even when the CrowdSec being checked runs bare-metal. Checked as
# a list so a future dependency reports alongside it in one message.
REQUIRED_CMDS=(docker)
missing_cmds=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || missing_cmds+=("$cmd")
done
if [[ ${#missing_cmds[@]} -gt 0 ]]; then
  echo "Missing required package(s): ${missing_cmds[*]}"
  echo "This wizard launches the troubleshooter container for you (docker run ...), so"
  echo "these need to be installed and reachable first — even when the CrowdSec you're"
  echo "checking runs bare-metal, this tool itself is still a Docker image."
  exit 1
fi

# If there's no controlling terminal at all (invoked from cron/CI), fail
# once, clearly, here — rather than every individual `read` below failing
# with a cryptic "No such device".
{ exec 3< /dev/tty; } 2>/dev/null || {
  echo "wizard.sh needs an interactive terminal to prompt for values (couldn't open /dev/tty)."
  echo "Running from a non-interactive context like cron or CI? Set the CROWDSEC_* env vars"
  echo "directly and run 'docker run' against the image yourself instead — see README.md."
  exit 1
}
exec 3<&-

echo "crowdsec-troubleshooter setup wizard"
echo "─────────────────────────────────────"

if [[ -z "$ACTION" ]]; then
  echo "What do you want to run?"
  PS3="Choice: "
  select choice in "Wellness check (tier 0)" "check-ip <ip>" "live-test <target-url>"; do
    case "$choice" in
      "Wellness check (tier 0)") ACTION="wellness"; break ;;
      "check-ip <ip>") ACTION="check-ip"; prompt ACTION_ARG "IP address to check" ""; break ;;
      "live-test <target-url>") ACTION="live-test"; prompt ACTION_ARG "Target URL to test blocking against" ""; break ;;
      *) echo "Pick 1, 2, or 3." ;;
    esac
  done < /dev/tty
fi

load_creds_file "$CREDS_FILE"
[[ -f "$CREDS_FILE" ]] && note "Loaded saved values from ${CREDS_FILE}"

if [[ -z "$COMPOSE_FILE" ]]; then
  default_compose=""
  # Try to actually find it before just asking: locate the running
  # crowdsec container and read Compose's own working_dir/config_files
  # labels off it — far more likely to be right than guessing from cwd,
  # since it reflects what's actually running rather than where this
  # wizard happens to have been launched from. Falls straight through to
  # the cwd guess (existing behavior) on any failure.
  if default_compose="$(detect_crowdsec_compose_file)"; then
    note "Found the running crowdsec container's own compose file: ${default_compose}"
  elif [[ -f ./docker-compose.yml ]]; then
    default_compose="./docker-compose.yml"
  elif [[ -f ./docker-compose.yaml ]]; then
    default_compose="./docker-compose.yaml"
  fi
  if [[ -n "$default_compose" ]]; then
    # A non-empty default means blank Enter always accepts it — that leaves
    # no way to decline a compose file that just happens to be sitting in
    # this directory, so 'skip'/'none' are explicit escape hatches rather
    # than relying on an empty answer to mean "don't use it".
    prompt COMPOSE_FILE "Found ${default_compose} — use it to suggest values? Enter to accept, type a different path, or 'skip'" "$default_compose"
    [[ "$COMPOSE_FILE" == "skip" || "$COMPOSE_FILE" == "none" ]] && COMPOSE_FILE=""
  else
    prompt COMPOSE_FILE "Path to a docker-compose.yml to auto-detect values from (blank to skip)" ""
  fi
fi
[[ -n "$COMPOSE_FILE" ]] && parse_compose "$COMPOSE_FILE"

declare -A NEW=()

# Vars below are assigned by prompt()/prompt_secret() via nameref; static
# analysis doesn't always trace that, hence the disable comments below.
prompt lapi_url "CROWDSEC_LAPI_URL" "$(resolve_default CROWDSEC_LAPI_URL)"
# shellcheck disable=SC2154
NEW[CROWDSEC_LAPI_URL]="$lapi_url"

case "$ACTION" in
  wellness)
    prompt metrics_url "CROWDSEC_METRICS_URL (blank lets the tool guess from the LAPI port — only reliable if they share one)" "$(resolve_default CROWDSEC_METRICS_URL)"
    [[ -n "$metrics_url" ]] && NEW[CROWDSEC_METRICS_URL]="$metrics_url"

    prompt want_traefik "Configure optional Traefik checks too (bouncer-type ID, auth-bypass check)? [y/N]" "N"
    # shellcheck disable=SC2154
    if [[ "$want_traefik" =~ ^[Yy] ]]; then
      prompt tb_url "TRAEFIK_BOUNCER_URL (blank to skip)" "$(resolve_default TRAEFIK_BOUNCER_URL)"
      [[ -n "$tb_url" ]] && NEW[TRAEFIK_BOUNCER_URL]="$tb_url"
      prompt ta_url "TRAEFIK_API_URL (blank to skip)" "$(resolve_default TRAEFIK_API_URL)"
      [[ -n "$ta_url" ]] && NEW[TRAEFIK_API_URL]="$ta_url"
      prompt tp_url "TRAEFIK_PROTECTED_URL (blank to skip the auth-bypass check)" "$(resolve_default TRAEFIK_PROTECTED_URL)"
      if [[ -n "$tp_url" ]]; then
        NEW[TRAEFIK_PROTECTED_URL]="$tp_url"
        prompt td_url "TRAEFIK_DIRECT_URL" "$(resolve_default TRAEFIK_DIRECT_URL)"
        # shellcheck disable=SC2154
        NEW[TRAEFIK_DIRECT_URL]="$td_url"
      fi
    fi
    ;;

  check-ip)
    [[ -z "$ACTION_ARG" ]] && prompt ACTION_ARG "IP address to check" ""
    prompt_secret lapi_key "CROWDSEC_LAPI_KEY (read-only bouncer key)" "$(resolve_default CROWDSEC_LAPI_KEY)"
    # shellcheck disable=SC2154
    NEW[CROWDSEC_LAPI_KEY]="$lapi_key"
    ;;

  live-test)
    [[ -z "$ACTION_ARG" ]] && prompt ACTION_ARG "Target URL to test blocking against" ""
    prompt host_creds_path "Path to your machine credentials JSON (blank to create one now)" "${PREV[_MACHINE_CREDS_HOST_PATH]:-}"
    if [[ -z "$host_creds_path" ]]; then
      note "On your CrowdSec server, run: docker exec crowdsec cscli machines add troubleshooter --auto -f -"
      note "The -f - avoids colliding with /etc/crowdsec/local_api_credentials.yaml (crowdsec's own engine already uses that path) and prints a Login/Password pair — enter them below (see setup/register_machine.sh for the full explanation)."
      prompt m_login "Machine login" ""
      prompt_secret m_password "Machine password" ""
      prompt host_creds_path "Save the credentials JSON to" "./.crowdsec-machine.json"
      # shellcheck disable=SC2154
      printf '{"login": "%s", "password": "%s"}\n' "$(json_escape "$m_login")" "$(json_escape "$m_password")" > "$host_creds_path"
      chmod 600 "$host_creds_path"
      note "Saved to ${host_creds_path} (chmod 600)"
    fi
    NEW[_MACHINE_CREDS_HOST_PATH]="$host_creds_path"
    ;;
esac

# ---- save credentials file ----
{
  for key in "${!NEW[@]}"; do
    case "$key" in
      CROWDSEC_*|TRAEFIK_*|_MACHINE_CREDS_HOST_PATH) echo "${key}=${NEW[$key]}" ;;
    esac
  done
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
note "Saved to ${CREDS_FILE} (chmod 600). Add it to .gitignore if this directory is a git repo — it can contain a bouncer key or a machine credential path."

# ---- build and launch the actual docker run ----
DOCKER_ARGS=(run --rm)
for key in "${!NEW[@]}"; do
  case "$key" in
    CROWDSEC_*|TRAEFIK_*) DOCKER_ARGS+=(-e "${key}=${NEW[$key]}") ;;
  esac
done

if [[ "$ACTION" == "live-test" ]]; then
  host_path="${NEW[_MACHINE_CREDS_HOST_PATH]}"
  host_path_abs="$(cd "$(dirname "$host_path")" 2>/dev/null && pwd)/$(basename "$host_path")"
  container_path="/creds/$(basename "$host_path")"
  DOCKER_ARGS+=(-e "CROWDSEC_MACHINE_CREDENTIALS_FILE=${container_path}")
  DOCKER_ARGS+=(-v "${host_path_abs}:${container_path}:ro")
fi

DOCKER_ARGS+=("$IMAGE_NAME")
case "$ACTION" in
  check-ip) DOCKER_ARGS+=(check-ip "$ACTION_ARG") ;;
  live-test) DOCKER_ARGS+=(live-test --target-url "$ACTION_ARG") ;;
esac

# Pull before running so this always exercises the latest published image
# rather than whatever stale copy happened to already be on disk — the
# whole point of running via the wizard instead of a hand-typed `docker
# run` that people forget to re-pull for. A failed pull degrades to a
# warning, not a hard stop: WIZARD_IMAGE may point at a local-only tag
# (e.g. a test build) that was never meant to be pulled from a registry.
if [[ "${WIZARD_SKIP_PULL:-}" != "1" ]]; then
  note "Pulling ${IMAGE_NAME}..."
  if ! docker pull "$IMAGE_NAME"; then
    warn "Couldn't pull ${IMAGE_NAME} — continuing with whatever local copy exists, if any"
    note "Set WIZARD_SKIP_PULL=1 to skip the pull step entirely, e.g. for a local-only image"
  fi
fi

echo
note "Running: docker ${DOCKER_ARGS[*]}"
echo
exec docker "${DOCKER_ARGS[@]}"
