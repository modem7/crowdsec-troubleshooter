#!/usr/bin/env bats
# wizard.sh runs on the host (not inside the container) and is mostly
# interactive prompts + `exec docker`, so it isn't a good fit for the
# run-and-check-exit-code pattern used elsewhere in this suite. Its main
# flow is guarded behind `[[ "${BASH_SOURCE[0]}" != "${0}" ]]` specifically
# so tests can `source` it and exercise the pure logic — compose parsing
# and default-resolution — directly, without needing docker installed or a
# TTY to answer prompts.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source wizard.sh
}

@test "sourcing wizard.sh does not require docker or trigger the interactive flow" {
  # setup() already sourced it without error — if the main flow's docker
  # guard or prompts had fired, setup itself would have failed the test.
  declare -F extract_service_block >/dev/null
}

@test "extract_service_block finds the crowdsec service by image and stops at the next service" {
  run extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$'
  [ "$status" -eq 0 ]
  [[ "$output" == *"crowdsec:"* ]]
  [[ "$output" == *'"19818:8080"'* ]]
  [[ "$output" != *"traefik-bouncer:"* ]]
}

@test "extract_service_block fails cleanly when no service matches" {
  run extract_service_block tests/fixtures/sample-compose.yml 'image:.*nonexistent-image'
  [ "$status" -ne 0 ]
}

@test "extract_yaml_list pulls ports out of a service block, quotes stripped" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$')"
  result="$(echo "$block" | extract_yaml_list ports)"
  [[ "$result" == *"19818:8080"* ]]
  [[ "$result" == *"16934:6060"* ]]
}

@test "extract_yaml_list strips a trailing unquoted # comment from an item" {
  result="$(printf 'ports:\n  - 8082:8080 # Dashboard\n  - 8083:8081 # Ping\n' | extract_yaml_list ports)"
  [ "$(echo "$result" | sed -n 1p)" = "8082:8080" ]
  [ "$(echo "$result" | sed -n 2p)" = "8083:8081" ]
}

@test "extract_yaml_list does not strip a literal # inside a quoted item" {
  result="$(printf 'labels:\n  - "traefik.some.label=value#notacomment"\n' | extract_yaml_list labels)"
  [ "$result" = "traefik.some.label=value#notacomment" ]
}

@test "extract_yaml_child_keys pulls network names from mapping-style networks:" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$')"
  result="$(echo "$block" | extract_yaml_child_keys networks)"
  [ "$result" = "pihole" ]
}

@test "extract_env_value reads a literal KEY=value from environment: list entries" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:.*traefik-crowdsec-bouncer')"
  result="$(echo "$block" | extract_env_value PORT)"
  [ "$result" = "8080" ]
}

@test "extract_label_value pulls a dotted Traefik label's value, quoted or not" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?traefik:')"
  labels="$(echo "$block" | extract_yaml_list labels)"
  result="$(echo "$labels" | extract_label_value 'traefik\.http\.routers\.traefik-rtr\.service')"
  [ "$result" = "api@internal" ]
}

@test "resolve_compose_vars substitutes \$VAR and \${VAR} from a matching .env file" {
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
DOMAINNAME=example.com
EOF
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "$tmpfile")"
  rm -f "$tmpfile"
  [ "$result" = "traefik.example.com" ]
}

@test "resolve_compose_vars strips a matching pair of double quotes around a .env value" {
  # Real bug: a user's actual .env had DOMAINNAME="modem7.com" (quoted,
  # valid Compose .env syntax) and the raw quotes rode straight through
  # into the suggested URL as https://traefik."modem7.com".
  tmpfile="$(mktemp)"
  echo 'DOMAINNAME="modem7.com"' > "$tmpfile"
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "$tmpfile")"
  rm -f "$tmpfile"
  [ "$result" = "traefik.modem7.com" ]
}

@test "resolve_compose_vars strips a matching pair of single quotes around a .env value" {
  tmpfile="$(mktemp)"
  echo "DOMAINNAME='modem7.com'" > "$tmpfile"
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "$tmpfile")"
  rm -f "$tmpfile"
  [ "$result" = "traefik.modem7.com" ]
}

@test "resolve_compose_vars leaves an unmatched/internal quote alone rather than mangling it" {
  tmpfile="$(mktemp)"
  echo 'DOMAINNAME=mo"dem7.com' > "$tmpfile"
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "$tmpfile")"
  rm -f "$tmpfile"
  [ "$result" = 'traefik.mo"dem7.com' ]
}

@test "resolve_compose_vars leaves the variable untouched when no .env is found" {
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "/does/not/exist/.env")"
  [ "$result" = 'traefik.$DOMAINNAME' ]
}

@test "resolve_compose_vars leaves the variable untouched when .env exists but has no matching key" {
  tmpfile="$(mktemp)"
  echo 'SOMETHING_ELSE=value' > "$tmpfile"
  result="$(resolve_compose_vars 'traefik.$DOMAINNAME' "$tmpfile")"
  rm -f "$tmpfile"
  [ "$result" = 'traefik.$DOMAINNAME' ]
}

