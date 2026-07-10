#!/usr/bin/env bash
# check_bouncer_type.sh — Tier 0, no credential needed.
#
# Identifies which Traefik bouncer type is in use, however it's implemented:
#
# - Legacy ForwardAuth-style bouncer (fbonalair/freifunkmuc forks) — a
#   separate service with its own /api/v1/ping endpoint, fingerprinted
#   directly, NOT via LAPI. This never touches LAPI's bouncer registry at
#   all: cscli's bouncer list/add/delete commands hit CrowdSec's database
#   directly, not an HTTP endpoint, so that data isn't reachable over the
#   network regardless of credential tier. This works around that by
#   asking the bouncer itself instead.
# - Modern Traefik plugin bouncer — runs in-process inside Traefik with no
#   separate service to probe at all, so confirming it means asking
#   Traefik's own API (api@internal) for a registered middleware whose
#   plugin module references crowdsec-bouncer-traefik-plugin instead.
#
# These used to be two entirely separate checks (this file, plus
# checks/optional_traefik_api/check_traefik_plugin.sh) on the theory that
# querying Traefik's own API is a genuinely different integration surface
# from anything CrowdSec-specific. True, but that separation had a real
# cost: checks/optional_traefik_api/ was never actually wired into
# troubleshoot.sh's tier0 sweep, so the plugin-bouncer check silently never
# ran for anyone — TRAEFIK_API_URL was collected by wizard.sh and exported
# into the container, but nothing ever consumed it. Merged into one check
# so both bouncer types get the same automatic, always-attempted coverage,
# since the plugin bouncer is CrowdSec's current recommended approach and
# deserves first-class detection, not a footnote nobody could reach.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

if [[ "${HAS_BOUNCER_URL:-false}" != true && "${HAS_TRAEFIK_API:-false}" != true ]]; then
  skip "Identifying which Traefik bouncer type you're running (legacy or modern plugin)" \
    "Two independent checks, use either or both: the legacy ForwardAuth-style bouncer has its own service to ping; the modern plugin bouncer runs in-process inside Traefik, so it's confirmed via Traefik's own API instead." \
    "For the legacy bouncer: set TRAEFIK_BOUNCER_URL to its address, e.g. http://traefik-bouncer:8080. For the modern plugin bouncer: set TRAEFIK_API_URL to Traefik's internal API address, e.g. http://traefik:8080 (requires --api.dashboard=true on Traefik)" \
    "Just unset whichever you set — nothing to clean up on the CrowdSec side, this check never touches LAPI or writes anything"
  exit 0
fi

legacy_checked=false
legacy_detected=false
plugin_checked=false
plugin_detected=false

if [[ "${HAS_BOUNCER_URL:-false}" == true ]]; then
  legacy_checked=true
  status="$(http_status "${TRAEFIK_BOUNCER_URL}/api/v1/ping")"
  body="$(http_get "${TRAEFIK_BOUNCER_URL}/api/v1/ping" 2>/dev/null || true)"
  [[ "$status" == "200" && "$body" == *"pong"* ]] && legacy_detected=true
fi

if [[ "${HAS_TRAEFIK_API:-false}" == true ]]; then
  plugin_checked=true
  middlewares="$(http_get "${TRAEFIK_API_URL}/api/http/middlewares" 2>/dev/null)"
  if [[ -n "$middlewares" ]] && echo "$middlewares" | jq -e '.[] | select(.plugin != null) | .provider // "" | test("crowdsec"; "i")' >/dev/null 2>&1; then
    plugin_detected=true
  elif [[ -z "$middlewares" ]]; then
    warn "Couldn't reach Traefik's API at ${TRAEFIK_API_URL}/api/http/middlewares"
  fi
fi

if [[ "$legacy_detected" == true ]]; then
  warn "Legacy ForwardAuth-style Traefik bouncer detected at ${TRAEFIK_BOUNCER_URL}
This bouncer type (fbonalair/freifunkmuc-style) predates CrowdSec's AppSec/WAF component.
CrowdSec's own docs now recommend the Traefik plugin bouncer instead."
fi

if [[ "$plugin_detected" == true ]]; then
  ok "Modern Traefik plugin bouncer detected — this is the current recommended approach"
fi

if [[ "$legacy_detected" != true && "$plugin_detected" != true ]]; then
  if [[ "$legacy_checked" == true && "$plugin_checked" == true ]]; then
    info "Neither the legacy bouncer nor the modern plugin bouncer could be confirmed.
Checked TRAEFIK_BOUNCER_URL (${TRAEFIK_BOUNCER_URL}) and TRAEFIK_API_URL (${TRAEFIK_API_URL}) — neither fingerprint matched."
  elif [[ "$legacy_checked" == true ]]; then
    info "No legacy-style bouncer found at ${TRAEFIK_BOUNCER_URL}.
This does NOT confirm the modern plugin bouncer is running — it just means this specific
fingerprint didn't match. Set TRAEFIK_API_URL too if you want to check for the plugin bouncer instead."
  elif [[ "$plugin_checked" == true ]]; then
    info "No crowdsec plugin middleware found registered in Traefik.
This does NOT confirm the legacy bouncer is running — it just means this specific check didn't
match. Set TRAEFIK_BOUNCER_URL too if you want to check for the legacy bouncer instead."
  fi
fi

exit 0
