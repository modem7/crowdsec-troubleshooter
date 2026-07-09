#!/usr/bin/env bash
# cve.sh — checks crowdsec/bouncer versions against known CVEs.
#
# STATUS: the weakest link in the whole network-only design. LAPI doesn't
# reliably expose its own version over the API for a third-party client to
# read. Two real options, neither implemented yet:
#   1. Prompt for the version once during setup and store it (simplest,
#      but goes stale if crowdsec is upgraded without re-running setup)
#   2. Read it from an optional mounted log line (accurate, but pulls in
#      another tier3-style mount for something that should arguably be tier0)
#
# Known CVEs worth checking against once a version is available:
#   - CVE-2026-33278 (critical validator RCE, 1.19.1–1.25.0, fixed 1.25.1)
#   - CVE-2026-44982 (WAF/AppSec chunked-body bypass, fixed 1.7.8)
#   - CVE-2026-44981 (LAPI DoS via gzip decompression, fixed 1.7.8)
# This list will go stale — treat it as a starting point, not a feed.

set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

CROWDSEC_VERSION="${CROWDSEC_VERSION_HINT:-}"

if [[ -z "$CROWDSEC_VERSION" ]]; then
  info "No CROWDSEC_VERSION_HINT set — version/CVE checking is skipped until this is resolved properly"
  info "See the comment at the top of this file for the two real implementation options"
  exit 0
fi

warn "Version/CVE checking against '${CROWDSEC_VERSION}' — this is a hardcoded, unmaintained CVE list"
info "Do not treat a clean result here as a real guarantee. Check NLnetLabs/crowdsec security"
info "advisories directly for anything current."
