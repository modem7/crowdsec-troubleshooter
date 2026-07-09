#!/usr/bin/env bash
# check_capi.sh — Tier 2, needs machine credentials. STATUS: UNVERIFIED.
#
# Intended to check whether the community-blocklist connection to CAPI is
# alive. `cscli capi status` exists as a command, but — same caveat as
# bouncer listing — it's unconfirmed whether this data is reachable via an
# LAPI HTTP endpoint for a third-party machine-authenticated client, or
# whether it's a DB/local-only operation like bouncer add/delete turned out
# to be. Do not treat this script as working until that's checked against
# the swagger spec or a live instance. Left in as a placeholder rather than
# silently dropped, so the open question doesn't get lost.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

warn "check_capi.sh is a known placeholder — CAPI status may not be reachable via LAPI HTTP at all"
info "See the comment at the top of this file. Needs verification before this check can be trusted."
exit 0
