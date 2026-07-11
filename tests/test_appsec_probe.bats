#!/usr/bin/env bats
# Regression coverage for test_appsec_probe.sh's baseline-then-diff alert
# check. Poll timing is overridden to 1 attempt / near-zero interval via
# APPSEC_PROBE_POLL_ATTEMPTS/APPSEC_PROBE_POLL_INTERVAL so this suite
# doesn't have to burn the real ~15s aggregation-delay window per test.

load test_helper.bash

CHECK="checks/tier2_machine/test_appsec_probe.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  export APPSEC_PROBE_POLL_ATTEMPTS=1
  export APPSEC_PROBE_POLL_INTERVAL=1
}

@test "skips cleanly when HAS_MACHINE_CREDS is false" {
  export HAS_MACHINE_CREDS=false
  run bash "$CHECK" --target-url http://example.invalid
  [ "$status" -eq 0 ]
  [[ "$output" == *"AppSec/WAF pipeline"* ]]
  [[ "$output" == *"test_live_block.sh"* ]]
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

@test "fails clearly when login is rejected before a baseline can be recorded" {
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:1"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url http://example.invalid
  rm -f "$tmpfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Machine login failed"* ]]
}

@test "fails clearly when the alerts endpoint is unreachable after a successful login" {
  # Login succeeds (so a token is minted), but the alerts endpoint itself
  # refuses the request — the one path where the baseline-fetch crit is
  # actually reachable, distinct from a login-time failure.
  start_mock_lapi 8222 "    def do_GET(self):
        self.send_response(500); self.end_headers()
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"token\": \"mock-token-123\"}')"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8222"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url "http://127.0.0.1:8222/probe"
  stop_mock_lapi 8222
  rm -f "$tmpfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Couldn't reach LAPI"* ]]
}

@test "confirms the probe when a new alert appears after the request" {
  # First /v1/alerts hit is the baseline (empty); every hit after that
  # returns one alert — simulating the probe actually having landed.
  start_mock_lapi 8220 "    call_count = 0
    def do_GET(self):
        if self.path.startswith('/v1/alerts'):
            type(self).call_count += 1
            self.send_response(200); self.end_headers()
            if type(self).call_count <= 1:
                self.wfile.write(b'[]')
            else:
                self.wfile.write(b'[{\"id\": 42, \"scenario\": \"crowdsecurity/appsec-generic-test\"}]')
        elif self.path == '/probe':
            self.send_response(200); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"token\": \"mock-token-123\"}')"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8220"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url "http://127.0.0.1:8220/probe"
  stop_mock_lapi 8220
  rm -f "$tmpfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AppSec probe confirmed"* ]]
  [[ "$output" == *"alert id 42"* ]]
}

@test "warns when no new alert appears within the poll window" {
  # Every /v1/alerts hit returns the same fixed alert — baseline and
  # post-probe sets never diverge, so no new id should ever be found.
  start_mock_lapi 8221 "    def do_GET(self):
        if self.path.startswith('/v1/alerts'):
            self.send_response(200); self.end_headers()
            self.wfile.write(b'[{\"id\": 7}]')
        elif self.path == '/probe':
            self.send_response(200); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        self.rfile.read(length)
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"token\": \"mock-token-123\"}')"
  export HAS_MACHINE_CREDS=true
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8221"
  tmpfile="$(mktemp)"
  echo '{"login":"tester","password":"correct"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  run bash "$CHECK" --target-url "http://127.0.0.1:8221/probe"
  stop_mock_lapi 8221
  rm -f "$tmpfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No new crowdsecurity/appsec-generic-test alert appeared"* ]]
  [[ "$output" == *"appsec-generic-test collection isn't installed"* ]]
}
