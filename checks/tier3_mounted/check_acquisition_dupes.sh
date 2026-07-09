#!/usr/bin/env bash
# check_acquisition_dupes.sh — Tier 3, needs acquis.yaml mounted read-only.
#
# Re-running CrowdSec's install wizard is a documented way to duplicate
# acquisition entries, meaning each log line gets read and counted multiple
# times — a scenario can then trigger on fewer real events than its
# threshold implies. This just scans for duplicate file paths across
# acquis.yaml / acquis.d/*, nothing more.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

ACQUIS_PATH="/mnt/crowdsec/acquis.yaml"
ACQUIS_DIR="/mnt/crowdsec/acquis.d"

if [[ ! -r "$ACQUIS_PATH" && ! -d "$ACQUIS_DIR" ]]; then
  skip "Checking for duplicate acquisition entries (a known install-wizard re-run bug)" \
    "Needs acquis.yaml and/or acquis.d/ mounted read-only — pure text scanning." \
    "Add: - \$USERDIR/Crowdsec/config/acquis.yaml:/mnt/crowdsec/acquis.yaml:ro (and acquis.d if you use it)" \
    "Just remove that volume line"
  exit 0
fi

dupes="$(cat "$ACQUIS_PATH" "$ACQUIS_DIR"/*.yaml 2>/dev/null | grep -E '^\s*-\s*/' | sort | uniq -d)"

if [[ -n "$dupes" ]]; then
  warn "Duplicate acquisition file paths found — each of these log files is being read more than once:"
  echo "$dupes" | sed 's/^/     /'
  info "Consequence: scenarios watching these logs may trigger on fewer real events than their"
  info "threshold implies, since each line is double-counted."
else
  ok "No duplicate acquisition entries found"
fi
