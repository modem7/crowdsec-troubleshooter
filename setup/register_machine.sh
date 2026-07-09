#!/usr/bin/env bash
# register_machine.sh
#
# Same reasoning as add_readonly_bouncer.sh — this is a database operation,
# not something reachable over LAPI's HTTP API, so it has to be a manual
# step. This one grants a meaningfully stronger credential than a bouncer
# key (read-write — can create/delete real decisions), so the explanation
# here is deliberately more thorough before printing the command.

set -uo pipefail

MACHINE_NAME="${1:-troubleshooter}"

cat <<EOF

This unlocks the live block/unban test and the AppSec probe test — the
checks that actually PROVE bans work, not just that they're configured.

Before you run this: the credential it creates can create and delete real
CrowdSec decisions, same as running cscli yourself. It CANNOT touch Docker,
your host system, or anything outside CrowdSec's own ban list. Only add
this if you're comfortable with that — everything else in this tool works
fine without it.

Run this ONE command on your CrowdSec server:

    docker exec crowdsec cscli machines add ${MACHINE_NAME} --auto

Save the full output as a file (it's the credentials file itself), then
point this container's CROWDSEC_MACHINE_CREDENTIALS_FILE at it.

To undo this later, run:

    docker exec crowdsec cscli machines delete ${MACHINE_NAME}

...then delete the credentials file and unset
CROWDSEC_MACHINE_CREDENTIALS_FILE. (See setup/unregister_machine.sh for the
same instructions on demand.)

EOF
