FROM alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc

RUN apk add --no-cache bash curl jq

WORKDIR /app
COPY lib/ lib/
COPY checks/ checks/
COPY setup/ setup/
COPY versioncheck/ versioncheck/
COPY capability_check.sh troubleshoot.sh ./
RUN chmod +x troubleshoot.sh capability_check.sh \
    lib/*.sh setup/*.sh versioncheck/*.sh \
    checks/*/*.sh

# Deliberately no HEALTHCHECK, no long-running process, no default CMD that
# loops — this tool runs once and exits. See README for why no daemon mode.
ENTRYPOINT ["./troubleshoot.sh"]
