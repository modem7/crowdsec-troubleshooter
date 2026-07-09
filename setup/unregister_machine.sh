#!/usr/bin/env bash
# unregister_machine.sh — the undo counterpart to register_machine.sh

set -uo pipefail
MACHINE_NAME="${1:-troubleshooter}"

cat <<EOF

To remove the machine credential this tool has been using, run this on
your CrowdSec server:

    docker exec crowdsec cscli machines delete ${MACHINE_NAME}

Then delete the credentials file and remove
CROWDSEC_MACHINE_CREDENTIALS_FILE from this container's environment. The
live block test and AppSec probe test will stop working; everything else
in this tool is unaffected.

EOF
