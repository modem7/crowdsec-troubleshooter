#!/usr/bin/env bash
# remove_readonly_bouncer.sh — the undo counterpart to add_readonly_bouncer.sh

set -uo pipefail
BOUNCER_NAME="${1:-troubleshooter-readonly}"

cat <<EOF

To remove the read-only key this tool has been using, run this on your
CrowdSec server:

    docker exec crowdsec cscli bouncers delete ${BOUNCER_NAME}

Then remove CROWDSEC_LAPI_KEY from this container's environment/secrets.
The block checker (check-ip) will stop working until a new key is added;
everything else in this tool is unaffected.

EOF
