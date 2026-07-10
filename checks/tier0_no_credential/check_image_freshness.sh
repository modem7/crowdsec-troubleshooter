#!/usr/bin/env bash
# check_image_freshness.sh — Tier 0, no credential needed.
#
# Compares the git commit this image was built from (baked in via
# IMAGE_GIT_SHA, see Dockerfile + .woodpecker.yml's GIT_SHA build-arg)
# against the latest commit on this project's master branch, so a manual
# `docker run` user finds out up-front if they're running a stale pull
# rather than debugging against an old build. Purely informational and
# network-gated, not credential-gated, so an unreachable GitHub API
# degrades to a plain info line rather than the padlock/skip UI — there's
# no credential to "add" here, just a best-effort check that didn't land.
#
# Known limitations, stated rather than papered over:
# - Compares against the latest commit on master, not what's actually been
#   published to Docker Hub yet. There's a brief window right after a push
#   — while CI is still building and pushing — where this can flag an
#   image that is, in fact, the latest one actually published.
# - GitHub's API is called unauthenticated here (60 req/hour per source
#   IP). A burst of runs from the same IP could hit that limit; treated as
#   "can't verify" rather than a failure either way.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"
require_jq

REPO="${IMAGE_FRESHNESS_REPO:-modem7/crowdsec-troubleshooter}"
BUILT_SHA="${IMAGE_GIT_SHA:-unknown}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"

if [[ "$BUILT_SHA" == "unknown" ]]; then
  info "This image wasn't built with GIT_SHA set (a local 'docker build .', maybe?) — skipping the freshness check"
  exit 0
fi

latest_response="$(http_get "${GITHUB_API_BASE}/repos/${REPO}/commits/master" "Accept: application/vnd.github+json" 2>/dev/null)"

if [[ -z "$latest_response" ]]; then
  info "Couldn't reach GitHub to check for a newer build — not treated as a failure, just unverified"
  exit 0
fi

latest_sha="$(echo "$latest_response" | jq -r '.sha // empty' 2>/dev/null)"

if [[ -z "$latest_sha" ]]; then
  info "GitHub's response didn't include a commit SHA (rate-limited?) — skipping the freshness check"
  exit 0
fi

if [[ "${latest_sha:0:7}" == "${BUILT_SHA:0:7}" ]]; then
  ok "Running the latest published build (commit ${BUILT_SHA:0:7})"
else
  warn "This image was built from an older commit (${BUILT_SHA:0:7}) — latest on master is ${latest_sha:0:7}"
  info "Pull the newest image: docker pull modem7/crowdsec-troubleshooter:latest
If you just saw a new push go out, this can also mean CI is still building it — wait a few minutes and re-pull."
fi
exit 0
