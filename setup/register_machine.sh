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

Step 1 — run this ONE command on your CrowdSec server:

    docker exec crowdsec cscli machines add ${MACHINE_NAME} --auto -f -

The "-f -" matters: without it, cscli tries to write credentials to
/etc/crowdsec/local_api_credentials.yaml by default, which usually already
exists (crowdsec's own engine already uses that file) — you'd hit exactly
that collision error without this flag. "-f -" prints the credentials
straight to your terminal instead, so there's no file to collide with and
nothing left behind on the server to clean up afterward.

It prints a Login and Password (not a ready-to-use token — this tool logs
in fresh on every run, so the credential never goes stale).

Step 2 — save those two values as a small JSON file, e.g. machine.json:

    {"login": "${MACHINE_NAME}", "password": "<password from step 1>"}

Step 3 — this file has to be readable *inside* the troubleshooter
container, so mount it and point the env var at the in-container path —
setting CROWDSEC_MACHINE_CREDENTIALS_FILE alone does nothing on its own,
a bare -e can't reach a file that only exists on the host:

    docker run --rm \\
      -e CROWDSEC_LAPI_URL=... \\
      -e CROWDSEC_MACHINE_CREDENTIALS_FILE=/creds/machine.json \\
      -v /path/on/host/machine.json:/creds/machine.json:ro \\
      modem7/crowdsec-troubleshooter live-test --target-url https://your-service.example.com

To undo this later, run:

    docker exec crowdsec cscli machines delete ${MACHINE_NAME}

...then delete the credentials file and unset
CROWDSEC_MACHINE_CREDENTIALS_FILE. (See setup/unregister_machine.sh for the
same instructions on demand.)

EOF
