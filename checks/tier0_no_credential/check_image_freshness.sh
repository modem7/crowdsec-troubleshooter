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
#
# A SHA mismatch alone used to be treated as "stale" outright — wrong.
# .woodpecker.yml only rebuilds Docker Hub's image on pushes that touch
# actual image content (see its own path: include list), on purpose:
# wizard.sh runs on the host and is never COPY'd into the Dockerfile, so a
# wizard.sh-only change to master legitimately has no corresponding newer
# image to pull, ever — yet the old logic would warn "stale" forever after
# a change like that, with no way to resolve it short of a comment change
# hitting a watched path. Real bug, caught by a wizard.sh-only PR merging
# and this check immediately misreporting the (correctly up-to-date)
# published image as stale. Fixed with one extra GitHub API call — only
# made on a SHA mismatch, so the common (already up to date) case stays at
# one call — asking what actually changed between the built commit and
# master's tip, and only warning if something on the same watched-path
# list actually did.

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

latest_sha="$(jq -r '.sha // empty' <<<"$latest_response" 2>/dev/null)"

if [[ -z "$latest_sha" ]]; then
  info "GitHub's response didn't include a commit SHA (rate-limited?) — skipping the freshness check"
  exit 0
fi

if [[ "${latest_sha:0:7}" == "${BUILT_SHA:0:7}" ]]; then
  ok "Running the latest published build (commit ${BUILT_SHA:0:7})"
  exit 0
fi

# SHAs differ — but that alone doesn't mean a newer image actually exists.
# Mirror .woodpecker.yml's own path: include list (kept in sync by hand;
# it's short and changes rarely) to check whether anything that actually
# lands in the image changed between the built commit and master's tip.
compare_response="$(http_get "${GITHUB_API_BASE}/repos/${REPO}/compare/${BUILT_SHA}...master" "Accept: application/vnd.github+json" 2>/dev/null)"

if [[ -z "$compare_response" ]]; then
  warn "This image was built from an older commit (${BUILT_SHA:0:7}) — latest on master is ${latest_sha:0:7}"
  info "Couldn't reach GitHub to check whether that actually changes the image itself — assuming it might."
  info "Pull the newest image: docker pull modem7/crowdsec-troubleshooter:latest"
  exit 0
fi

changed_relevant="$(jq -r '.files[]?.filename // empty' <<<"$compare_response" 2>/dev/null \
  | grep -E '^(Dockerfile|lib/|checks/|setup/|versioncheck/|capability_check\.sh|troubleshoot\.sh|\.woodpecker\.yml)' \
  | head -1 || true)"

if [[ -z "$changed_relevant" ]]; then
  ok "Running an older commit (${BUILT_SHA:0:7}) than master's tip (${latest_sha:0:7}), but nothing since then actually changes the image — nothing to pull"
else
  warn "This image was built from an older commit (${BUILT_SHA:0:7}) — latest on master is ${latest_sha:0:7}"
  info "Pull the newest image: docker pull modem7/crowdsec-troubleshooter:latest
If you just saw a new push go out, this can also mean CI is still building it — wait a few minutes and re-pull."
fi
exit 0
