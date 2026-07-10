#!/usr/bin/env bats
# check_image_freshness.sh compares the git commit baked into the image
# (IMAGE_GIT_SHA) against GitHub's latest master commit. Mocking GitHub's
# API via GITHUB_API_BASE, same pattern as IP_ECHO_URL in
# test_live_block.bats — keeps this suite from depending on real network
# access or GitHub's actual commit history.

load test_helper.bash

CHECK="checks/tier0_no_credential/check_image_freshness.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "skips gracefully when IMAGE_GIT_SHA is unset (a local docker build)" {
  unset IMAGE_GIT_SHA
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wasn't built with GIT_SHA set"* ]]
}

@test "reports OK when the built commit matches the latest on master" {
  start_mock_lapi 8208 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"sha\": \"abc1234def5678900000000000000000000000\"}')"
  export IMAGE_GIT_SHA="abc1234000000000000000000000000000000000"
  export GITHUB_API_BASE="http://127.0.0.1:8208"
  run bash "$CHECK"
  stop_mock_lapi 8208
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running the latest published build"* ]]
}

@test "reports WARN with a pull instruction when the built commit is behind" {
  start_mock_lapi 8209 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"sha\": \"zzz9999def5678900000000000000000000000\"}')"
  export IMAGE_GIT_SHA="abc1234000000000000000000000000000000000"
  export GITHUB_API_BASE="http://127.0.0.1:8209"
  run bash "$CHECK"
  stop_mock_lapi 8209
  [[ "$output" == *"older commit"* ]]
  [[ "$output" == *"docker pull modem7/crowdsec-troubleshooter:latest"* ]]
}

@test "skips gracefully (not a crash) when GitHub is unreachable" {
  export IMAGE_GIT_SHA="abc1234000000000000000000000000000000000"
  export GITHUB_API_BASE="http://127.0.0.1:1"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Couldn't reach GitHub"* ]]
}

@test "skips gracefully when the response has no sha field (e.g. rate-limited)" {
  # A real rate-limit response is HTTP 403, which curl -f in http_get
  # already turns into an empty response (covered by the unreachable-
  # GitHub test above). This covers the other malformed-response case: a
  # 200 whose body genuinely has no .sha field.
  start_mock_lapi 8211 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{\"message\": \"something unexpected\"}')"
  export IMAGE_GIT_SHA="abc1234000000000000000000000000000000000"
  export GITHUB_API_BASE="http://127.0.0.1:8211"
  run bash "$CHECK"
  stop_mock_lapi 8211
  [ "$status" -eq 0 ]
  [[ "$output" == *"didn't include a commit SHA"* ]]
}
