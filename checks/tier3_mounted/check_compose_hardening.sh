#!/usr/bin/env bash
# check_compose_hardening.sh — Tier 3, needs a read-only mounted docker-compose.yml.
#
# Productizes the manual compose review into a repeatable rule set. Pure text
# parsing of a read-only mounted file — never docker.sock, never exec. The
# rules below are exactly the ones found by hand during the design of this
# tool, generalized to apply to anyone's compose file, not just one.

set -uo pipefail
# shellcheck source=../../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

COMPOSE_FILE="/mnt/compose/docker-compose.yml"

if [[ "${HAS_COMPOSE_MOUNT:-false}" != true ]]; then
  skip "Auditing your docker-compose.yml for common hardening gaps" \
    "This is pure text-file reading — no docker.sock, no exec, nothing beyond what's in the file itself. Mount it read-only and this runs entirely offline against the text." \
    "Add this volume to the troubleshooter service: - ./docker-compose.yml:/mnt/compose/docker-compose.yml:ro" \
    "Just remove that volume line — nothing else to undo"
  exit 0
fi

echo ""
echo "Compose hardening audit — ${COMPOSE_FILE}"
echo "───────────────────────────────────────"

# Rule 1: docker.sock mounted anywhere, and whether a socket-proxy is present
sock_services="$(grep -B5 'docker.sock:/var/run/docker.sock' "$COMPOSE_FILE" | grep -E '^\s{2}[a-zA-Z0-9_-]+:$' | tr -d ' :' || true)"
sock_count="$(grep -c 'docker.sock:/var/run/docker.sock' "$COMPOSE_FILE" || true)"
has_proxy="$(grep -ic 'socket-proxy\|tecnativa' "$COMPOSE_FILE" || true)"

if [[ "$sock_count" -gt 0 ]]; then
  if [[ "$has_proxy" -eq 0 ]]; then
    warn "${sock_count} service(s) mount docker.sock directly, with no socket-proxy in this file:"
    echo "$sock_services" | sed 's/^/     - /'
    info "Reminder: a :ro bind mount does NOT restrict which Docker API calls can be made over the"
    info "socket — it only stops the container rewriting the socket file itself. Consider"
    info "tecnativa/docker-socket-proxy to actually scope what each service can do."
  else
    ok "docker.sock is mounted by ${sock_count} service(s), but a socket-proxy is also present"
  fi
else
  ok "No services mount docker.sock directly"
fi

# Rule 2: published ports with no bind address on traefik/crowdsec-image services
# (dashboard/LAPI/metrics-shaped exposure — the exact pattern found by hand)
unbound_sensitive_ports="$(awk '
  /^\s{2}[a-zA-Z0-9_-]+:$/ { svc=$0 }
  /image:.*(traefik|crowdsec)/ { in_relevant_svc=1 }
  /^\s{2}[a-zA-Z0-9_-]+:$/ && !/image:/ { in_relevant_svc=0 }
  in_relevant_svc && /^\s*-\s*"?[0-9]+:[0-9]+"?\s*$/ { print svc, $0 }
' "$COMPOSE_FILE" || true)"

if [[ -n "$unbound_sensitive_ports" ]]; then
  warn "Traefik/CrowdSec-image services publish ports with no bind address (defaults to 0.0.0.0):"
  echo "$unbound_sensitive_ports" | sed 's/^/     /'
  info "If these are dashboard/API/metrics ports, they likely don't need to be reachable outside"
  info "the docker network at all — sibling containers can already reach them internally."
else
  ok "No unbound dashboard/API-style port publishes found on Traefik/CrowdSec-image services"
fi

# Rule 3: global insecureSkipVerify
if grep -q 'insecureSkipVerify=true' "$COMPOSE_FILE"; then
  warn "serversTransport.insecureSkipVerify=true found — disables TLS verification for ALL backend connections, not just ones that need it"
  info "Consider scoping this to a dedicated serversTransport applied only to backends with self-signed certs"
fi

# Rule 4: privileged containers
if grep -qE '^\s*privileged:\s*true\s*$' "$COMPOSE_FILE"; then
  warn "At least one service runs with privileged: true — worth confirming that's still necessary"
fi

# Rule 5: no-new-privileges coverage ratio
total_services="$(grep -cE '^\s{2}[a-zA-Z0-9_-]+:$' "$COMPOSE_FILE" || echo 0)"
hardened_services="$(grep -c 'no-new-privileges' "$COMPOSE_FILE" || echo 0)"
info "no-new-privileges is set on ${hardened_services} of roughly ${total_services} services"
info "Cheap, broad win where missing — blocks setuid-based privilege escalation with no functional downside"

echo ""