@test "parse_compose finds the Traefik dashboard router via the api@internal label and suggests TRAEFIK_API_URL/TRAEFIK_DIRECT_URL" {
  declare -gA COMPOSE=()
  parse_compose tests/fixtures/sample-compose.yml >/dev/null
  # Depends on detect_host_ip() succeeding in whatever environment this
  # runs in: published-port form (host-ip:8082) if it does, the
  # internal-service-name fallback (traefik:8080) if it can't — both are
  # correct outcomes for their respective environment, so accept either
  # rather than asserting a specific host IP that varies by machine.
  [[ "${COMPOSE[TRAEFIK_API_URL]}" == http://*:8082 || "${COMPOSE[TRAEFIK_API_URL]}" == "http://traefik:8080" ]]
  [ "${COMPOSE[TRAEFIK_API_URL]}" = "${COMPOSE[TRAEFIK_DIRECT_URL]}" ]
}

@test "parse_compose suggests TRAEFIK_PROTECTED_URL from the dashboard router's Host() rule, left unresolved with no .env present" {
  declare -gA COMPOSE=()
  parse_compose tests/fixtures/sample-compose.yml >/dev/null
  # tests/fixtures/ has no .env, so $DOMAINNAME is expected to survive
  # unresolved — a clearer signal to fill it in by hand than a wrong guess.
  [ "${COMPOSE[TRAEFIK_PROTECTED_URL]}" = 'http://traefik.$DOMAINNAME' ]
}

@test "parse_compose still suggests TRAEFIK_API_URL without a dashboard router, but leaves PROTECTED/DIRECT unset rather than guessing" {
  tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.0
    labels:
      - "traefik.http.routers.traefik-rtr.rule=Host(`traefik.$DOMAINNAME`)"
    command:
      - --entryPoints.traefik.address=:8080
    ports:
      - 8082:8080
EOF
  declare -gA COMPOSE=()
  parse_compose "${tmpdir}/docker-compose.yml" >/dev/null
  rm -rf "$tmpdir"
  # No `service=api@internal` label — this tool can't confirm which router
  # is actually the dashboard, so it must not guess a security-check target.
  [[ "${COMPOSE[TRAEFIK_API_URL]}" == http://*:8082 || "${COMPOSE[TRAEFIK_API_URL]}" == "http://traefik:8080" ]]
  [ -z "${COMPOSE[TRAEFIK_PROTECTED_URL]:-}" ]
  [ -z "${COMPOSE[TRAEFIK_DIRECT_URL]:-}" ]
}

@test "parse_compose warns when the dashboard router has middlewares attached (auth/SSO likely blocks the API check)" {
  # Real-world case: a router bound only to public HTTPS entrypoints with
  # an SSO middleware in front of the dashboard. TRAEFIK_API_URL still
  # gets suggested (it's still the technically-correct address), but the
  # user needs to know check_bouncer_type.sh's Traefik-API confirmation
  # can't succeed through an auth-gated router — no URL fixes that.
  tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:latest
    command:
      - --entryPoints.https-int.address=:443
    ports:
      - 443:443
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-rtr.entrypoints=https-int"
      - "traefik.http.routers.traefik-rtr.rule=Host(`traefik.$DOMAINNAME`)"
      - "traefik.http.routers.traefik-rtr.service=api@internal"
      - "traefik.http.routers.traefik-rtr.middlewares=chain-authentik@file"
EOF
  declare -gA COMPOSE=()
  outfile="$(mktemp)"
  parse_compose "${tmpdir}/docker-compose.yml" > "$outfile"
  output="$(cat "$outfile")"
  rm -rf "$tmpdir" "$outfile"
  [[ "$output" == *"middlewares=chain-authentik@file"* ]]
  [[ "$output" == *"needs UNauthenticated access"* ]]
  [ -n "${COMPOSE[TRAEFIK_API_URL]:-}" ]
}

@test "parse_compose does not warn about middlewares when the dashboard router has none" {
  tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:latest
    command:
      - --entryPoints.traefik.address=:8080
    ports:
      - 8082:8080
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik-rtr.entrypoints=traefik"
      - "traefik.http.routers.traefik-rtr.rule=Host(`traefik.$DOMAINNAME`)"
      - "traefik.http.routers.traefik-rtr.service=api@internal"
EOF
  declare -gA COMPOSE=()
  output="$(parse_compose "${tmpdir}/docker-compose.yml")"
  rm -rf "$tmpdir"
  [[ "$output" != *"middlewares"* ]]
}

@test "parse_compose resolves \$DOMAINNAME and detects https scheme when a matching .env sits next to the compose file" {
  tmpdir="$(mktemp -d)"
  cat > "${tmpdir}/docker-compose.yml" <<'EOF'
services:
  traefik:
    image: traefik:v3.0
    labels:
      - "traefik.http.routers.traefik-rtr.rule=Host(`traefik.$DOMAINNAME`)"
      - "traefik.http.routers.traefik-rtr.entrypoints=https-int"
      - "traefik.http.routers.traefik-rtr.service=api@internal"
    command:
      - --entryPoints.https-int.address=:8080
    ports:
      - 8082:8080
EOF
  # Quoted on purpose, not DOMAINNAME=example.com — this is the actual
  # real-world shape (a real user's .env had it quoted) that originally
  # produced https://traefik."example.com" end to end through this exact
  # path before resolve_compose_vars stripped matching quote pairs.
  echo 'DOMAINNAME="example.com"' > "${tmpdir}/.env"
  declare -gA COMPOSE=()
  parse_compose "${tmpdir}/docker-compose.yml" >/dev/null
  rm -rf "$tmpdir"
  [ "${COMPOSE[TRAEFIK_PROTECTED_URL]}" = "https://traefik.example.com" ]
}

@test "resolve_default prefers an exported env var over a saved or compose value" {
  declare -gA PREV=([CROWDSEC_LAPI_URL]="http://from-file:1")
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  export CROWDSEC_LAPI_URL="http://from-env:3"
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  unset CROWDSEC_LAPI_URL
  [ "$result" = "http://from-env:3" ]
}

@test "resolve_default falls back to the saved file value when no env var is set" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=([CROWDSEC_LAPI_URL]="http://from-file:1")
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ "$result" = "http://from-file:1" ]
}

@test "resolve_default falls back to the compose suggestion when nothing else is set" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=()
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ "$result" = "http://from-compose:2" ]
}

