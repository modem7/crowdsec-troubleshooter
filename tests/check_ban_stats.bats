#!/usr/bin/env bats
# check_ban_stats.sh — GET /v1/decisions with no filter, same read path and
# credential as check_ip.sh (tier1_bouncer_key/check_ip.sh), just without
# the ?ip= filter. Unlike check-ip, this needs no argument, so it's the one
# tier1 check troubleshoot.sh runs automatically — see its own bats
# coverage for the wiring, this file only covers the check script itself.

load test_helper.bash

CHECK="checks/tier1_bouncer_key/check_ban_stats.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "skips cleanly when HAS_BOUNCER_KEY is false" {
  export HAS_BOUNCER_KEY=false
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"🔒"* ]]
  [[ "$output" == *"ban stats"* ]]
}

@test "fails clearly when LAPI is unreachable" {
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:1"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't reach LAPI"* ]]
}

@test "reports no active decisions without treating it as a failure" {
  start_mock_lapi 8222 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[]')"
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8222"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK"
  stop_mock_lapi 8222
  [ "$status" -eq 0 ]
  [[ "$output" == *"No active decisions"* ]]
}

@test "counts decisions and breaks them down by scope and origin" {
  start_mock_lapi 8223 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[{\"scope\":\"Ip\",\"origin\":\"crowdsec\"},{\"scope\":\"Ip\",\"origin\":\"CAPI\"},{\"scope\":\"Range\",\"origin\":\"CAPI\"}]')"
  export HAS_BOUNCER_KEY=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8223"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash "$CHECK"
  stop_mock_lapi 8223
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 decision(s) currently active"* ]]
  [[ "$output" == *"Ip: 2"* ]]
  [[ "$output" == *"Range: 1"* ]]
  [[ "$output" == *"CAPI: 2"* ]]
  [[ "$output" == *"crowdsec: 1"* ]]
}
