#!/usr/bin/env bash
# lib/known_issues.sh — curated knowledge base of common CrowdSec /
# CrowdSec+Traefik problems, kept as data rather than scattered across check
# scripts, since most of these (upstream version bugs, nftables internals)
# have no reliable credential-free detection — they're reference material
# for a human, not something a check can assert pass/fail on.
#
# Sourced lazily (only by the `issues` action, not every wellness run) and
# shipped inside the image, so it's browsable offline/airgapped too.
#
# NOT a live feed — hand-curated from crowdsecurity/crowdsec,
# crowdsecurity/cs-firewall-bouncer, and
# maxlerebourg/crowdsec-bouncer-traefik-plugin issues. Bump KB_VERSION
# whenever entries change.

set -uo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KB_VERSION="2026-07-10"

# -g matters: without it, `declare -A` inside a function scope (e.g. a bats
# `setup()` sourcing this file) makes KB_ISSUES local, vanishing once that
# function returns.
#
# id -> "Title|Component|Symptom|Fix|Link"
# Field separator is a plain pipe — none of the text below contains one.
declare -gA KB_ISSUES=(
  [docker-healthcheck-capi-rate-limit]="Docker healthcheck calling cscli capi status triggers CAPI 403s|crowdsec-core|Container looks unhealthy on a fresh boot and CAPI (community blocklist) calls start returning 403 Forbidden.|A HEALTHCHECK running cscli capi status on an interval re-triggers a full CAPI login every time; enough containers doing this get rate-limited. Healthcheck against cscli lapi status instead.|https://github.com/crowdsecurity/crowdsec/issues/4160#issuecomment-3671583345"
  [v1.7.8-sqlite-lock-cpu]="v1.7.8 SQLite lock contention causes CPU spikes and 500s|crowdsec-core|CPU usage doubles or triples after upgrading to v1.7.8; logs show database is locked and LAPI returns intermittent 500s.|v1.7.8's chunked decision-stream implementation holds SQLite transactions open longer, and dashboards polling /v1/alerts make it worse. Migrate to PostgreSQL/MySQL, or pin to v1.7.7 until a fix lands.|https://github.com/crowdsecurity/crowdsec/issues/4464"
  [appsec-body-size-limit]="AppSec rejects large legitimate request bodies by default|crowdsec-core|Uploads or requests over roughly 134MB get denied by AppSec even though nothing malicious is present.|AppSec's default max body size isn't a plain config value — needs a custom AppSec rule using SetMaxBodySize/SetBodySizeExceededAction.|https://github.com/crowdsecurity/crowdsec/issues/3837#issuecomment-4506444406"
  [appsec-tmp-file-accumulation]="AppSec leaves temp files accumulating in /tmp|crowdsec-core|/tmp fills with crzmp-prefixed files at hundreds of MB/hour after enabling AppSec, eventually filling the container's disk.|No confirmed permanent fix as of this writing (Coraza WAF engine temp-file cleanup). Mitigate by mounting /tmp as tmpfs with a size cap, or scheduling periodic cleanup, and watch container disk usage if AppSec is enabled.|https://github.com/crowdsecurity/crowdsec/issues/3055"
  [decision-stream-dropped]="A specific ban decision never reaches bouncers via the decision stream|crowdsec-core|cscli decisions list shows a ban for an IP, but it never appears in /v1/decisions/stream, so no bouncer ever blocks it.|An LAPI decision-stream edge case dropped certain decisions from the stream response; fixed in a later release. Upgrade LAPI if seen.|https://github.com/crowdsecurity/crowdsec/issues/2014#issuecomment-2803325596"
  [decision-stream-payload-spike]="Full decision list re-sent every ~2h spikes CPU across all bouncers|crowdsec-core|Every couple of hours, /v1/decisions/stream returns a multi-MB payload and every connected bouncer's CPU spikes simultaneously.|The stream re-sent the full decision list periodically instead of true diffs. Enable the chunked_decisions_stream feature flag.|https://docs.crowdsec.net/docs/next/configuration/feature_flags"
  [lapi-port-change-multi-config]="Changing LAPI's port breaks things unless every consumer is updated too|crowdsec-core|LAPI itself starts fine on the new port, but cscli, the firewall bouncer, or the Traefik plugin fail to connect with no obvious error.|The port has to be changed consistently in config.yaml, local_api_credentials.yaml, AND every bouncer's own config file — updating only one of them is the most common trap.|https://github.com/crowdsecurity/crowdsec/issues/3096#issuecomment-2191409607"
  [v1.6.0-docker-whitelist-crash]="v1.6.0 Docker image fails to start when a whitelist parser is configured|crowdsec-core|Upgrading the Docker image from 1.5.5 to 1.6.0 causes the container to fail startup while processing whitelist parser files.|Packaging regression in the 1.6.0 image; fixed in the v1.6.0-1/latest tag. Avoid the bare v1.6.0 tag.|https://github.com/crowdsecurity/crowdsec/issues/2786#issuecomment-1923824051"
  [docker-lapi-key-persistence]="Bouncer API keys reset every time the CrowdSec container restarts|crowdsec-core|Bouncers lose auth (401/403) after every container restart or host reboot, even though nothing was reconfigured.|/var/lib/crowdsec/data (the SQLite DB holding registered bouncer keys) wasn't on a persistent volume, so every restart is effectively a fresh install. Mount that path as a named volume, and gate dependent bouncer containers on a healthcheck rather than just container-start order.|https://github.com/crowdsecurity/crowdsec/issues/3603"
  [oom-multiple-bouncers]="Memory grows until OOMKilled with several bouncers on one LAPI|crowdsec-core|Container memory climbs over days and eventually gets OOMKilled, in setups running a firewall bouncer, Traefik plugin, and AppSec against the same LAPI on a memory-constrained host (under ~1GB).|Not conclusively root-caused upstream as of this writing. If seen, raise the container's memory limit past CrowdSec's documented ~100MB-per-bouncer baseline estimate, or split components across hosts.|https://github.com/crowdsecurity/crowdsec/issues/3641"
  [docker-first-boot-needs-restart]="First-ever container start needs a manual restart to fully initialize|crowdsec-core|On a brand-new container, first boot logs warnings about an empty scenario list or a missing cloudflare_ips.txt, and doesn't fully finish initializing until restarted once.|The entrypoint raced hub/scenario download against LAPI/parser init on first boot; fixed from v1.6.3 onward. If pinned to an older tag, expect to restart once after the very first startup.|https://github.com/crowdsecurity/crowdsec/issues/3114#issuecomment-2326552033"
  [docker-external-db-not-detected]="Entrypoint ignores a configured external database on upgrade|crowdsec-core|Upgrading the Docker image with an external MySQL/Postgres db_config already set errors about a missing local crowdsec.db path, as if SQLite were still expected.|Was an entrypoint detection bug on certain versions; confirm db_config is correctly picked up after any image upgrade, not just on first install.|https://github.com/crowdsecurity/crowdsec/issues/2121#issuecomment-1685307755"
  [docker-client-api-version-too-new]="Docker log-acquisition datasource fails against older Docker Engine hosts|crowdsec-core|A crowdsec container using the Docker datasource fails with a Docker client API version too new error — commonly seen on Synology NAS and similar older Docker Engine hosts.|CrowdSec's vendored Docker client library moved past what the host's Docker Engine daemon supports. Pin an older crowdsec image tag, or upgrade the host's Docker Engine.|https://github.com/crowdsecurity/crowdsec/issues/4122#issuecomment-3833990955"
  [lapi-reverse-proxy-tls-redirect]="A reverse proxy in front of LAPI causes an x509 cert error on startup|crowdsec-core|The crowdsec service fails to start with a certificate expired or not-yet-valid x509 error during the internal watcher-login call, on an otherwise fresh install.|A local reverse proxy on LAPI's port was silently redirecting the internal HTTP watcher-login call to HTTPS with a mismatched cert. Point local_api_credentials.yaml / CROWDSEC_LAPI_URL at LAPI directly, not through the proxy.|https://github.com/crowdsecurity/crowdsec/issues/3810#issuecomment-3211343747"
  [firewall-bouncer-lapi-failure-flushes-blocklist]="A single failed LAPI response can crash the firewall bouncer and wipe its blocklist|firewall-bouncer|One transient LAPI error (e.g. an HTTP 504 during a restart or network blip) crashes the nftables/iptables bouncer entirely, and every previously-applied ban is flushed with it.|No retry/backoff on LAPI errors treated a transient outage as fatal; fixed by adding retry logic to the shared go-cs-bouncer library, mitigated further by the chunked_decisions_stream feature flag. Update to a current bouncer release.|https://github.com/crowdsecurity/cs-firewall-bouncer/issues/369#issuecomment-3510274270"
  [firewall-bouncer-nftables-cidr-not-blocked]="CIDR/subnet bans succeed in cscli but nftables never actually blocks them|firewall-bouncer|Adding a subnet ban with --range reports success, but traffic from IPs inside that range still gets through.|Open upstream issue — nftables sets created by the bouncer aren't declared with the interval flag needed to match CIDR ranges rather than exact IPs. Known limitation as of this writing; verify with a live-block test against a range ban specifically, don't assume it behaves like a single-IP ban.|https://github.com/crowdsecurity/cs-firewall-bouncer/issues/412"
  [firewall-bouncer-high-cpu-low-power]="High CPU on the firewall bouncer during decision churn on low-power hosts|firewall-bouncer|Noticeable CPU spikes specifically when many decisions are added/removed at once, most visible on constrained hardware (small routers/SBCs).|Inefficient one-by-one retry logic when re-adding short-TTL entries instead of bulk set updates; improved in later releases. Update the bouncer if seen on constrained hardware.|https://github.com/crowdsecurity/cs-firewall-bouncer/issues/316#issuecomment-1732412158"
  [traefik-plugin-tls-mtls-confusion]="Enabling the plugin's tls option crashes CrowdSec, not the plugin|traefik-plugin|Turning on the plugin's tls block (e.g. with mkcert-generated certs) causes the CrowdSec container itself to crash or refuse connections.|tls configures mutual-TLS client-cert auth against LAPI — a different, stronger auth mode than the plugin's normal API-key auth. If you're only using an API key, leave tls disabled entirely.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/65#issuecomment-1367851817"
  [traefik-plugin-split-brain-lapi]="Plugin points at a log-parsing-only CrowdSec instance instead of the real LAPI|traefik-plugin|A separate CrowdSec agent parses Traefik logs, but the plugin never blocks anything, even though bans clearly exist somewhere.|In split setups (e.g. LAPI on a firewall/router, a separate agent just for Traefik logs), the plugin must point at whichever instance actually holds LAPI and makes ban decisions — not the log-parsing agent. Only one CrowdSec instance is the real decision source.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/120#issuecomment-1770735007"
  [traefik-plugin-crowdsec-outside-docker]="Plugin can't reach a CrowdSec instance running outside Docker|traefik-plugin|CrowdSec runs on bare metal or a VM (not in the same Docker network as Traefik); the plugin loads but never registers any activity.|CrowdsecLapiHost / CrowdsecAppsecHost need to point at the host's real reachable IP, not a Docker-network service name, when CrowdSec isn't a sibling container.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/193#issuecomment-2413491203"
  [traefik-plugin-lapi-appsec-unreachable]="crowdsecQuery:unreachable / appsecQuery:unreachable in Traefik logs|traefik-plugin|Traefik logs a bare connection-refused/unreachable error for the plugin's LAPI or AppSec query, even at debug logging level, with no further detail.|The plugin can't reach the CrowdSec container's LAPI or AppSec listener port — almost always a Docker network/DNS issue (wrong service name, container not on the same network, AppSec not actually listening). Confirm the port from inside the Traefik container first.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/251"
  [traefik-plugin-403-everyone-no-decisions]="Plugin 403s every request with zero active CrowdSec decisions|traefik-plugin|The plugin enters a permanent fail-closed state, returning 403 to all traffic, while cscli decisions list shows nothing banned.|Usually an API-key mismatch between the plugin's config and what's actually registered in CrowdSec (cscli bouncers list). Also: Traefik needs a full restart to pick up plugin config changes — a reload/redeploy alone isn't enough.|https://discourse.crowdsec.net/t/traefik-once-bouncer-loaded-all-request-get-403/2456"
  [traefik-plugin-trustedips-inverted]="clientTrustedIPs misconfiguration blocks everyone except the trusted range|traefik-plugin|Setting clientTrustedIPs to skip the bouncer for internal IPs instead blocks every IP that isn't in that range.|Usually a CIDR-formatting mistake (stray whitespace, wrong prefix) or forwarded-header trust misconfigured alongside it, causing client-IP misidentification. Double-check the exact CIDR syntax against the plugin's README example.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/41#issuecomment-1328227730"
  [traefik-plugin-sees-docker-bridge-ip]="Plugin sees the Docker bridge gateway IP instead of the real client IP|traefik-plugin|Every request appears to come from the same address (e.g. 172.x.x.1, Docker's default bridge gateway), so per-IP bans never match real attackers.|An extra reverse-proxy hop in front of Traefik (another proxy, a tunnel, a CDN) isn't listed in forwardedHeadersTrustedIPs, so the plugin trusts the immediate hop's IP instead of reading the real client IP out of X-Forwarded-For.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/119#issuecomment-1765555363"
  [traefik-plugin-middleware-not-attached]="Bouncer registers in CrowdSec but never actually runs|traefik-plugin|cscli bouncers list shows the Traefik bouncer registered, but with no last-pull activity — looks configured, does nothing.|The Traefik middleware referencing the plugin was defined but never attached to any router, so the plugin code never executes on any request. Confirm the middleware is actually referenced in a router's middlewares list, not just declared.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/248#issuecomment-3217181247"
  [traefik-plugin-nonroot-workingdir]="Running Traefik as non-root can silently break plugin loading|traefik-plugin|Traefik refuses to load the middleware referencing the plugin, specifically after hardening the container to run as a non-root user.|The plugin loader needs a writable working directory; running as non-root without one breaks it silently. Set working_dir: /tmp (or another writable path) alongside the non-root user: line — worth checking if this tool's own compose-hardening check just flagged you toward running non-root.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/issues/138#issuecomment-3104884464"
  [traefik-plugin-v147-appsec-broke]="v1.4.7 silently broke AppSec integration on upgrade|traefik-plugin|Upgrading the plugin from 1.4.6 to 1.4.7 with AppSec previously working causes AppSec checks to stop functioning, with no error explaining why.|v1.4.7 introduced new required AppSec config keys (crowdsecAppsecScheme, crowdsecAppSecKey) that weren't documented at release time, so existing configs silently stopped working. Upgrade to v1.5.0 or later, which fixed the regression.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/releases/tag/v1.5.0"
  [traefik-plugin-v3-banpage-rendering]="Custom ban page renders as raw text under Traefik v3|traefik-plugin|A configured custom ban.html page displays as raw/escaped HTML source instead of rendering, only under Traefik v3.|The plugin wasn't setting the correct Content-Type header for the custom ban page under Traefik v3; fixed in plugin v1.3.1 and later.|https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/releases/tag/v1.3.1"
  [traefik-legacy-forwardauth-vs-plugin]="Legacy ForwardAuth Traefik bouncer vs the modern plugin bouncer|traefik-plugin|check_bouncer_type.sh (or cscli bouncers list) shows the older fbonalair/freifunkmuc-style ForwardAuth bouncer registered instead of the in-process Traefik plugin.|The ForwardAuth bouncer routes every request through a separate webserver that calls LAPI per-request; the plugin runs in-process inside Traefik instead, using a streaming/local-cache model that removes that extra hop entirely. Migrate by installing the plugin per the official docs, confirm it registers and blocks correctly, then remove the old ForwardAuth middleware and its container.|https://docs.crowdsec.net/u/bouncers/traefik/ (official install docs); https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin#about (why it replaced ForwardAuth, in the plugin authors' own words)"
)