@test "resolve_default returns empty when nothing is set anywhere" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=()
  declare -gA COMPOSE=()
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ -z "$result" ]
}

@test "json_escape escapes embedded quotes and backslashes" {
  result="$(json_escape 'pass"word\with\stuff')"
  [ "$result" = 'pass\"word\\with\\stuff' ]
}

@test "load_creds_file populates PREV from a KEY=VALUE env file, ignoring comments and blanks" {
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
# a comment
CROWDSEC_LAPI_URL=http://saved:8080

CROWDSEC_LAPI_KEY=abc123
EOF
  declare -gA PREV=()
  load_creds_file "$tmpfile"
  rm -f "$tmpfile"
  [ "${PREV[CROWDSEC_LAPI_URL]}" = "http://saved:8080" ]
  [ "${PREV[CROWDSEC_LAPI_KEY]}" = "abc123" ]
}

# detect_crowdsec_compose_file calls the real `docker` binary, which isn't
# assumed to be installed wherever these bats tests run — stubbed with a
# bash function of the same name rather than skipped, so the actual
# label-parsing/path-resolution logic still gets exercised. See the
# manual claude-vm verification (a real container, real labels, real
# `docker inspect`) in the commit/PR notes for the real-binary check this
# can't cover.

@test "detect_crowdsec_compose_file resolves a relative config_files path against working_dir" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/docker-compose.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec:v1.6.3\n' ;;
      # Single combined `docker inspect` call now (see
      # detect_crowdsec_compose_file's own comment for why) — the mock
      # returns both labels tab-separated in one line, matching the real
      # --format template's actual output shape (verified against a real
      # container, not assumed).
      inspect) printf '%s\tdocker-compose.yml\n' "$tmpdir" ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/docker-compose.yml" ]
}

@test "detect_crowdsec_compose_file accepts an absolute config_files path as-is" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/custom.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect) printf '/some/unrelated/dir\t%s/custom.yml\n' "$tmpdir" ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/custom.yml" ]
}

@test "detect_crowdsec_compose_file falls back to docker-compose.yml when config_files label is absent" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/docker-compose.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      # <no value> here specifically to keep covering that defensive
      # sentinel check, even though a real `index`-based template lookup
      # on a genuinely absent label renders as an empty string instead
      # (verified separately — see the next test down for that case).
      inspect) printf '%s\t<no value>\n' "$tmpdir" ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/docker-compose.yml" ]
}

@test "detect_crowdsec_compose_file fails cleanly when no crowdsec container is running" {
  docker() {
    case "$1" in
      ps) printf 'somethingelse\tnginx:latest\n' ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_crowdsec_compose_file fails cleanly when the container isn't Compose-managed (no working_dir label)" {
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      # Empty string, not "<no value>" — this is what a real `docker
      # inspect --format` with `index` actually renders for a genuinely
      # missing label (verified against a real container: dot-notation
      # produces "<no value>", `index` produces "").
      inspect) printf '\t\n' ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
}

@test "detect_crowdsec_compose_file fails cleanly when the resolved file isn't actually readable" {
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect) printf '/definitely/does/not/exist\tdocker-compose.yml\n' ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
}

@test "wizard.sh exits with a clear message when docker is missing from PATH" {
  # This is main-flow behavior, not a sourceable pure function (it's after
  # the return-guard), so it has to be exercised via a real subprocess
  # execution, not sourcing. A bare empty PATH also hides `bash` itself
  # from the outer shell's own lookup before it can even exec the script,
  # so build a minimal PATH with just bash symlinked in, deliberately
  # omitting docker.
  tmpbin="$(mktemp -d)"
  ln -s "$(command -v bash)" "${tmpbin}/bash"
  PATH="$tmpbin" run bash "${BATS_TEST_DIRNAME}/../wizard.sh"
  rm -rf "$tmpbin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required package(s): docker"* ]]
}
