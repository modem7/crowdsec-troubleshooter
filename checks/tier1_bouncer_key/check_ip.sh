#!/usr/bin/env bash
# check_ip.sh — Tier 1, needs a dedicated read-only bouncer key.
#
# THE BLOCK CHECKER. User supplies an IP, gets a plain-English answer. Uses
# GET /v1/decisions?ip=<ip> with X-Api-Key — the exact same read path every
# real bouncer already uses, no new API surface. Translates the raw JSON
# (scenario/origin/duration) into plain language, with a fallback to the raw
# scenario name for anything not in the lookup table below.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

usage() { echo "Usage: check_ip.sh <ip-address>"; exit 2; }
IP="${1:-}"
[[ -z "$IP" ]] && usage

if [[ "${HAS_BOUNCER_KEY:-false}" != true ]]; then
  skip "Checking a specific IP's ban status (the block checker)" \
    "Ban decisions are private to your server — CrowdSec won't hand them out to anyone who asks, so this needs its own small, read-only key. It can only read the ban list, nothing else." \
    "Run on your CrowdSec server: docker exec crowdsec cscli bouncers add troubleshooter-readonly — then set CROWDSEC_LAPI_KEY to the key it prints" \
    "Run on your CrowdSec server: docker exec crowdsec cscli bouncers delete troubleshooter-readonly — then unset CROWDSEC_LAPI_KEY"
  exit 0
fi

# Small, non-exhaustive lookup table — falls back to the raw scenario name
# for anything not listed here, never hides it.
translate_scenario() {
  case "$1" in
    *http-probing*)        echo "scanning for vulnerabilities" ;;
    *http-crawl-non_statics*) echo "aggressive/non-standard crawling" ;;
    *http-bad-user-agent*) echo "known malicious user agent" ;;
    *http-sensitive-files*) echo "probing for sensitive files (.env, .git, etc.)" ;;
    *ssh-bf*)               echo "repeated failed SSH logins" ;;
    *http-dos*)             echo "excessive request rate (possible DoS)" ;;
    *) echo "" ;;
  esac
}

translate_origin() {
  case "$1" in
    crowdsec) echo "detected by this CrowdSec instance" ;;
    CAPI)     echo "community blocklist (shared threat intelligence)" ;;
    cscli)    echo "manually added" ;;
    *)        echo "$1" ;;
  esac
}

response="$(http_get "${CROWDSEC_LAPI_URL}/v1/decisions?ip=${IP}" "X-Api-Key: ${CROWDSEC_LAPI_KEY}")"
status=$?

if [[ $status -ne 0 ]]; then
  crit "Couldn't reach LAPI to check ${IP} — check CROWDSEC_LAPI_KEY is still valid"
  exit 1
fi

echo ""
echo "Checking IP: ${IP}"
echo ""

if [[ -z "$response" || "$response" == "null" || "$response" == "[]" ]]; then
  ok "This IP is not currently banned"
  exit 0
fi

count="$(echo "$response" | jq 'length')"
for i in $(seq 0 $((count - 1))); do
  scenario="$(echo "$response" | jq -r ".[$i].scenario // \"unknown\"")"
  origin="$(echo "$response" | jq -r ".[$i].origin // \"unknown\"")"
  duration="$(echo "$response" | jq -r ".[$i].duration // \"unknown\"")"

  friendly="$(translate_scenario "$scenario")"
  origin_friendly="$(translate_origin "$origin")"

  warn "This IP is currently banned"
  if [[ -n "$friendly" ]]; then
    echo "   Reason: ${friendly} (${scenario})"
  else
    echo "   Reason: ${scenario}"
  fi
  echo "   Source: ${origin_friendly}"
  echo "   Duration: ${duration}"
done
exit 0
