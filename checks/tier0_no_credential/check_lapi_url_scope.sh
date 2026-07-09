#!/usr/bin/env bash
# check_lapi_url_scope.sh — Tier 0, no credential needed.
#
# A pure heuristic on CROWDSEC_LAPI_URL itself — something this tool already
# has by construction, no new access required. If the host component looks
# like a private-range LAN IP rather than a docker-compose service name,
# that's consistent with reaching LAPI via a host-published port rather than
# the internal docker network. Can't confirm from here whether that port is
# ALSO reachable from outside the LAN (that's a router/firewall fact, not
# visible to any container) — this only flags the pattern, not the exposure.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

host="$(echo "$CROWDSEC_LAPI_URL" | sed -E 's#^https?://##; s#[:/].*##')"

is_private_ip() {
  [[ "$1" =~ ^127\. ]] && return 0
  [[ "$1" =~ ^10\. ]] && return 0
  [[ "$1" =~ ^192\.168\. ]] && return 0
  [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_private_ip "$host"; then
  warn "CROWDSEC_LAPI_URL points at a LAN IP (${host}) rather than a docker-compose service name"
  info "This is consistent with reaching LAPI via a host-published port. If nothing outside this"
  info "docker network needs to reach LAPI directly, consider dropping the port publish and using"
  info "the internal service name instead (e.g. http://crowdsec:8080)."
  info "Note: this can't tell whether that port is also reachable from outside your LAN — just that"
  info "the pattern matches a published port rather than internal-only networking."
  exit 0
else
  ok "CROWDSEC_LAPI_URL looks like internal docker networking, not a published host port"
  exit 0
fi
