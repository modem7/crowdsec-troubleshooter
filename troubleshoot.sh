#!/usr/bin/env bash
# troubleshoot.sh — main entrypoint.
#
# Always: docker run --rm, never a daemon. --tier selects what to attempt;
# default (no flag) auto-detects the highest tier the current credentials
# satisfy and runs everything up to that. Requesting a higher tier than
# what's configured doesn't fail — it runs what it can and prints the guard
# explanation for the gap, which doubles as a preview of what that tier
# needs before deciding to set it up.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || { echo "Failed to cd into script directory — this shouldn't happen inside the container"; exit 1; }
source lib/common.sh

# `issues` is pure offline reference data (no LAPI, no credential needed), so
# it's handled before capability_check.sh sources — that script hard-fails
# without CROWDSEC_LAPI_URL, which would otherwise block this working airgapped.
if [[ "${1:-}" == "issues" ]]; then
  source lib/known_issues.sh
  case "${2:-}" in
    "") kb_list ;;
    search) kb_search "${3:-}" ;;
    *) kb_show "${2}" ;;
  esac
  exit 0
fi

# ---- capability detection, always first ----
source capability_check.sh

# ---- argument parsing ----
REQUESTED_TIER="$DETECTED_TIER"
ACTION="tier-run"
ACTION_ARG=""

case "${1:-}" in
  --tier)
    REQUESTED_TIER="${2:-0}"; ACTION="tier-run"
    ;;
  check-ip)
    ACTION="check-ip"; ACTION_ARG="${2:-}"
    ;;
  live-test)
    ACTION="live-test"; ACTION_ARG="${3:-}"  # expects: live-test --target-url <url>
    ;;
  setup)
    exec "setup/${2}.sh" "${@:3}"
    ;;
  "")
    ACTION="tier-run"
    ;;
  *)
    echo "Usage: troubleshoot.sh [--tier N] | check-ip <ip> | live-test --target-url <url> | setup <script-name> | issues [<id>|search <term>]"
    exit 2
    ;;
esac

# run_checks_grouped <dir-or-single-check.sh> — runs every check script in
# <dir> (or just the one script, if given a file — used by run_tier1() for
# check_ban_stats.sh, the one tier1 check needing no argument). Prints real
# results (OK/WARN/CRIT/INFO) as they complete, but holds back the 🔒
# "not configured" blocks to print together under one footer instead of
# interleaved with real results.
#
# Each check's output is captured in full before it's classified, so a check
# with an internal wait (check_metrics_liveness.sh's poll gap) won't stream
# progress in real time — acceptable since nothing else here has a comparable delay.
run_checks_grouped() {
  local target="$1"
  local -a checks=()
  if [[ -d "$target" ]]; then
    checks=("$target"/*.sh)
  else
    checks=("$target")
  fi
  local locked="" out status overall_status=0
  for check in "${checks[@]}"; do
    out="$(bash "$check")"
    # Capture $? immediately — the command substitution above already
    # consumed it once, so grabbing it late would silently lose a check's
    # real exit code.
    status=$?
    (( status != 0 )) && overall_status=$status
    if [[ "$out" == *"🔒"* ]]; then
      locked+="${out}"$'\n'
    else
      printf '%s\n' "$out"
    fi
  done
  if [[ -n "$locked" ]]; then
    echo
    echo "── Optional checks (not configured) ──"
    printf '%s' "$locked"
  fi
  return "$overall_status"
}

run_tier0() {
  run_checks_grouped "checks/tier0_no_credential"
}

run_tier1() {
  # check_ban_stats.sh needs no argument (unlike check-ip), so it's the one
  # tier1 check that can safely join an automatic sweep — it degrades to
  # its own 🔒 skip block via run_checks_grouped exactly like tier0/tier3
  # checks do when HAS_BOUNCER_KEY is false.
  run_checks_grouped "checks/tier1_bouncer_key/check_ban_stats.sh"
  local status=$?
  info "check-ip <ip> is a separate named action — not part of the automatic sweep, since it needs an IP argument"
  return "$status"
}

run_tier2() {
  info "(tier 2 live tests need --target-url and are run explicitly, not part of the default sweep)"
}

run_tier3() {
  run_checks_grouped "checks/tier3_mounted"
}

case "$ACTION" in
  tier-run)
    echo "Wellness Check Results"
    echo "────────────────────────"
    # tier_status is tracked explicitly rather than relying on the last
    # statement's exit status: `(( cond )) && run_tierN` alone would leak the
    # arithmetic test's own exit code (1) whenever a tier is skipped, and a
    # bare `if`/`fi` would let a vacuously-true skip silently overwrite an
    # earlier tier's real failure.
    tier_status=0
    run_tier0; (( $? != 0 )) && tier_status=1
    if (( REQUESTED_TIER >= 1 )); then run_tier1; (( $? != 0 )) && tier_status=1; fi
    if (( REQUESTED_TIER >= 2 )); then run_tier2; (( $? != 0 )) && tier_status=1; fi
    if (( REQUESTED_TIER >= 3 )); then run_tier3; (( $? != 0 )) && tier_status=1; fi
    exit "$tier_status"
    ;;
  check-ip)
    [[ -z "$ACTION_ARG" ]] && { echo "Usage: troubleshoot.sh check-ip <ip-address>"; exit 2; }
    bash checks/tier1_bouncer_key/check_ip.sh "$ACTION_ARG"
    ;;
  live-test)
    bash checks/tier2_machine/test_live_block.sh --target-url "$ACTION_ARG"
    ;;
esac
