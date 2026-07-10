#!/usr/bin/env bash
# add_readonly_bouncer.sh
#
# Prints instructions rather than executing anything — bouncer registration
# (`cscli bouncers add`) is a database operation, not an LAPI HTTP endpoint,
# so it can't be done by this container over the network. The one manual
# step below is unavoidable by design.

set -uo pipefail
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

BOUNCER_NAME="${1:-troubleshooter-readonly}"

cat <<EOF

To give this tool the ability to look up a specific IP's ban status, run
this ONE command on your CrowdSec server (not in this container):

    docker exec crowdsec cscli bouncers add ${BOUNCER_NAME}

It will print an API key — copy it, then set it as this container's
CROWDSEC_LAPI_KEY. That key can only READ the ban list. It cannot create,
remove, or change anything.

To undo this later, run:

    docker exec crowdsec cscli bouncers delete ${BOUNCER_NAME}

...then unset CROWDSEC_LAPI_KEY on this container. (See
setup/remove_readonly_bouncer.sh for the same instructions on demand.)

EOF
