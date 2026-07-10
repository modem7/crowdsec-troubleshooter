#!/usr/bin/env bats
# wizard.sh runs on the host (not inside the container) and is mostly
# interactive prompts + `exec docker`, so it isn't a good fit for the
# run-and-check-exit-code pattern used elsewhere in this suite. Its main
# flow is guarded behind `[[ "${BASH_SOURCE[0]}" != "${0}" ]]` specifically
# so tests can `source` it and exercise the pure logic — compose parsing
# and default-resolution — directly, without needing docker installed or a
# TTY to answer prompts.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source wizard.sh
}

@test "sourcing wizard.sh does not require docker or trigger the interactive flow" {
  # setup() already sourced it without error — if the main flow's docker
  # guard or prompts had fired, setup itself would have failed the test.
  declare -F extract_service_block >/dev/null
}

@test "extract_service_block finds the crowdsec service by image and stops at the next service" {
  run extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$'
  [ "$status" -eq 0 ]
  [[ "$output" == *"crowdsec:"* ]]
  [[ "$output" == *'"19818:8080"'* ]]
  [[ "$output" != *"traefik-bouncer:"* ]]
}

@test "extract_service_block fails cleanly when no service matches" {
  run extract_service_block tests/fixtures/sample-compose.yml 'image:.*nonexistent-image'
  [ "$status" -ne 0 ]
}

@test "extract_yaml_list pulls ports out of a service block, quotes stripped" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$')"
  result="$(echo "$block" | extract_yaml_list ports)"
  [[ "$result" == *"19818:8080"* ]]
  [[ "$result" == *"16934:6060"* ]]
}

@test "extract_yaml_child_keys pulls network names from mapping-style networks:" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:[[:space:]]*"?crowdsecurity/crowdsec"?[[:space:]]*$')"
  result="$(echo "$block" | extract_yaml_child_keys networks)"
  [ "$result" = "pihole" ]
}

@test "extract_env_value reads a literal KEY=value from environment: list entries" {
  block="$(extract_service_block tests/fixtures/sample-compose.yml 'image:.*traefik-crowdsec-bouncer')"
  result="$(echo "$block" | extract_env_value PORT)"
  [ "$result" = "8080" ]
}

@test "resolve_default prefers an exported env var over a saved or compose value" {
  declare -gA PREV=([CROWDSEC_LAPI_URL]="http://from-file:1")
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  export CROWDSEC_LAPI_URL="http://from-env:3"
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  unset CROWDSEC_LAPI_URL
  [ "$result" = "http://from-env:3" ]
}

@test "resolve_default falls back to the saved file value when no env var is set" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=([CROWDSEC_LAPI_URL]="http://from-file:1")
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ "$result" = "http://from-file:1" ]
}

@test "resolve_default falls back to the compose suggestion when nothing else is set" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=()
  declare -gA COMPOSE=([CROWDSEC_LAPI_URL]="http://from-compose:2")
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ "$result" = "http://from-compose:2" ]
}

@test "resolve_default returns empty when nothing is set anywhere" {
  unset CROWDSEC_LAPI_URL 2>/dev/null || true
  declare -gA PREV=()
  declare -gA COMPOSE=()
  result="$(resolve_default CROWDSEC_LAPI_URL)"
  [ -z "$result" ]
}

@test "json_escape escapes embedded quotes and backslashes" {
  result="$(json_escape 'pass"word\with\stuff')"
  [ "$result" = 'pass\"word\\with\\stuff' ]
}

@test "load_creds_file populates PREV from a KEY=VALUE env file, ignoring comments and blanks" {
  tmpfile="$(mktemp)"
  cat > "$tmpfile" <<'EOF'
# a comment
CROWDSEC_LAPI_URL=http://saved:8080

CROWDSEC_LAPI_KEY=abc123
EOF
  declare -gA PREV=()
  load_creds_file "$tmpfile"
  rm -f "$tmpfile"
  [ "${PREV[CROWDSEC_LAPI_URL]}" = "http://saved:8080" ]
  [ "${PREV[CROWDSEC_LAPI_KEY]}" = "abc123" ]
}

# detect_crowdsec_compose_file calls the real `docker` binary, which isn't
# assumed to be installed wherever these bats tests run — stubbed with a
# bash function of the same name rather than skipped, so the actual
# label-parsing/path-resolution logic still gets exercised. See the
# manual claude-vm verification (a real container, real labels, real
# `docker inspect`) in the commit/PR notes for the real-binary check this
# can't cover.

@test "detect_crowdsec_compose_file resolves a relative config_files path against working_dir" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/docker-compose.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec:v1.6.3\n' ;;
      inspect)
        if [[ "$3" == *working_dir* ]]; then echo "$tmpdir"
        elif [[ "$3" == *config_files* ]]; then echo "docker-compose.yml"
        fi ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/docker-compose.yml" ]
}

@test "detect_crowdsec_compose_file accepts an absolute config_files path as-is" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/custom.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect)
        if [[ "$3" == *working_dir* ]]; then echo "/some/unrelated/dir"
        elif [[ "$3" == *config_files* ]]; then echo "${tmpdir}/custom.yml"
        fi ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/custom.yml" ]
}

@test "detect_crowdsec_compose_file falls back to docker-compose.yml when config_files label is absent" {
  tmpdir="$(mktemp -d)"
  touch "${tmpdir}/docker-compose.yml"
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect)
        if [[ "$3" == *working_dir* ]]; then echo "$tmpdir"
        elif [[ "$3" == *config_files* ]]; then echo "<no value>"
        fi ;;
    esac
  }
  result="$(detect_crowdsec_compose_file)"
  rm -rf "$tmpdir"
  [ "$result" = "${tmpdir}/docker-compose.yml" ]
}

@test "detect_crowdsec_compose_file fails cleanly when no crowdsec container is running" {
  docker() {
    case "$1" in
      ps) printf 'somethingelse\tnginx:latest\n' ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "detect_crowdsec_compose_file fails cleanly when the container isn't Compose-managed (no working_dir label)" {
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect) echo "<no value>" ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
}

@test "detect_crowdsec_compose_file fails cleanly when the resolved file isn't actually readable" {
  docker() {
    case "$1" in
      ps) printf 'mycontainer\tcrowdsecurity/crowdsec\n' ;;
      inspect)
        if [[ "$3" == *working_dir* ]]; then echo "/definitely/does/not/exist"
        elif [[ "$3" == *config_files* ]]; then echo "docker-compose.yml"
        fi ;;
    esac
  }
  run detect_crowdsec_compose_file
  [ "$status" -ne 0 ]
}
