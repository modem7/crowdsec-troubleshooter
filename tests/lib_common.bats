#!/usr/bin/env bats
# Regression test for a real bug: curl's -w "%{http_code}" already prints
# "000" on connection failure, but an earlier version of http_status()
# appended `|| echo "000"` on top of that, producing a concatenated
# "000000" instead. Caught by manual smoke-testing, not by code review —
# codified here so it can't silently come back.

load test_helper.bash

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source lib/common.sh
}

@test "http_status returns exactly '000' (not '000000') on connection refused" {
  run http_status "http://127.0.0.1:1"
  [ "$status" -eq 0 ]  # http_status itself should not fail, it reports via output
  [ "$output" = "000" ]
}

@test "http_status returns the real status code on a reachable server" {
  start_mock_lapi 8201 "    def do_GET(self):
        self.send_response(204); self.end_headers()"
  run http_status "http://127.0.0.1:8201/"
  stop_mock_lapi 8201
  [ "$output" = "204" ]
}

@test "http_get returns empty string (not garbage) when the server is unreachable" {
  run http_get "http://127.0.0.1:1/health"
  [ -z "$output" ]
}
