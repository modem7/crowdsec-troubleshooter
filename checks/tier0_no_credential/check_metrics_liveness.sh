#!/usr/bin/env bash
# check_metrics_liveness.sh — Tier 0, no credential needed.
#
# CrowdSec's Prometheus endpoint is unauthenticated by default, same as
# node_exporter. We scrape it twice, a few seconds apart, and compare the
# datasource hit counters — if they're moving, logs are actively being read
# and parsed, not just configured. Needs prometheus.listen_addr: 0.0.0.0 on
# the crowdsec side; the default is 127.0.0.1, which is invisible to a
# sibling container even on the same docker network. We detect that specific
# failure mode and say so, rather than just reporting a generic timeout.

set -uo pipefail
source "$(dirname "$0")/../../lib/common.sh"

METRICS_URL="${CROWDSEC_METRICS_URL:-${CROWDSEC_LAPI_URL/:8080/:6060}}"
POLL_GAP_SECONDS="${METRICS_POLL_GAP:-10}"

sum_hit_counters() {
  grep -E '^cs_(filesource|dockersource|journalctlsource)_hits_total' \
    | awk '{sum += $NF} END {print sum+0}'
}

first="$(http_get "${METRICS_URL}/metrics" 2>/dev/null | sum_hit_counters)"

if [[ -z "$first" ]]; then
  warn "Couldn't reach the metrics endpoint at ${METRICS_URL}/metrics"
  info "Most likely cause: prometheus.listen_addr is still the default 127.0.0.1 inside crowdsec's"
  info "own config, which is loopback-only and invisible to this container even on the same network."
  info "Set prometheus.listen_addr: 0.0.0.0 in crowdsec's config.yaml to fix this."
  exit 1
fi

step "First metrics sample: ${first} total log lines processed. Waiting ${POLL_GAP_SECONDS}s..."
sleep "$POLL_GAP_SECONDS"

second="$(http_get "${METRICS_URL}/metrics" 2>/dev/null | sum_hit_counters)"

if [[ -z "$second" ]]; then
  warn "Metrics endpoint stopped responding between polls — check crowdsec is still running"
  exit 1
fi

delta=$(( second - first ))
if (( delta > 0 )); then
  ok "Logs are actively being read and analyzed (${delta} new events in the last ${POLL_GAP_SECONDS}s)"
  exit 0
else
  warn "No new log activity in the last ${POLL_GAP_SECONDS}s"
  info "This can be normal on a quiet homelab with little traffic — not necessarily a problem on its own."
  info "If you were expecting activity, check the acquisition config points at the right log files."
  exit 0
fi
