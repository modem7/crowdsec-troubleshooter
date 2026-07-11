#!/usr/bin/env bats
# Locks in that `troubleshoot.sh appsec-test --target-url <url>` dispatches
# to test_appsec_probe.sh, mirroring live-test's own wiring. Check-script
# logic itself is covered by test_appsec_probe.bats; this just proves the
# CLI action reaches it.

load test_helper.bash

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  export APPSEC_PROBE_POLL_ATTEMPTS=1
  export APPSEC_PROBE_POLL_INTERVAL=1
}

@test "appsec-test dispatches to test_appsec_probe.sh and skips cleanly with no machine creds" {
  start_mock_lapi 8226 "    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers()
        else:
            self.send_response(404); self.end_headers()"
  export CROWDSEC_LAPI_URL="http://127.0.0.1:8226"
  unset CROWDSEC_LAPI_KEY CROWDSEC_MACHINE_CREDENTIALS_FILE
  run bash troubleshoot.sh appsec-test --target-url http://example.invalid
  stop_mock_lapi 8226
  [ "$status" -eq 0 ]
  [[ "$output" == *"AppSec/WAF pipeline"* ]]
}