# Explicit display order — bash associative array iteration order is
# undefined, and grouping by component reads better than alphabetical.
KB_ORDER=(
  docker-healthcheck-capi-rate-limit
  v1.7.8-sqlite-lock-cpu
  appsec-body-size-limit
  appsec-tmp-file-accumulation
  decision-stream-dropped
  decision-stream-payload-spike
  lapi-port-change-multi-config
  v1.6.0-docker-whitelist-crash
  docker-lapi-key-persistence
  oom-multiple-bouncers
  docker-first-boot-needs-restart
  docker-external-db-not-detected
  docker-client-api-version-too-new
  lapi-reverse-proxy-tls-redirect
  firewall-bouncer-lapi-failure-flushes-blocklist
  firewall-bouncer-nftables-cidr-not-blocked
  firewall-bouncer-high-cpu-low-power
  traefik-plugin-tls-mtls-confusion
  traefik-plugin-split-brain-lapi
  traefik-plugin-crowdsec-outside-docker
  traefik-plugin-lapi-appsec-unreachable
  traefik-plugin-403-everyone-no-decisions
  traefik-plugin-trustedips-inverted
  traefik-plugin-sees-docker-bridge-ip
  traefik-plugin-middleware-not-attached
  traefik-plugin-nonroot-workingdir
  traefik-plugin-v147-appsec-broke
  traefik-plugin-v3-banpage-rendering
  traefik-legacy-forwardauth-vs-plugin
)

