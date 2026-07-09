#!/usr/bin/env bash
# check_direct_access_bypass.sh — Tier 0, no credential needed, fully optional.
#
# If given both the normal auth-gated URL and the raw internal address for
# the same backend, compares them. If the protected URL correctly challenges
# but the direct one serves content straight away, that proves the backend
# enforces no auth of its own — middleware-only protection, bypassable by
# anything that can reach the backend directly (a published port, a
# compromised sibling container, anything). Doesn't prove external exposure,
# but proves the actual root cause behind that class of finding.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

if [[ "${HAS_BYPASS_URLS:-false}" != true ]]; then
  skip "Checking whether a protected dashboard can be reached directly, bypassing auth" \
    "Needs two URLs for the same service: the normal one you'd use, and its raw internal address. No credential involved — just URLs." \
    "Set both TRAEFIK_PROTECTED_URL (e.g. https://traefik.example.com) and TRAEFIK_DIRECT_URL (e.g. http://traefik:8080)" \
    "Just unset both — nothing to clean up anywhere"
  exit 0
fi

protected_status="$(http_status "$TRAEFIK_PROTECTED_URL")"
direct_status="$(http_status "$TRAEFIK_DIRECT_URL")"

protected_challenged=false
[[ "$protected_status" =~ ^(401|403)$ || "$protected_status" =~ ^3[0-9][0-9]$ ]] && protected_challenged=true

if [[ "$protected_challenged" == true && "$direct_status" == "200" ]]; then
  crit "Backend at ${TRAEFIK_DIRECT_URL} serves content directly with no auth of its own"
  info "The protected route (${TRAEFIK_PROTECTED_URL}) correctly challenges (HTTP ${protected_status}),"
  info "but reaching the backend directly bypasses that entirely — auth is enforced only at the"
  info "router/middleware layer, not the backend. Anything that can reach ${TRAEFIK_DIRECT_URL} directly"
  info "(a published port, a compromised sibling container) walks straight past the protection."
  exit 1
elif [[ "$direct_status" != "200" ]]; then
  ok "Direct address (${TRAEFIK_DIRECT_URL}) did not serve content unauthenticated (HTTP ${direct_status})"
  exit 0
else
  info "Couldn't establish a clear comparison — protected URL returned HTTP ${protected_status}"
  exit 0
fi
