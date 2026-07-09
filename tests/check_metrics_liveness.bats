#!/usr/bin/env bats
# Regression test for a real bug: awk's `END {print sum+0}` always produces
# output ("0") even on completely empty input, so checking the summarized
# value for emptiness could never actually detect an unreachable metrics
# endpoint — it would silently report "0 events" and carry on instead of
# failing with a clear CRIT/WARN. Caught by manual smoke-testing against a
# deliberately-unreachable mock; codified here so it can't come back
# disguised as a "small refactor" later.

load test_helper.bash

CHECK="checks/tier0_no_credential/check_metrics_liveness.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "reports unreachable (not silently '0 events') when metrics endpoint doesn't respond" {
  export CROWDSEC_LAPI_URL="http://127.0.0.1:1"
  export CROWDSEC_METRICS_URL="http://127.0.0.1:1"
  run bash "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't reach the metrics endpoint"* ]]
  [[ "$output" != *"0 new events"* ]]
}

@test "reports increasing activity when the counter actually moves between polls" {
  start_mock_lapi 8202 "    _n = 0
    def do_GET(self):
        H._n += 15
        self.send_response(200); self.end_headers()
        self.wfile.write(('cs_filesource_hits_total{source=\"x\"} %d\n' % H._n).encode())"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8202"
  export CROWDSEC_METRICS_URL="http://127.0.0.1:8202"
  export METRICS_POLL_GAP=1
  run bash "$CHECK"
  stop_mock_lapi 8202
  [ "$status" -eq 0 ]
  [[ "$output" == *"actively being read and analyzed"* ]]
}

@test "reports no new activity (not a crash) when the counter is flat between polls" {
  start_mock_lapi 8203 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'cs_filesource_hits_total{source=\"x\"} 7\n')"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8203"
  export CROWDSEC_METRICS_URL="http://127.0.0.1:8203"
  export METRICS_POLL_GAP=1
  run bash "$CHECK"
  stop_mock_lapi 8203
  [ "$status" -eq 0 ]
  [[ "$output" == *"No new log activity"* ]]
}
