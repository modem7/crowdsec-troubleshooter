#!/usr/bin/env bats
# check_bouncer_type.sh merges what used to be two separate checks (legacy
# ForwardAuth-style bouncer fingerprint + modern Traefik plugin bouncer
# fingerprint) into one, since the plugin check was never actually wired
# into troubleshoot.sh's tier0 sweep before (see DESIGN.md). Covers every
# combination of the two independent env vars.
#
# HAS_BOUNCER_URL/HAS_TRAEFIK_API are normally set by capability_check.sh
# based on whether TRAEFIK_BOUNCER_URL/TRAEFIK_API_URL are non-empty — this
# check doesn't compute them itself, so tests must export both the flag
# and the URL, not just the URL (capability_check.sh isn't sourced here).

load test_helper.bash

CHECK="checks/tier0_no_credential/check_bouncer_type.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  unset TRAEFIK_BOUNCER_URL TRAEFIK_API_URL HAS_BOUNCER_URL HAS_TRAEFIK_API
}

@test "skips cleanly when neither TRAEFIK_BOUNCER_URL nor TRAEFIK_API_URL is set" {
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TRAEFIK_BOUNCER_URL"* ]]
  [[ "$output" == *"TRAEFIK_API_URL"* ]]
}

@test "detects the legacy bouncer when TRAEFIK_BOUNCER_URL responds with pong" {
  start_mock_lapi 8214 "    def do_GET(self):
        if self.path == '/api/v1/ping':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{\"message\": \"pong\"}')
        else:
            self.send_response(404); self.end_headers()"
  export HAS_BOUNCER_URL=true
  export TRAEFIK_BOUNCER_URL="http://127.0.0.1:8214"
  run bash "$CHECK"
  stop_mock_lapi 8214
  [[ "$output" == *"Legacy ForwardAuth-style Traefik bouncer detected"* ]]
}

@test "reports no legacy bouncer found, and does not claim that as plugin confirmation" {
  start_mock_lapi 8215 "    def do_GET(self):
        self.send_response(404); self.end_headers()"
  export HAS_BOUNCER_URL=true
  export TRAEFIK_BOUNCER_URL="http://127.0.0.1:8215"
  run bash "$CHECK"
  stop_mock_lapi 8215
  [[ "$output" == *"No legacy-style bouncer found"* ]]
  [[ "$output" == *"does NOT confirm"* ]]
}

@test "detects the modern plugin bouncer when Traefik's middleware API lists a crowdsec plugin" {
  start_mock_lapi 8216 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[{\"provider\": \"docker-crowdsec-bouncer-plugin\", \"plugin\": {}}]')"
  export HAS_TRAEFIK_API=true
  export TRAEFIK_API_URL="http://127.0.0.1:8216"
  run bash "$CHECK"
  stop_mock_lapi 8216
  [[ "$output" == *"Modern Traefik plugin bouncer detected"* ]]
}

@test "reports no plugin middleware found when Traefik's API has no matching provider" {
  start_mock_lapi 8217 "    def do_GET(self):
        self.send_response(200); self.end_headers()
        self.wfile.write(b'[{\"provider\": \"docker\", \"plugin\": null}]')"
  export HAS_TRAEFIK_API=true
  export TRAEFIK_API_URL="http://127.0.0.1:8217"
  run bash "$CHECK"
  stop_mock_lapi 8217
  [[ "$output" == *"No crowdsec plugin middleware found"* ]]
}

@test "reports unreachable Traefik API distinctly, not silently as no-plugin-found" {
  export HAS_TRAEFIK_API=true
  export TRAEFIK_API_URL="http://127.0.0.1:1"
  run bash "$CHECK"
  [[ "$output" == *"Couldn't reach Traefik's API"* ]]
}

@test "checks both independently and reports both results when both env vars are set" {
  start_mock_lapi 8218 "    def do_GET(self):
        if self.path == '/api/v1/ping':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{\"message\": \"pong\"}')
        elif self.path == '/api/http/middlewares':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'[]')
        else:
            self.send_response(404); self.end_headers()"
  export HAS_BOUNCER_URL=true
  export HAS_TRAEFIK_API=true
  export TRAEFIK_BOUNCER_URL="http://127.0.0.1:8218"
  export TRAEFIK_API_URL="http://127.0.0.1:8218"
  run bash "$CHECK"
  stop_mock_lapi 8218
  [[ "$output" == *"Legacy ForwardAuth-style Traefik bouncer detected"* ]]
  [[ "$output" != *"Modern Traefik plugin bouncer detected"* ]]
}

@test "reports neither confirmed when both are set but neither fingerprint matches" {
  start_mock_lapi 8219 "    def do_GET(self):
        if self.path == '/api/http/middlewares':
            self.send_response(200); self.end_headers()
            self.wfile.write(b'[]')
        else:
            self.send_response(404); self.end_headers()"
  export HAS_BOUNCER_URL=true
  export HAS_TRAEFIK_API=true
  export TRAEFIK_BOUNCER_URL="http://127.0.0.1:8219"
  export TRAEFIK_API_URL="http://127.0.0.1:8219"
  run bash "$CHECK"
  stop_mock_lapi 8219
  [[ "$output" == *"Neither the legacy bouncer nor the modern plugin bouncer could be confirmed"* ]]
}
