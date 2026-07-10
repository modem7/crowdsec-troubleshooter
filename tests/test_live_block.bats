#!/usr/bin/env bats
# Regression coverage for the login/password -> fresh-token exchange added
# after the original approach turned out to expect a `.token` field that
# `cscli machines add --auto` never actually produces (see DESIGN.md's
# corrections list). Also covers the skip path and a rejected login.
#
# IP_ECHO_URL lets the self-IP lookup be redirected at the mock server
# instead of the real https://api.ipify.org — keeps this suite from
# depending on outbound internet access in CI.

load test_helper.bash

CHECK="checks/tier2_machine/test_live_block.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "skips cleanly when HAS_MACHINE_CREDS is false" {
  export HAS_MACHINE_CREDS=false
  run bash "$CHECK" --target-url http://example.invalid
  [ "$status" -eq 0 ]
  [[ "$output" == *"cscli machines add troubleshooter --auto"* ]]
  [[ "$output" == *"Save them as JSON"* ]]
}

@test "fails clearly when the credentials file is missing login/password" {
  export HAS_MACHINE_CREDS=true
  tmpfile="$(mktemp)"
  echo '{"token":"leftover-from-old-format"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url http://example.invalid
  rm -f "$tmpfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't read login/password"* ]]
}

@test "fails clearly when machine login is rejected" {
  start_mock_lapi 8206 "    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{}')"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8206"
  export IP_ECHO_URL="http://127.0.0.1:8206/ip"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"wrong"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url http://example.invalid
  stop_mock_lapi 8206
  rm -f "$tmpfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Machine login failed"* ]]
}

@test "mints a fresh token and confirms blocking end-to-end on the happy path" {
  # POST /v1/alerts, not /v1/decisions — there is no POST /v1/decisions on
  # a real LAPI; cscli's own decisions-add builds a synthetic Alert and
  # posts that instead (see the comment in test_live_block.sh). A prior
  # version of this test mocked a generic 200 response for any POST path,
  # which is exactly how this bug shipped without a test catching it: the
  # mock accepted a request shape the real LAPI never would have. Real LAPI
  # returns 201 Created on success, not 200 — asserted here specifically so
  # this can't regress back to accepting any 2xx.
  start_mock_lapi 8207 "    def do_GET(self):
        if self.path == '/ip':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'203.0.113.7')
        else:
            self.send_response(403); self.end_headers()
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        if self.path == '/v1/watchers/login':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{\"token\": \"mock-token-123\"}')
        elif self.path == '/v1/alerts':
            self.send_response(201); self.end_headers()
            self.wfile.write(b'[\"1\"]')
        else:
            # anything else, notably the old (wrong) /v1/decisions POST,
            # 404s here on purpose — a real LAPI has no such route either
            self.send_response(404); self.end_headers()
    def do_DELETE(self):
        self.send_response(200); self.end_headers()"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8207"
  export IP_ECHO_URL="http://127.0.0.1:8207/ip"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url "http://127.0.0.1:8207/protected"
  stop_mock_lapi 8207
  rm -f "$tmpfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Logging in as machine 'tester'"* ]]
  [[ "$output" == *"blocking confirmed working end-to-end"* ]]
}

@test "prints LAPI's actual error body on a failed decision add, not a generic credentials guess" {
  # This is the exact bug found by a real user running live-test against a
  # real LAPI: the old code used `curl -f`, which discards the response
  # body on any 4xx/5xx, so a real rejection reason was never visible —
  # just a blind "check your credentials" guess. Locking in that the real
  # LAPI error message now actually reaches the user.
  start_mock_lapi 8208 "    def do_GET(self):
        if self.path == '/ip':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'203.0.113.7')
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        if self.path == '/v1/watchers/login':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{\"token\": \"mock-token-123\"}')
        elif self.path == '/v1/alerts':
            self.send_response(403); self.end_headers()
            self.wfile.write(b'{\"message\": \"access forbidden\"}')"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8208"
  export IP_ECHO_URL="http://127.0.0.1:8208/ip"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url "http://127.0.0.1:8208/protected"
  stop_mock_lapi 8208
  rm -f "$tmpfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HTTP 403"* ]]
  [[ "$output" == *"access forbidden"* ]]
}
