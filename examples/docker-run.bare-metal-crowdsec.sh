#!/usr/bin/env bash
# docker-run.bare-metal-crowdsec.sh — reference invocation for checking a
# CrowdSec install that runs via apt/binary on the host, NOT in Docker.
#
# This tool always runs as a container itself (docker run --rm ...) — that
# doesn't change here. What changes is which host paths get bind-mounted
# for tier 3, since a package install uses real filesystem paths instead of
# a docker-compose volume layout. See README.md's "Bare-metal / non-Docker
# CrowdSec installs" section for the full explanation and the reasoning
# behind each path below — verified against CrowdSec's actual default
# config.yaml and the firewall bouncer's own packaged config, not assumed.
#
# Not meant to be run as-is: fill in LAPI_URL/LAPI_KEY below (or export
# them before running this script), and comment out whichever tier-3 mount
# lines don't apply to your setup (e.g. you may not run the firewall
# bouncer at all, or may have customized common.log_dir away from the
# /var/log/ default).
#
# wizard.sh works here too and is the easier route day-to-day — see the
# README's dual bare-metal/Dockerized note if you also run a *separate*
# Dockerized CrowdSec instance (e.g. one dedicated to Traefik): wizard.sh's
# compose auto-detection will always find that one, not this bare-metal
# one, since there's no container to detect for a bare-metal install —
# answer 'skip' at its compose-file prompt to enter these values by hand.

set -uo pipefail

# --- required ---
LAPI_URL="${LAPI_URL:-http://192.168.1.10:8080}"        # your CrowdSec host's real LAN IP/hostname

# --- optional: tier 1 (check-ip, ban-count stats) ---
# Get one with: cscli bouncers add troubleshooter-readonly
LAPI_KEY="${LAPI_KEY:-}"

docker run --rm \
  -e CROWDSEC_LAPI_URL="$LAPI_URL" \
  ${LAPI_KEY:+-e CROWDSEC_LAPI_KEY="$LAPI_KEY"} \
  -v /etc/crowdsec/acquis.yaml:/mnt/crowdsec/acquis.yaml:ro \
  -v /etc/crowdsec/acquis.d:/mnt/crowdsec/acquis.d:ro \
  -v /var/log/crowdsec.log:/mnt/crowdsec/crowdsec.log:ro \
  -v /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml:/mnt/bouncer/firewall-bouncer.yaml:ro \
  -v /var/log/crowdsec-firewall-bouncer.log:/mnt/bouncer/firewall-bouncer.log:ro \
  modem7/crowdsec-troubleshooter --tier 3

# No docker-compose.yml mount here on purpose — check_compose_hardening.sh
# doesn't apply to a pure bare-metal install (nothing to audit) and simply
# reports its usual 🔒 skip block when that mount is absent, same as any
# other unconfigured optional check.
