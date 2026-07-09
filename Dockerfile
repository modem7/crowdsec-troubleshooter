# syntax = docker/dockerfile:latest

FROM alpine:3.24

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
