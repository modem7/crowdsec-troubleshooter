#!/usr/bin/env bash
# check_traefik_plugin.sh — optional, separate integration surface from LAPI.
#
# The only real way to positively confirm the modern Traefik plugin bouncer
# is in use, since it runs in-process inside Traefik with no separate
# service to fingerprint the way the legacy ForwardAuth bouncer has. Queries
# Traefik's own API (api@internal) for a registered middleware whose plugin
# module references crowdsec-bouncer-traefik-plugin.
#
# This is deliberately opt-in and separate from anything CrowdSec-specific —
# using it means this tool now also needs to know about Traefik, not just
# CrowdSec's LAPI. Flagged clearly rather than silently bundled in.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"
require_jq

if [[ "${HAS_TRAEFIK_API:-false}" != true ]]; then
  skip "Confirming the modern Traefik plugin bouncer is registered (vs. just not finding the legacy one)" \
    "This is a genuinely different check than anything else here — it asks Traefik's own API, not CrowdSec's. Only useful if you want positive confirmation rather than absence-of-evidence." \
    "Set TRAEFIK_API_URL to Traefik's internal API address, e.g. http://traefik:8080 (requires --api.dashboard=true on Traefik)" \
    "Just unset TRAEFIK_API_URL — nothing to clean up, this never writes anything"
  exit 0
fi

middlewares="$(http_get "${TRAEFIK_API_URL}/api/http/middlewares" 2>/dev/null)"

if [[ -z "$middlewares" ]]; then
  warn "Couldn't reach Traefik's API at ${TRAEFIK_API_URL}/api/http/middlewares"
  exit 1
fi

if echo "$middlewares" | jq -e '.[] | select(.plugin != null) | .provider // "" | test("crowdsec"; "i")' >/dev/null 2>&1; then
  ok "Modern Traefik plugin bouncer detected — this is the current recommended approach"
  exit 0
else
  info "No crowdsec plugin middleware found registered in Traefik"
  info "Combined with no legacy bouncer fingerprint either, this suggests no Traefik-level bouncer is active"
  exit 0
fi
