#!/usr/bin/env bats
# Pure logic, no network — fast tests, run these liberally.

CHECK="checks/tier0_no_credential/check_lapi_url_scope.sh"

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "flags a private LAN IP as consistent with a published host port" {
  export CROWDSEC_LAPI_URL="http://192.168.1.50:19818"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]
}

@test "flags 10.x range too" {
  export CROWDSEC_LAPI_URL="http://10.0.0.5:8080"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]
}

@test "flags 172.16-31.x range but not other 172.x" {
  export CROWDSEC_LAPI_URL="http://172.20.0.1:8080"
  run bash "$CHECK"
  [[ "$output" == *"points at a LAN IP"* ]]

  export CROWDSEC_LAPI_URL="http://172.64.0.1:8080"
  run bash "$CHECK"
  [[ "$output" != *"points at a LAN IP"* ]]
}

@test "does not flag a docker-compose service name" {
  export CROWDSEC_LAPI_URL="http://crowdsec:8080"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"looks like internal docker networking"* ]]
}

@test "flags any dotted local-DNS hostname, not just one example name" {
  # The rule is "contains a dot and isn't a raw IPv4 literal" — deliberately
  # exercised against several unrelated naming conventions people actually
  # use for LAN DNS (mDNS .local, a custom internal zone, a router-assigned
  # .home suffix, ...) so this can't silently regress into being keyed off
  # one specific hostname.
  for host in hda.home bob.home fred.local nas.lan homelab.internal; do
    export CROWDSEC_LAPI_URL="http://${host}:19818"
    run bash "$CHECK"
    [[ "$output" == *"points at a DNS hostname (${host})"* ]] || {
      echo "expected a DNS-hostname warning for ${host}, got: $output"
      return 1
    }
  done
}

@test "flags a public FQDN too" {
  export CROWDSEC_LAPI_URL="https://crowdsec.example.com:8080"
  run bash "$CHECK"
  [[ "$output" == *"points at a DNS hostname"* ]]
}

@test "does not flag a public IP outside private ranges" {
  export CROWDSEC_LAPI_URL="http://172.64.0.1:8080"
  run bash "$CHECK"
  [[ "$output" == *"looks like internal docker networking"* ]]
}

@test "KNOWN LIMITATION: a bare single-label LAN hostname is indistinguishable from a compose service name" {
  # Documents the gap called out in the header comment, deliberately, so a
  # future change to this behavior is a conscious decision and not a
  # silent regression either direction. "nas" here is syntactically
  # identical to a docker-compose service name — this heuristic cannot
  # tell them apart without actually resolving DNS, which this tool
  # deliberately doesn't do (see DESIGN.md).
  export CROWDSEC_LAPI_URL="http://nas:8080"
  run bash "$CHECK"
  [[ "$output" == *"looks like internal docker networking"* ]]
}
