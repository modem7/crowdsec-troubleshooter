#!/usr/bin/env bats
# Pure logic, no network — fast tests, run these liberally.

CHECK="checks/tier0_no_credential/check_lapi_url_scope.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "flags a private LAN IP as consistent with a published host port" {
  export CROWDSEC_LAPI_URL="http://192.168.1.50:19818"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]
}

@test "flags 10.x range too" {
  export CROWDSEC_LAPI_URL="http://10.0.0.5:8080"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]
}

@test "flags 172.16-31.x range but not other 172.x" {
  export CROWDSEC_LAPI_URL="http://172.20.0.1:8080"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]

  export CROWDSEC_LAPI_URL="http://172.64.0.1:8080"
  run bash "$CHECK"
  [[ "$output" != *"points at a LAN IP"* ]]
}

@test "does not flag a docker-compose service name" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks like internal docker networking"* ]]
}
