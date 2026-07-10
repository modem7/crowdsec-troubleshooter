#!/usr/bin/env bash
# check_lapi_url_scope.sh — Tier 0, no credential needed.
#
# A pure heuristic on CROWDSEC_LAPI_URL itself. If the host component looks
# like a private-range LAN IP or a DNS hostname rather than a docker-compose
# service name, that's consistent with reaching LAPI via a host-published
# port rather than the internal docker network. Can't confirm from here
# whether that port is ALSO reachable from outside the LAN (a router/
# firewall fact no container can see) — this only flags the pattern.
#
# Any host containing a "." that isn't itself a dotted-quad IPv4 literal is
# flagged too, not just LAN IPs — Compose's embedded DNS only resolves
# single-label service names, so a multi-label host (a local-DNS name like
# "nas.home") is never compose-internal.
#
# Known blind spot: a bare single-label LAN hostname with no dot (e.g.
# "nas") is syntactically identical to a compose service name, so this
# reports a false OK for that case — resolving it to check would need DNS
# introspection this tool deliberately doesn't do (see DESIGN.md).

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

host="$(sed -E 's#^https?://##; s#[:/].*##' <<<"$CROWDSEC_LAPI_URL")"

is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

is_private_ip() {
  [[ "$1" =~ ^127\. ]] && return 0
  [[ "$1" =~ ^10\. ]] && return 0
  [[ "$1" =~ ^192\.168\. ]] && return 0
  [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

# Doesn't suggest "use the internal service name instead" — that only
# resolves if this container joins crowdsec's own docker network, which
# isn't guessed here or true by default (see DESIGN.md).
warn_not_internal() {
  warn "CROWDSEC_LAPI_URL $1 rather than a docker-compose service name"
  info "This is consistent with reaching LAPI via a host-published port rather than internal
docker networking — expected and fine if anything outside crowdsec's own compose stack (this
troubleshooter included) needs to reach LAPI directly. Can't tell from here whether that port
is also reachable from outside your LAN — only that the pattern matches a published port."
}

if is_ipv4 "$host" && is_private_ip "$host"; then
  warn_not_internal "points at a LAN IP (${host})"
  exit 0
elif [[ "$host" == *.* ]] && ! is_ipv4 "$host"; then
  warn_not_internal "points at a DNS hostname (${host})"
  exit 0
else
  ok "CROWDSEC_LAPI_URL looks like internal docker networking, not a published host port"
  exit 0
fi
