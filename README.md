# crowdsec-troubleshooter

[![CI](https://github.com/modem7/crowdsec-troubleshooter/actions/workflows/ci.yml/badge.svg)](https://github.com/modem7/crowdsec-troubleshooter/actions/workflows/ci.yml)
[![status-badge](https://woodpecker.modem7.com/api/badges/3/status.svg)](https://woodpecker.modem7.com/repos/3)
[![Last Commit](https://img.shields.io/github/last-commit/modem7/crowdsec-troubleshooter)](https://github.com/modem7/crowdsec-troubleshooter/commits/master)
[![Docker Pulls](https://img.shields.io/docker/pulls/modem7/crowdsec-troubleshooter)](https://hub.docker.com/r/modem7/crowdsec-troubleshooter)
[![Docker Image Size](https://img.shields.io/docker/image-size/modem7/crowdsec-troubleshooter)](https://hub.docker.com/r/modem7/crowdsec-troubleshooter)

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
# CROWDSEC_MACHINE_CREDENTIALS_FILE is read from inside the container, so the
# host file must be bind-mounted in — see setup/register_machine.sh for how
# to provision the credential itself (it's a login+password, not a token).
docker run --rm -e CROWDSEC_LAPI_URL=... \
  -e CROWDSEC_MACHINE_CREDENTIALS_FILE=/creds/machine.json \
  -v /path/on/host/machine.json:/creds/machine.json:ro \
  modem7/crowdsec-troubleshooter live-test --target-url https://your-service.example.com
```

### Known-issues reference: `issues`

A curated, offline knowledge base of common CrowdSec / CrowdSec+Traefik
problems — the ones this tool has no reliable, credential-free way to
actually detect (upstream version regressions, nftables internals, "which
exact release broke this"), so they're reference material rather than a
check. Works with **zero credentials and zero network access** — it's
data shipped inside the image (`lib/known_issues.sh`), not a live lookup,
so it works in restricted-network/offline-image environments too. Links in
the output are plain text, meant to be read or copy-pasted to a machine
that does have internet access — the tool itself never dereferences them:

```bash
docker run --rm modem7/crowdsec-troubleshooter issues                    # list all entries
docker run --rm modem7/crowdsec-troubleshooter issues search bridge      # search title/symptom/fix text
docker run --rm modem7/crowdsec-troubleshooter issues traefik-plugin-tls-mtls-confusion  # full detail + link
```

Where a check's own finding matches a KB entry, the check prints that entry's
title and link inline as part of its own output (a `kb_hint` call — see
`check_bouncer_type.sh` for the example) instead of pointing at another
script's filename as if that were a fix. Not every check is wired up yet;
`troubleshoot.sh issues` remains the way to browse the full set by hand.

This isn't "airgapped" in the strictest sense — it's aimed at a restricted
network that can reach your LAPI and other Docker services but may not be
able to reach Docker Hub/GitHub. Nothing in this tool needs the latter to
function: the KB is baked into the image at build time, not fetched at
runtime. (The one thing in this repo that *does* make an optional runtime
call to GitHub is `check_image_freshness.sh`, an unrelated staleness check
that already degrades to "can't verify" rather than failing if it can't
reach it.)

Curated by hand from `crowdsecurity/crowdsec`, `crowdsecurity/cs-firewall-bouncer`,
and `maxlerebourg/crowdsec-bouncer-traefik-plugin` GitHub issues — not a
live feed, and not exhaustive. Each entry links to the best available
resolution (official docs where one exists, otherwise the GitHub
comment/PR/release that actually fixed it), and every link is verified to
resolve before being added. Pulling a newer image is the only thing needed
to refresh it.

### Or skip the `-e` flags entirely: `wizard.sh`

Typing out `CROWDSEC_LAPI_URL`/`CROWDSEC_LAPI_KEY`/`CROWDSEC_MACHINE_CREDENTIALS_FILE`
by hand every run gets old fast, especially with the `-v` mount the last
one needs. `wizard.sh` (Linux only — runs on the host, not inside the
container) prompts for whatever a given action actually needs, remembers
what you enter in `./.crowdsec-troubleshooter.env` for next time, and
launches the real `docker run` for you.

No clone needed — run it straight from the repo:

```bash
curl -fsSL https://raw.githubusercontent.com/modem7/crowdsec-troubleshooter/master/wizard.sh | bash -s -- wellness
```

`-s --` matters: without it, `bash` tries to open a file literally named
`wellness` instead of passing it as an argument to the piped script. Every
prompt reads from `/dev/tty` explicitly rather than the script's own
stdin (which the pipe above is using to deliver the script itself) — this
is what makes prompting actually work over a pipe instead of every answer
silently coming back empty.

Or clone the repo and run it locally, same commands either way:

```bash
./wizard.sh                                        # interactive menu
./wizard.sh --compose ./docker-compose.yml wellness # auto-suggest from your compose file
./wizard.sh check-ip 198.51.100.23
./wizard.sh live-test https://your-service.example.com
```

Every value it resolves follows the same priority: a shell env var you've
already exported wins, then a previously-saved value, then a
`docker-compose.yml`-derived suggestion (best-effort — it looks for
`crowdsecurity/crowdsec`, `*traefik-crowdsec-bouncer`, and
`crowdsecurity/cloudflare-worker-bouncer` images and reads their `ports:`/
`networks:`/`environment:` blocks), then blank. Nothing is silently
overwritten — every prompt shows its default and Enter keeps it. The saved
file is `chmod 600`'d; treat it like any other credentials file and
`.gitignore` it if this directory is a git repo.

## The tier model

| Tier | Unlocks with | What it adds |
|---|---|---|
| 0 | Nothing beyond `CROWDSEC_LAPI_URL` | LAPI liveness, log-parsing activity, bouncer-type fingerprint (legacy or modern plugin), LAPI-URL scope heuristic, optional auth-bypass comparison |
| 1 | A dedicated **read-only bouncer key** | `check-ip` — the block checker |
| 2 | A **machine credential** (read-write) | Live block/unban test, AppSec probe |
| 3 | **Read-only host file mounts** | `DOCKER-USER` chain evidence, duplicate-acquisition detection, syslog hinting, compose-file hardening audit |

Nothing needs `docker.sock`, `--privileged`, `NET_ADMIN`/`NET_RAW`, or host
networking, at any tier. See [`DESIGN.md`](./DESIGN.md) for the reasoning
behind every one of these boundaries — most of them exist because an earlier
draft of this tool assumed more access than it turned out to actually need.

For the full list of every `-e` var, `-v` mount, and CLI flag this tool
reads — what each one unlocks, what's required alongside it, and the exact
`docker run` invocation for each tier — see
[`FLAGS.md`](./FLAGS.md).

## Why no daemon mode

Considered and deliberately rejected. The only real argument for one is
continuous monitoring, and that's just "run tier 0 on a schedule" — a cron
entry or a scheduler calling `docker run --rm`, piped into Healthchecks.io
or polled by Uptime Kuma, gets the same outcome with none of the downside.
A daemon means a machine credential (create/delete real bans) sitting live
in a running process indefinitely — the one architecture choice that would
undo the whole credential-hygiene design of this tool for no functional gain.

## Images

Published to both registries on every successful build — pick whichever fits your setup:

```bash
docker pull modem7/crowdsec-troubleshooter:latest        # Docker Hub — via Woodpecker
docker pull ghcr.io/modem7/crowdsec-troubleshooter:latest # GHCR — via GitHub Actions
```

Docker Hub builds on every push to `master` that touches the image's actual
source (`Dockerfile`, `lib/`, `checks/`, `setup/`, `versioncheck/`,
`capability_check.sh`, `troubleshoot.sh`) — see `.woodpecker.yml`. GHCR
publishes only after the `CI` GitHub Actions workflow has actually succeeded
for that commit — see `.github/workflows/publish-ghcr.yml` — so an image
can't land on GHCR without every lint/test/build check passing first. Both
are multi-arch (`linux/amd64` + `linux/arm64`).

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
