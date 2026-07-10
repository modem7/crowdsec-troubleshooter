#!/usr/bin/env bats
load test_helper.bash

CHECK="checks/tier1_bouncer_key/check_ip.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "skips cleanly when HAS_BOUNCER_KEY is false" {
  export HAS_BOUNCER_KEY=false
  run bash "$CHECK" 198.51.100.23
  [ "$status" -eq 0 ]
  [[ "$output" == *"cscli bouncers add troubleshooter-readonly"* ]]
}

@test "reports not banned when LAPI returns an empty array" {
  start_mock_lapi 8212 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[]')"
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8212"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK" 198.51.100.23
  stop_mock_lapi 8212
  [ "$status" -eq 0 ]
  [[ "$output" == *"not currently banned"* ]]
}

@test "reports banned with reason and prints the unblock command" {
  start_mock_lapi 8213 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[{\"scenario\": \"crowdsecurity/http-probing\", \"origin\": \"crowdsec\", \"duration\": \"4h\"}]')"
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8213"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK" 198.51.100.23
  stop_mock_lapi 8213
  [ "$status" -eq 0 ]
  [[ "$output" == *"currently banned"* ]]
  [[ "$output" == *"scanning for vulnerabilities"* ]]
  [[ "$output" == *"docker exec crowdsec cscli decisions delete --ip 198.51.100.23"* ]]
  [[ "$output" == *"read-only bouncer"* ]]
}

@test "fails clearly when LAPI is unreachable" {
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:1"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK" 198.51.100.23
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't reach LAPI"* ]]
}
