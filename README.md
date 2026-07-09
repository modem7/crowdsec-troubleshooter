# crowdsec-troubleshooter

[![CI](https://github.com/modem7/crowdsec-troubleshooter/actions/workflows/ci.yml/badge.svg)](https://github.com/modem7/crowdsec-troubleshooter/actions/workflows/ci.yml)

A small, unprivileged, run-once Docker tool for diagnosing CrowdSec + Traefik
setups — a wellness check, an IP block checker, and (optionally) a live
"does blocking actually work" test. No daemon, no `docker.sock`, no host
networking, no capabilities required for anything beyond an outbound HTTP
call. Everything beyond the basic wellness check is opt-in, and every
credential the tool can use comes with its own add/remove instructions
printed directly in the tool's own output.

## Why this exists

CrowdSec decisions live in its Local API (LAPI) alone — Traefik's bouncer
and the Cloudflare Worker bouncer are both just enforcement points that poll
LAPI and apply what it says. So "why isn't this being blocked" is
fundamentally a LAPI question, not a three-way Traefik/CrowdSec/Cloudflare
diagnostic. This tool is built around that.

## Quick start

```bash
docker run --rm -e CROWDSEC_LAPI_URL=http://crowdsec:8080 modem7/crowdsec-troubleshooter
```

That alone runs the tier-0 checks — LAPI liveness, log-parsing activity,
bouncer-type fingerprinting, and a heuristic on the LAPI URL itself — with
**zero credentials of any kind**. Everything else in this tool is additive
from there; run it once with nothing configured and it'll tell you exactly
what each extra check needs, why, and how to add (or remove) it.

```bash
# Check a specific IP's ban status and reason
docker run --rm -e CROWDSEC_LAPI_URL=... -e CROWDSEC_LAPI_KEY=... \
  modem7/crowdsec-troubleshooter check-ip 198.51.100.23

# Prove blocking actually works end-to-end (adds/removes a real test ban)
docker run --rm -e CROWDSEC_LAPI_URL=... -e CROWDSEC_MACHINE_CREDENTIALS_FILE=... \
  modem7/crowdsec-troubleshooter live-test --target-url https://your-service.example.com
```

## The tier model

| Tier | Unlocks with | What it adds |
|---|---|---|
| 0 | Nothing beyond `CROWDSEC_LAPI_URL` | LAPI liveness, log-parsing activity, bouncer-type fingerprint, LAPI-URL scope heuristic, optional auth-bypass comparison |
| 1 | A dedicated **read-only bouncer key** | `check-ip` — the block checker |
| 2 | A **machine credential** (read-write) | Live block/unban test, AppSec probe |
| 3 | **Read-only host file mounts** | `DOCKER-USER` chain evidence, duplicate-acquisition detection, syslog hinting, compose-file hardening audit |

Nothing needs `docker.sock`, `--privileged`, `NET_ADMIN`/`NET_RAW`, or host
networking, at any tier. See [`DESIGN.md`](./DESIGN.md) for the reasoning
behind every one of these boundaries — most of them exist because an earlier
draft of this tool assumed more access than it turned out to actually need.

## Why no daemon mode

Considered and deliberately rejected. The only real argument for one is
continuous monitoring, and that's just "run tier 0 on a schedule" — a cron
entry or a scheduler calling `docker run --rm`, piped into Healthchecks.io
or polled by Uptime Kuma, gets the same outcome with none of the downside.
A daemon means a machine credential (create/delete real bans) sitting live
in a running process indefinitely — the one architecture choice that would
undo the whole credential-hygiene design of this tool for no functional gain.

## Testing / CI

Every push and PR runs: `bash -n` syntax checks, ShellCheck, a set of
convention checks specific to this repo (every script executable and
starting with `set -uo pipefail`; every `setup/add_*`/`register_*` has a
matching `remove_*`/`unregister_*`), Hadolint against the Dockerfile,
YAML/schema validation of the example compose files, a Gitleaks secret
scan, a `bats` regression/behavior test suite, and finally a Docker build
plus smoke test against a mock LAPI.

Two real bugs were caught during development by actually running the code
against mock servers rather than just reading it — see `tests/lib_common.bats`
and `tests/check_metrics_liveness.bats` for the regression tests that now
cover both, and `DESIGN.md` for what they were. A third, more structural bug
(fragile `$0`-based path resolution that only worked by coincidence when
scripts were executed rather than sourced) was caught by the test suite
itself failing when tests legitimately `source`d a script directly — fixed
project-wide by switching to `${BASH_SOURCE[0]}`.

Run locally the same way CI does:

```bash
shellcheck --severity=warning $(find . -name "*.sh")
bats tests/*.bats
docker build -t crowdsec-troubleshooter:local .
```

## Status

Early scaffold. Tier 0 and the block checker (tier 1) are implemented and
should work as-is against a real CrowdSec instance — not yet tested against
one, so treat as a starting point to validate rather than trust blindly.
Tier 2 (live block test) is implemented with the same caveat, plus a hard
safety requirement: the cleanup trap that removes the test ban must be
verified to actually fire under real failure conditions before this is
trusted against a production instance.

Known open questions, not yet resolved:
- Whether `cscli capi status`-equivalent data (`check_capi.sh`) is reachable
  via LAPI's HTTP API at all, or is database-only like bouncer listing
  turned out to be. Flagged as a placeholder in the script itself.
- The exact AppSec probe path format (`test_appsec_probe.sh`) — CrowdSec's
  docs show an example token but don't confirm whether it's fixed or
  generated per-install.
- Version/CVE checking (`versioncheck/cve.sh`) has no reliable network-only
  mechanism yet — currently accepts a manual hint rather than detecting
  anything itself.

## License

MIT
