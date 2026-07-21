# syntax = docker/dockerfile:latest@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# Baked in at build time so a running container can report which commit it
# was actually built from — check_image_freshness.sh compares this against
# GitHub's latest master commit to warn about stale pulls. Defaults to
# "unknown" for a local `docker build .` with no --build-arg, which the
# check treats as "can't verify, not necessarily stale" rather than a
# false warning.
ARG GIT_SHA=unknown
ENV IMAGE_GIT_SHA=$GIT_SHA

RUN apk add --no-cache bash curl jq

WORKDIR /app
COPY --link lib/ lib/
COPY --link checks/ checks/
COPY --link setup/ setup/
COPY --link versioncheck/ versioncheck/
COPY --link capability_check.sh troubleshoot.sh ./
RUN chmod +x troubleshoot.sh capability_check.sh \
    lib/*.sh setup/*.sh versioncheck/*.sh \
    checks/*/*.sh

# Deliberately no HEALTHCHECK, no long-running process, no default CMD that
# loops — this tool runs once and exits. See README for why no daemon mode.
ENTRYPOINT ["./troubleshoot.sh"]
