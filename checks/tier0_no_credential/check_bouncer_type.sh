#!/usr/bin/env bash
# check_bouncer_type.sh — Tier 0, no credential needed.
#
# Distinguishes the legacy ForwardAuth-style Traefik bouncer (fbonalair /
# freifunkmuc forks) from the modern Traefik plugin bouncer — by fingerprinting
# the bouncer's own network endpoint directly, NOT via LAPI. This never touches
# LAPI's bouncer registry at all: cscli's bouncer list/add/delete commands hit
# CrowdSec's database directly, not an HTTP endpoint, so that data isn't
# reachable over the network regardless of credential tier. This check works
# around that by asking the bouncer itself instead.
#
# A response here is a POSITIVE fingerprint of the legacy bouncer. No response
# does NOT prove the modern plugin bouncer is running instead — that requires
# check_traefik_plugin.sh (optional_traefik_api/), since the plugin runs
# in-process inside Traefik with no separate service to probe at all.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

if [[ "${HAS_BOUNCER_URL:-false}" != true ]]; then
  skip "Identifying which Traefik bouncer type you're running" \
    "This needs to know where your bouncer's own service lives. Nothing sensitive — just a URL, no credential of any kind." \
    "Set TRAEFIK_BOUNCER_URL to your bouncer container's address, e.g. http://traefik-bouncer:8080" \
    "Just unset TRAEFIK_BOUNCER_URL — nothing to clean up on the CrowdSec side, this check never touches LAPI"
  exit 0
fi

status="$(http_status "${TRAEFIK_BOUNCER_URL}/api/v1/ping")"
body="$(http_get "${TRAEFIK_BOUNCER_URL}/api/v1/ping" 2>/dev/null || true)"

if [[ "$status" == "200" && "$body" == *"pong"* ]]; then
  warn "Legacy ForwardAuth-style Traefik bouncer detected at ${TRAEFIK_BOUNCER_URL}"
  info "This bouncer type (fbonalair/freifunkmuc-style) predates CrowdSec's AppSec/WAF component.
CrowdSec's own docs now recommend the Traefik plugin bouncer instead — see check_traefik_plugin.sh"
  exit 0
else
  info "No legacy-style bouncer found at ${TRAEFIK_BOUNCER_URL}
This does NOT confirm the modern plugin bouncer is running — it just means this specific
fingerprint didn't match. If TRAEFIK_API_URL is set, check_traefik_plugin.sh can confirm that instead."
  exit 0
fi
