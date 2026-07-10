#!/usr/bin/env bats
# known_issues.bats — the KB itself (lib/known_issues.sh) plus the
# `troubleshoot.sh issues` dispatch that has to work with zero credentials
# and zero network access (the whole point of shipping it in the image for
# airgapped use).

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  source lib/known_issues.sh
}

@test "sourcing lib/known_issues.sh does not require any CROWDSEC_* env var" {
  # setup() already sourced it with a clean env — if it needed credentials
  # to even load, setup itself would have failed.
  declare -F kb_list >/dev/null
}

@test "every KB_ORDER id has a matching KB_ISSUES entry" {
  for id in "${KB_ORDER[@]}"; do
    [[ -n "${KB_ISSUES[$id]:-}" ]]
  done
}

@test "every KB_ISSUES key appears in KB_ORDER (nothing orphaned from the listing)" {
  for id in "${!KB_ISSUES[@]}"; do
    [[ " ${KB_ORDER[*]} " == *" ${id} "* ]]
  done
}

@test "every entry has exactly 5 pipe-delimited fields, all non-empty" {
  for id in "${KB_ORDER[@]}"; do
    IFS='|' read -r title component symptom fix link <<<"${KB_ISSUES[$id]}"
    [[ -n "$title" && -n "$component" && -n "$symptom" && -n "$fix" && -n "$link" ]]
    field_count="$(grep -o '|' <<<"${KB_ISSUES[$id]}" | wc -l)"
    [ "$field_count" -eq 4 ]
  done
}

@test "every entry's link is a real https URL, not a bare issue number or TODO" {
  for id in "${KB_ORDER[@]}"; do
    IFS='|' read -r _ _ _ _ link <<<"${KB_ISSUES[$id]}"
    [[ "$link" == https://* ]]
  done
}

@test "kb_list prints every id and groups by component" {
  run kb_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"traefik-plugin-tls-mtls-confusion"* ]]
  [[ "$output" == *"── crowdsec-core ──"* ]]
  [[ "$output" == *"── traefik-plugin ──"* ]]
}

@test "kb_show prints title, symptom, fix, and link for a known id" {
  run kb_show "docker-lapi-key-persistence"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Bouncer API keys reset"* ]]
  [[ "$output" == *"Symptom:"* ]]
  [[ "$output" == *"Fix:"* ]]
  [[ "$output" == *"https://github.com/crowdsecurity/crowdsec/issues/3603"* ]]
}

@test "kb_show fails cleanly (not a crash) on an unknown id" {
  run kb_show "this-id-does-not-exist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No known-issue entry"* ]]
}

@test "kb_search matches case-insensitively across title/symptom/fix text" {
  run kb_search "BRIDGE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"traefik-plugin-sees-docker-bridge-ip"* ]]
}

@test "kb_search reports no matches rather than erroring on an unmatched term" {
  run kb_search "definitely-not-a-real-term-xyz"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No known-issue entries matched"* ]]
}

@test "kb_search with no term prints usage instead of silently matching everything" {
  run kb_search ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "troubleshoot.sh issues works with zero CROWDSEC_* env vars set (airgapped case)" {
  env -i PATH="$PATH" bash troubleshoot.sh issues >/tmp/issues_out 2>&1
  status=$?
  output="$(cat /tmp/issues_out)"
  rm -f /tmp/issues_out
  [ "$status" -eq 0 ]
  [[ "$output" != *"CROWDSEC_LAPI_URL is not set"* ]]
  [[ "$output" == *"Known-issues KB"* ]]
}

@test "troubleshoot.sh issues <id> dispatches to kb_show" {
  env -i PATH="$PATH" bash troubleshoot.sh issues docker-lapi-key-persistence >/tmp/issues_out2 2>&1
  output="$(cat /tmp/issues_out2)"
  rm -f /tmp/issues_out2
  [[ "$output" == *"Bouncer API keys reset"* ]]
}

@test "troubleshoot.sh issues search <term> dispatches to kb_search" {
  env -i PATH="$PATH" bash troubleshoot.sh issues search nftables >/tmp/issues_out3 2>&1
  output="$(cat /tmp/issues_out3)"
  rm -f /tmp/issues_out3
  [[ "$output" == *"firewall-bouncer-nftables-cidr-not-blocked"* ]]
}
