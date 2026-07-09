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
source "$(dirname "$0")/lib/common.sh"

if [[ -z "${CROWDSEC_LAPI_URL:-}" ]]; then
  crit "CROWDSEC_LAPI_URL is not set — this is the one thing this tool actually requires."
  info "Example: -e CROWDSEC_LAPI_URL=http://crowdsec:8080"
  exit 1
fi

# Tier 1: a dedicated read-only bouncer key
if [[ -n "${CROWDSEC_LAPI_KEY:-}" ]]; then
  export HAS_BOUNCER_KEY=true
else
  export HAS_BOUNCER_KEY=false
fi

# Tier 2: machine credentials (read-write). Stored as a file, not an inline
# env var, so it doesn't end up in `docker inspect` output or shell history.
if [[ -n "${CROWDSEC_MACHINE_CREDENTIALS_FILE:-}" && -r "${CROWDSEC_MACHINE_CREDENTIALS_FILE:-}" ]]; then
  export HAS_MACHINE_CREDS=true
else
  export HAS_MACHINE_CREDS=false
fi

# Optional: Traefik's own API, a separate integration surface from LAPI
if [[ -n "${TRAEFIK_API_URL:-}" ]]; then
  export HAS_TRAEFIK_API=true
else
  export HAS_TRAEFIK_API=false
fi

# Optional: bouncer's own service address, for direct fingerprinting
if [[ -n "${TRAEFIK_BOUNCER_URL:-}" ]]; then
  export HAS_BOUNCER_URL=true
else
  export HAS_BOUNCER_URL=false
fi

# Optional: paired URLs for the auth-bypass comparison check
if [[ -n "${TRAEFIK_PROTECTED_URL:-}" && -n "${TRAEFIK_DIRECT_URL:-}" ]]; then
  export HAS_BYPASS_URLS=true
else
  export HAS_BYPASS_URLS=false
fi

# Tier 3: read-only mounted bouncer config/log — path is fixed by convention,
# documented in the compose examples, not user-configurable (keeps setup simple)
if [[ -r "/mnt/bouncer/firewall-bouncer.yaml" ]]; then
  export HAS_BOUNCER_CONFIG_MOUNT=true
else
  export HAS_BOUNCER_CONFIG_MOUNT=false
fi
if [[ -r "/mnt/bouncer/firewall-bouncer.log" ]]; then
  export HAS_BOUNCER_LOG_MOUNT=true
else
  export HAS_BOUNCER_LOG_MOUNT=false
fi
if [[ -r "/mnt/compose/docker-compose.yml" ]]; then
  export HAS_COMPOSE_MOUNT=true
else
  export HAS_COMPOSE_MOUNT=false
fi

# Auto-detect the highest tier currently satisfiable, for the default
# (no --tier flag) run. Explicit --tier requests are handled in troubleshoot.sh.
detected_tier=0
[[ "$HAS_BOUNCER_KEY" == true ]] && detected_tier=1
[[ "$HAS_MACHINE_CREDS" == true ]] && detected_tier=2
export DETECTED_TIER="$detected_tier"
