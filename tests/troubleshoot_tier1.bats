#!/usr/bin/env bats
# troubleshoot.sh's run_tier1() — locks in that check_ban_stats.sh (no
# argument needed) actually runs as part of --tier 1, unlike check-ip
# (which stays a named action since it needs an IP). End-to-end against a
# real troubleshoot.sh invocation and a mock LAPI, not just the check
# script in isolation (see check_ban_stats.bats for that).

load test_helper.bash

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "--tier 1 runs check_ban_stats.sh and reports its result, plus the check-ip reminder" {
  start_mock_lapi 8224 "    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers()
        elif self.path == '/v1/decisions':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'[{\"scope\":\"Ip\",\"origin\":\"crowdsec\"}]')
        else:
            self.send_response(404); self.end_headers()"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8224"
  export CROWDSEC_LAPI_KEY="test-key"
  run bash troubleshoot.sh --tier 1
  stop_mock_lapi 8224
  [[ "$output" == *"1 decision(s) currently active"* ]]
  [[ "$output" == *"check-ip <ip> is a separate named action"* ]]
}

@test "--tier 1 with no bouncer key defers check_ban_stats.sh to the Optional checks footer" {
  start_mock_lapi 8225 "    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers()
        else:
            self.send_response(404); self.end_headers()"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8225"
  unset CROWDSEC_LAPI_KEY
  run bash troubleshoot.sh --tier 1
  stop_mock_lapi 8225
  [[ "$output" == *"Optional checks (not configured)"* ]]
  [[ "$output" == *"Showing current ban stats"* ]]
}
