#!/usr/bin/env bash
# check_lapi_url_scope.sh — Tier 0, no credential needed.
#
# A pure heuristic on CROWDSEC_LAPI_URL itself — something this tool already
# has by construction, no new access required. If the host component looks
# like a private-range LAN IP, or a DNS hostname, rather than a
# docker-compose service name, that's consistent with reaching LAPI via a
# host-published port rather than the internal docker network. Can't
# confirm from here whether that port is ALSO reachable from outside the
# LAN (that's a router/firewall fact, not visible to any container) — this
# only flags the pattern, not the exposure.
#
# Dotted hostnames (e.g. any local-DNS name like "hda.home", "bob.home",
# "fred.local" — the pattern is the dot, not any specific name) were
# originally missed entirely — the IPv4-only regex let them fall through as
# a false "looks internal" OK. Fixed by also flagging any host containing a
# "." that isn't itself a dotted-quad IPv4 literal: Compose's embedded DNS
# only ever resolves single-label service names, so a multi-label host is
# never a compose-internal address regardless of whether it's a raw IP or a
# name.
#
# Known remaining blind spot, not fixable by this approach: a bare
# single-label LAN hostname with no dot at all (e.g. "nas", "docker-host")
# is syntactically identical to a compose service name — nothing in the
# string itself distinguishes them, so this heuristic reports a false OK
# for that case. Actually resolving the name and inspecting what answered
# would need DNS/network introspection this tool deliberately doesn't do
# (see DESIGN.md's "No docker.sock, ever" section) — left as an honest gap
# rather than a heuristic likely to misfire the other way.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

host="$(echo "$CROWDSEC_LAPI_URL" | sed -E 's#^https?://##; s#[:/].*##')"

is_ipv4() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

is_private_ip() {
  [[ "$1" =~ ^127\. ]] && return 0
  [[ "$1" =~ ^10\. ]] && return 0
  [[ "$1" =~ ^192\.168\. ]] && return 0
  [[ "$1" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

warn_not_internal() {
  warn "CROWDSEC_LAPI_URL $1 rather than a docker-compose service name"
  info "This is consistent with reaching LAPI via a host-published port. If nothing outside this"
  info "docker network needs to reach LAPI directly, consider dropping the port publish and using"
  info "the internal service name instead (e.g. http://crowdsec:8080)."
  info "Note: this can't tell whether that port is also reachable from outside your LAN — just that"
  info "the pattern matches a published port rather than internal-only networking."
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
