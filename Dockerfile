# syntax = docker/dockerfile:latest

FROM alpine:3.24

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
