#!/usr/bin/env bash
# check_config_syslog_hint.sh — Tier 3, needs the crowdsec log dir mounted read-only.
#
# A real gotcha: config.yaml-level YAML errors log to syslog, not
# crowdsec.log — meaning "where do I even look" is itself the problem for a
# lot of people. This can't read syslog (out of scope, host-level), but it
# can notice when crowdsec's own log is suspiciously empty/missing and point
# at the actual place to look instead of leaving that as a silent gap.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

LOG_PATH="/mnt/crowdsec/crowdsec.log"

if [[ ! -r "$LOG_PATH" ]]; then
  skip "Hinting where to look if crowdsec won't start and nothing explains why" \
    "Needs crowdsec's own log directory mounted read-only, just to check it isn't suspiciously empty." \
    "Add: - \$USERDIR/Crowdsec/config/log:/mnt/crowdsec:ro (adjust path to match your logfile location)" \
    "Just remove that volume line"
  exit 0
fi

if [[ ! -s "$LOG_PATH" ]]; then
  warn "crowdsec.log exists but is empty — if crowdsec isn't starting, this is a real gotcha:"
  info "config.yaml-level YAML syntax errors log to syslog, not crowdsec.log. Check the host's"
  info "syslog/journalctl output for the actual error, not this file."
else
  ok "crowdsec.log has content — if something's wrong, it's likely logged here rather than syslog"
fi
