#!/usr/bin/env bats
load test_helper.bash

CHECK="checks/tier0_no_credential/check_lapi_alive.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "reports OK when /health returns 200" {
  start_mock_lapi 8204 "    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers()
        else:
            self.send_response(404); self.end_headers()"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8204"
  run bash "$CHECK"
  stop_mock_lapi 8204
  [ "$status" -eq 0 ]
  [[ "$output" == *"is up and responding"* ]]
}

@test "reports CRIT (not a silent pass) when LAPI is unreachable" {
  export CROWDSEC_LAPI_URL="http://127.0.0.1:1"
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Can't reach LAPI"* ]]
}

@test "reports WARN when something responds but not with 200" {
  start_mock_lapi 8205 "    def do_GET(self):
        self.send_response(500); self.end_headers()"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8205"
  run bash "$CHECK"
  stop_mock_lapi 8205
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 500"* ]]
}