kb_list() {
  echo "Known-issues KB — v${KB_VERSION} (${#KB_ORDER[@]} entries, offline/airgapped-friendly)"
  echo "Curated from crowdsecurity/crowdsec, crowdsecurity/cs-firewall-bouncer, and"
  echo "maxlerebourg/crowdsec-bouncer-traefik-plugin GitHub issues. Not a live feed — see each"
  echo "entry's link for current upstream status."
  local last_component="" id title component
  for id in "${KB_ORDER[@]}"; do
    IFS='|' read -r title component _ <<<"${KB_ISSUES[$id]}"
    if [[ "$component" != "$last_component" ]]; then
      echo
      echo "── ${component} ──"
      last_component="$component"
    fi
    printf "  %-46s %s\n" "$id" "$title"
  done
  echo
  echo "Run 'troubleshoot.sh issues <id>' for details, or 'troubleshoot.sh issues search <term>'"
}

kb_show() {
  local id="$1"
  local entry="${KB_ISSUES[$id]:-}"
  if [[ -z "$entry" ]]; then
    warn "No known-issue entry '${id}' — run 'troubleshoot.sh issues' to list all IDs"
    return 1
  fi
  local title component symptom fix link
  IFS='|' read -r title component symptom fix link <<<"$entry"
  echo "${id} — ${title}"
  echo "Component: ${component}"
  echo
  echo "Symptom: ${symptom}"
  echo "Fix:     ${fix}"
  echo "Link:    ${link}"
}

# kb_hint <id> — called from inside a check script's own OK/WARN/CRIT block
# to attach a real, verified resolution link right where the finding is
# printed, instead of pointing at another script filename in this tool (which
# isn't a resolution — it just relocates the question). Silent no-op on an
# unknown id rather than erroring, since a typo here shouldn't take down the
# check that called it.
kb_hint() {
  local id="$1"
  local entry="${KB_ISSUES[$id]:-}"
  [[ -z "$entry" ]] && return 0
  local title link
  IFS='|' read -r title _ _ _ link <<<"$entry"
  info "KB: ${title}"
  info "    ${link}"
}

kb_search() {
  local term="${1:-}"
  if [[ -z "$term" ]]; then
    warn "Usage: troubleshoot.sh issues search <term>"
    return 1
  fi
  local id title component found=0
  for id in "${KB_ORDER[@]}"; do
    if grep -qi -- "$term" <<<"${KB_ISSUES[$id]}"; then
      IFS='|' read -r title component _ <<<"${KB_ISSUES[$id]}"
      printf "  %-46s [%s] %s\n" "$id" "$component" "$title"
      found=1
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    info "No known-issue entries matched '${term}'"
  fi
}
