#!/usr/bin/env bash
# Shared helpers sourced by troubleshoot.sh and every check script.
# Keep this dependency-light: curl + jq only, matching the Dockerfile.

set -uo pipefail

# ---- output helpers -------------------------------------------------------
# Consistent [OK]/[WARN]/[CRIT]/[INFO]/[SKIP] prefixes across every check.
# A multi-line message (a literal newline embedded in the string) prints the
# colored bracket once, with continuation lines indented under it — pass one
# continued explanation as a single call rather than several back-to-back
# ones, which would render as unrelated observations instead.
_leveled() {
  local color="$1" label="$2" message="$3"
  local first=1 line
  while IFS= read -r line; do
    if [[ "$first" == 1 ]]; then
      printf "%b%s\033[0m %s\n" "$color" "$label" "$line"
      first=0
    else
      printf "       %s\n" "$line"
    fi
  done <<< "$message"
}

ok()   { _leveled "\033[32m" "[OK]  " "$*"; }
warn() { _leveled "\033[33m" "[WARN]" "$*"; }
crit() { _leveled "\033[31m" "[CRIT]" "$*"; }
info() { _leveled "\033[36m" "[INFO]" "$*"; }
step() { _leveled "\033[90m" "[..]  " "$*"; }

# skip <feature-name> <why-heredoc-text> <add-cmd> <remove-cmd>
# Renders the friendly "here's what you're missing, why, and how to add/
# remove it" block. This is the one function every locked-out check must
# call instead of erroring — see capability_check.sh for how gating works.
skip() {
  local feature="$1" why="$2" add_cmd="$3" remove_cmd="$4"
  printf "\n\033[2m🔒 %s\033[0m\n" "$feature"
  printf "   %s\n" "$why"
  printf "\n   To add it:\n     %s\n" "$add_cmd"
  printf "\n   To remove it later:\n     %s\n" "$remove_cmd"
}

# ---- HTTP helpers ----------------------------------------------------------

# http_get <url> [header...] -> prints body, returns curl's exit code
# 5s connect / 10s total timeout throughout — this tool should never hang.
http_get() {
  local url="$1"; shift
  local -a hdrs=()
  for h in "$@"; do hdrs+=(-H "$h"); done
  curl -fsS --connect-timeout 5 --max-time 10 "${hdrs[@]}" "$url" 2>/dev/null
}

# http_status <url> [header...] -> prints just the HTTP status code, "000" on failure
# Reads curl's own "000" via -w rather than appending `|| echo "000"`, which
# would double up to "000000" since curl already exits non-zero on failure.
http_status() {
  local url="$1"; shift
  local -a hdrs=()
  for h in "$@"; do hdrs+=(-H "$h"); done
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${hdrs[@]}" "$url" 2>/dev/null)
  echo "${code:-000}"
}

require_jq() {
  command -v jq >/dev/null 2>&1 || { crit "jq not found in image — this is a packaging bug, not a config issue"; exit 1; }
}
