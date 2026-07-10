#!/usr/bin/env bash
# capability_check.sh
#
# Runs first, always. Detects what's actually available and exports a small
# set of HAS_* flags that every check script reads before doing anything.
# Nothing downstream should assume access it hasn't confirmed here — that's
# the whole point of this file existing separately from troubleshoot.sh.
#
# Hard rule: this script must never fail or exit non-zero just because
# something is missing. Missing == false, not an error. The only thing that
# can make this fail is CROWDSEC_LAPI_URL being genuinely unset, since
# nothing in this tool is meaningful without it.

set -uo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [[ -z "${CROWDSEC_LAPI_URL:-}" ]]; then
  crit "CROWDSEC_LAPI_URL is not set — this is the one thing this tool actually requires."
  info "Example: -e CROWDSEC_LAPI_URL=http://crowdsec:8080"
  exit 1
fi

# Tier 1: a dedicated read-only bouncer key
[[ -n "${CROWDSEC_LAPI_KEY:-}" ]] && export HAS_BOUNCER_KEY=true || export HAS_BOUNCER_KEY=false

# Tier 2: machine credentials (read-write). Stored as a file, not an inline
# env var, so it doesn't end up in `docker inspect` output or shell history.
if [[ -n "${CROWDSEC_MACHINE_CREDENTIALS_FILE:-}" && -r "${CROWDSEC_MACHINE_CREDENTIALS_FILE:-}" ]]; then
  export HAS_MACHINE_CREDS=true
else
  export HAS_MACHINE_CREDS=false
fi

# Optional integrations — each just reflects whether its env var is set
[[ -n "${TRAEFIK_API_URL:-}" ]] && export HAS_TRAEFIK_API=true || export HAS_TRAEFIK_API=false
[[ -n "${TRAEFIK_BOUNCER_URL:-}" ]] && export HAS_BOUNCER_URL=true || export HAS_BOUNCER_URL=false
if [[ -n "${TRAEFIK_PROTECTED_URL:-}" && -n "${TRAEFIK_DIRECT_URL:-}" ]]; then
  export HAS_BYPASS_URLS=true
else
  export HAS_BYPASS_URLS=false
fi

# Tier 3: read-only mounts — fixed paths by convention (see compose examples),
# not user-configurable, to keep setup simple.
[[ -r "/mnt/bouncer/firewall-bouncer.yaml" ]] && export HAS_BOUNCER_CONFIG_MOUNT=true || export HAS_BOUNCER_CONFIG_MOUNT=false
[[ -r "/mnt/bouncer/firewall-bouncer.log" ]] && export HAS_BOUNCER_LOG_MOUNT=true || export HAS_BOUNCER_LOG_MOUNT=false
[[ -r "/mnt/compose/docker-compose.yml" ]] && export HAS_COMPOSE_MOUNT=true || export HAS_COMPOSE_MOUNT=false

# Auto-detect the highest tier currently satisfiable, for the default
# (no --tier flag) run. Explicit --tier requests are handled in troubleshoot.sh.
detected_tier=0
[[ "$HAS_BOUNCER_KEY" == true ]] && detected_tier=1
[[ "$HAS_MACHINE_CREDS" == true ]] && detected_tier=2
export DETECTED_TIER="$detected_tier"
