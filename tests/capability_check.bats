#!/usr/bin/env bats
# The capability guard is the single most load-bearing file in this repo —
# every check's safety depends on it correctly reporting what's available.
# Bugs here are the highest-consequence kind: a false "available" could make
# a check attempt something it has no business attempting.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "fails clearly when CROWDSEC_LAPI_URL is unset" {
  unset CROWDSEC_LAPI_URL
  run bash capability_check.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CROWDSEC_LAPI_URL is not set"* ]]
}

@test "HAS_BOUNCER_KEY is false when CROWDSEC_LAPI_KEY is unset" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  unset CROWDSEC_LAPI_KEY
  source capability_check.sh
  [ "$HAS_BOUNCER_KEY" = "false" ]
}

@test "HAS_BOUNCER_KEY is true when CROWDSEC_LAPI_KEY is set" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  export CROWDSEC_LAPI_KEY="some-key"
  source capability_check.sh
  [ "$HAS_BOUNCER_KEY" = "true" ]
}

@test "HAS_MACHINE_CREDS is false when the credentials file doesn't exist" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="/nonexistent/path"
  source capability_check.sh
  [ "$HAS_MACHINE_CREDS" = "false" ]
}

@test "HAS_MACHINE_CREDS is true when the credentials file exists and is readable" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  tmpfile="$(mktemp)"
  echo '{"token":"x"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  source capability_check.sh
  rm -f "$tmpfile"
  [ "$HAS_MACHINE_CREDS" = "true" ]
}

@test "DETECTED_TIER auto-detects correctly across all three combinations" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  unset CROWDSEC_LAPI_KEY CROWDSEC_MACHINE_CREDENTIALS_FILE
  source capability_check.sh
  [ "$DETECTED_TIER" = "0" ]

  export CROWDSEC_LAPI_KEY="some-key"
  source capability_check.sh
  [ "$DETECTED_TIER" = "1" ]

  tmpfile="$(mktemp)"
  echo '{"token":"x"}' > "$tmpfile"
  export CROWDSEC_MACHINE_CREDENTIALS_FILE="$tmpfile"
  source capability_check.sh
  rm -f "$tmpfile"
  [ "$DETECTED_TIER" = "2" ]
}
