#!/usr/bin/env bash
# check_hub_update_cron.sh — Tier 0, no credential needed. Mount optional.
#
# CrowdSec's detection rules (scenarios/collections) go stale without
# `cscli hub update && cscli hub upgrade` run periodically — a silent
# failure mode, since LAPI stays healthy while defending against outdated
# attack patterns. Unlike the Traefik checks, this applies to every
# installation, so it always prints a plain info line rather than being
# gated behind skip()'s "Optional checks" footer.
#
# If a host crontab is optionally mounted read-only, this upgrades from a
# blanket recommendation to an actual confirmed/missing finding.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

# CRON_MOUNT_BASE override exists for tests only (same pattern as
# GITHUB_API_BASE/IP_ECHO_URL elsewhere) — real usage always mounts to the
# fixed /mnt/cron path documented in FLAGS.md.
CRON_MOUNT_BASE="${CRON_MOUNT_BASE:-/mnt/cron}"
CRON_PATH="${CRON_MOUNT_BASE}/crontab"
CRON_DIR="${CRON_MOUNT_BASE}/cron.d"

if [[ ! -r "$CRON_PATH" && ! -d "$CRON_DIR" ]]; then
  info "Recommended: a periodic cron job running 'cscli hub update && cscli hub upgrade' (e.g. weekly) —"
  info "nothing else keeps scenarios/collections current, and a stale hub fails silently."
  info "Mount your crontab read-only to let this check confirm it's actually there instead of just"
  info "suggesting it — see FLAGS.md for the exact mount path."
  exit 0
fi

content="$(cat "$CRON_PATH" "$CRON_DIR"/* 2>/dev/null || true)"
has_update="$(grep -c 'cscli hub update' <<<"$content" || true)"
has_upgrade="$(grep -c 'cscli hub upgrade' <<<"$content" || true)"

if [[ "${has_update:-0}" -gt 0 && "${has_upgrade:-0}" -gt 0 ]]; then
  ok "Found a cron job running cscli hub update/upgrade — scenarios and collections stay current"
else
  warn "No cron job found running cscli hub update && cscli hub upgrade in the mounted crontab"
  info "Without this, scenarios/collections silently go stale — nothing else refreshes them. Example:"
  info "0 3 * * 0 docker exec crowdsec cscli hub update && docker exec crowdsec cscli hub upgrade"
fi
exit 0
