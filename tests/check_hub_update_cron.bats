#!/usr/bin/env bats
# check_hub_update_cron.sh — always prints the advisory (tier0, no
# credential, no mount required), and upgrades to a confirmed/missing
# finding if a crontab is optionally mounted. Deliberately not gated
# behind the 🔒 skip() pattern — see the script's own header comment for
# why: this advice is universally relevant, unlike genuinely optional
# integrations.
#
# CRON_MOUNT_BASE is a test-only override (same pattern as
# GITHUB_API_BASE/IP_ECHO_URL elsewhere) so these tests use a tmpdir
# instead of writing into the real, fixed /mnt/cron container path.

load test_helper.bash

CHECK="checks/tier0_no_credential/check_hub_update_cron.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "prints the advisory (not a 🔒 skip block) when no crontab is mounted" {
  export CRON_MOUNT_BASE="/does/not/exist"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Recommended: a periodic cron job"* ]]
  [[ "$output" != *"🔒"* ]]
}

@test "confirms the cron job when both commands are found in a mounted crontab file" {
  tmpdir="$(mktemp -d)"
  echo "0 3 * * 0 docker exec crowdsec cscli hub update && docker exec crowdsec cscli hub upgrade" > "${tmpdir}/crontab"
  export CRON_MOUNT_BASE="$tmpdir"
  run bash "$CHECK"
  rm -rf "$tmpdir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Found a cron job running cscli hub update/upgrade"* ]]
}

@test "warns when a crontab is mounted but the commands aren't in it" {
  tmpdir="$(mktemp -d)"
  echo "0 3 * * 0 echo unrelated job" > "${tmpdir}/crontab"
  export CRON_MOUNT_BASE="$tmpdir"
  run bash "$CHECK"
  rm -rf "$tmpdir"
  [[ "$output" == *"No cron job found"* ]]
}

@test "finds the commands split across two files in a mounted cron.d directory" {
  tmpdir="$(mktemp -d)"
  mkdir -p "${tmpdir}/cron.d"
  echo "0 3 * * 0 docker exec crowdsec cscli hub update" > "${tmpdir}/cron.d/update"
  echo "5 3 * * 0 docker exec crowdsec cscli hub upgrade" > "${tmpdir}/cron.d/upgrade"
  export CRON_MOUNT_BASE="$tmpdir"
  run bash "$CHECK"
  rm -rf "$tmpdir"
  [[ "$output" == *"Found a cron job running cscli hub update/upgrade"* ]]
}
