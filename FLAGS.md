# Flags and environment variable reference

Every `-e` var, `-v` mount, and CLI flag this tool actually reads, organized
by the tier model from [README.md](./README.md#the-tier-model). Nothing
here is required beyond `CROWDSEC_LAPI_URL` — everything else unlocks a
specific, named check, and every check degrades gracefully (prints what
it's missing and why, then exits 0) if its inputs aren't set.

If you'd rather not track any of this by hand, [`wizard.sh`](./wizard.sh)
prompts for whatever a given action actually needs and remembers your
answers — see the Quick start section of the README. This file is the
reference for the manual `docker run` route, and for wizard.sh's own flags.

## Quick reference

| Variable / flag | Tier | Unlocks | Required alongside it |
|---|---|---|---|
| `CROWDSEC_LAPI_URL` | 0 | Everything — the one thing this tool actually requires | — |
| `CROWDSEC_METRICS_URL` | 0 | Accurate log-parsing-activity check when metrics isn't on the same port as LAPI | — |
| `METRICS_POLL_GAP` | 0 | Tuning only — seconds between the two metrics samples (default `10`) | — |
| `TRAEFIK_BOUNCER_URL` | 0 (optional) | Bouncer-type fingerprinting | — |
| `TRAEFIK_PROTECTED_URL` + `TRAEFIK_DIRECT_URL` | 0 (optional) | Auth-bypass comparison check | Both must be set together |
| `TRAEFIK_API_URL` | optional | Positive confirmation of the modern Traefik plugin bouncer | Traefik must have `--api.dashboard=true` |
| `CROWDSEC_LAPI_KEY` | 1 | `check-ip` — the block checker | A dedicated **read-only** bouncer key |
| `CROWDSEC_MACHINE_CREDENTIALS_FILE` | 2 | `live-test` — proves blocking works end-to-end | A `-v` mount (see below) + a machine credential |
| `CROWDSEC_VERSION_HINT` | optional | CVE checking against a hardcoded, unmaintained list — see caveat below | — |
| Tier-3 `-v` mounts | 3 | `DOCKER-USER` chain evidence, duplicate-acquisition detection, syslog hinting, compose-file hardening | Read-only host file mounts, see below |

## Tier 0 — nothing but `CROWDSEC_LAPI_URL`

```bash
docker run --rm -e CROWDSEC_LAPI_URL=http://crowdsec:8080 modem7/crowdsec-troubleshooter
```

- **`CROWDSEC_LAPI_URL`** *(required)* — LAPI's address. Use the
  docker-compose service name (`http://crowdsec:8080`) if this container
  joins the same docker network (`docker run --network <name> ...`);
  otherwise a LAN IP/hostname + published port both work, but
  `check_lapi_url_scope.sh` will flag that pattern as a heads-up, not an
  error — it can't tell whether that port is also reachable from outside
  your LAN, only that it's not the internal-networking shape.
- **`CROWDSEC_METRICS_URL`** *(optional)* — where CrowdSec's Prometheus
  endpoint lives. If unset, the tool guesses by swapping `:8080` for
  `:6060` in `CROWDSEC_LAPI_URL` — that guess only works if your LAPI port
  literally contains `:8080` (e.g. it breaks for a published port like
  `:19818`). Set this explicitly whenever LAPI and metrics are on different
  published ports. Also needs `prometheus.listen_addr: 0.0.0.0` in
  crowdsec's own `config.yaml` — the default `127.0.0.1` is loopback-only
  and invisible to a sibling container even on the same docker network.
- **`METRICS_POLL_GAP`** *(optional, default `10`)* — seconds between the
  two samples the metrics-liveness check compares to detect activity.
- **`TRAEFIK_BOUNCER_URL`** *(optional)* — your Traefik bouncer's own
  service address, e.g. `http://traefik-bouncer:8080`. Fingerprints the
  legacy ForwardAuth-style bouncer directly; a non-match doesn't prove the
  modern plugin bouncer is running instead (see `TRAEFIK_API_URL` below).
- **`TRAEFIK_PROTECTED_URL`** + **`TRAEFIK_DIRECT_URL`** *(optional pair)* —
  the normal auth-gated URL for a service, and its raw internal address.
  Set both to check whether the backend enforces its own auth or relies
  entirely on the router/middleware layer (bypassable by anything that can
  reach the backend directly).

## Tier 1 — a dedicated read-only bouncer key

```bash
docker run --rm -e CROWDSEC_LAPI_URL=... -e CROWDSEC_LAPI_KEY=... \
  modem7/crowdsec-troubleshooter check-ip 198.51.100.23
```

- **`CROWDSEC_LAPI_KEY`** — a bouncer API key, read-only by construction
  (bouncer keys can only read decisions, never create/delete them). Get one
  with `docker run --rm modem7/crowdsec-troubleshooter setup
  add_readonly_bouncer` — it prints the one `cscli bouncers add` command to
  run on your CrowdSec server (this can't be done over the network; bouncer
  registration is a database operation, not an LAPI HTTP endpoint) and the
  matching `setup remove_readonly_bouncer` output for undoing it later.
- **CLI argument**: `check-ip <ip-address>` — the IP to look up.

## Tier 2 — a machine credential (read-write)

```bash
docker run --rm -e CROWDSEC_LAPI_URL=... \
  -e CROWDSEC_MACHINE_CREDENTIALS_FILE=/creds/machine.json \
  -v /path/on/host/machine.json:/creds/machine.json:ro \
  modem7/crowdsec-troubleshooter live-test --target-url https://your-service.example.com
```

- **`CROWDSEC_MACHINE_CREDENTIALS_FILE`** — the **in-container** path to a
  small JSON file: `{"login": "...", "password": "..."}`. This is read from
  inside the container, so it must be bind-mounted in with `-v` — setting
  the env var alone does nothing, the path has to actually resolve inside
  the container's filesystem.
- The **login/password**, not a ready-made token: run
  `docker run --rm modem7/crowdsec-troubleshooter setup register_machine`
  for the full walkthrough. In short: `docker exec crowdsec cscli machines
  add troubleshooter --auto` on your CrowdSec server prints a Login and
  Password — save those two as the JSON above. The tool logs in fresh
  (`POST /v1/watchers/login`) on every run to mint a short-lived token, so
  the credential file never goes stale between runs.
- Treat this credential like an admin password, not like the block-checker
  key: it **can** create/delete real CrowdSec decisions. It **cannot**
  touch Docker, your host system, or anything outside CrowdSec's own ban
  list. `setup unregister_machine` prints the matching teardown.
- **CLI argument**: `live-test --target-url <url>` — the service to prove
  blocking against. Adds a short-lived (60s) real ban on this container's
  own outbound IP, confirms the target returns 403, removes the ban, and
  confirms access is restored — the actual proof that blocking works
  end-to-end, not just that it's configured.

## Tier 3 — read-only host file mounts

No env vars — each of these is a `-v` mount at a fixed path. Nothing here
needs `docker.sock`; these are all plain read-only bind mounts of files you
already have on the host.

```bash
docker run --rm -e CROWDSEC_LAPI_URL=... \
  -v /path/to/firewall-bouncer.yaml:/mnt/bouncer/firewall-bouncer.yaml:ro \
  -v /path/to/firewall-bouncer.log:/mnt/bouncer/firewall-bouncer.log:ro \
  -v /path/to/docker-compose.yml:/mnt/compose/docker-compose.yml:ro \
  -v /path/to/crowdsec/config/acquis.yaml:/mnt/crowdsec/acquis.yaml:ro \
  -v /path/to/crowdsec/config/log:/mnt/crowdsec:ro \
  modem7/crowdsec-troubleshooter --tier 3
```

| Mount (container path) | Unlocks |
|---|---|
| `/mnt/bouncer/firewall-bouncer.yaml` | `DOCKER-USER` iptables chain evidence, read from the firewall bouncer's own config |
| `/mnt/bouncer/firewall-bouncer.log` | Same check, corroborated from the bouncer's own log |
| `/mnt/compose/docker-compose.yml` | Compose-file hardening audit (e.g. `docker.sock` mount patterns) |
| `/mnt/crowdsec/acquis.yaml`, `/mnt/crowdsec/acquis.d/` | Duplicate-acquisition-entry detection (a documented install-wizard re-run bug) |
| `/mnt/crowdsec` (containing `crowdsec.log`) | Syslog hinting — notices when crowdsec's own log is suspiciously empty and points at syslog/journalctl instead |

Mount only the ones you want; each check independently reports what it's
missing (with the exact `-v` line to add) if its specific mount isn't
present. `--tier 3` runs every tier up to and including 3 — omit it and the
tool auto-detects the highest tier your current flags/mounts satisfy.

## Optional / advanced overrides

Rarely needed — mostly for forks, CI, or working around something specific.

| Variable | Default | Purpose |
|---|---|---|
| `CROWDSEC_VERSION_HINT` | unset | Feeds `versioncheck/cve.sh`'s CVE check. **Caveat**: this is a hardcoded, unmaintained CVE list — a clean result here is not a real guarantee. Check CrowdSec's own security advisories directly for anything current. |
| `IMAGE_FRESHNESS_REPO` | `modem7/crowdsec-troubleshooter` | Which GitHub repo the image-freshness check compares its build commit against — only relevant for a fork. |
| `GITHUB_API_BASE` | `https://api.github.com` | Test-only override for the image-freshness check's API endpoint. |
| `IP_ECHO_URL` | `https://api.ipify.org` | Test-only override for `live-test`'s self-IP lookup. |

## `wizard.sh` flags

Host-side only (Linux, runs on the Docker host, not inside the container —
see the README's Quick start for why). Full usage: `./wizard.sh --help`.

| Flag / env var | Purpose |
|---|---|
| `--file <path>` | Credentials file to load/save (default `./.crowdsec-troubleshooter.env`) |
| `--compose <path>` | A `docker-compose.yml` to auto-suggest values from (best-effort — see the README). If omitted, the wizard first tries to find it itself: it looks for a running container whose image is `crowdsecurity/crowdsec` and reads the `com.docker.compose.project.working_dir`/`.config_files` labels Compose stamps on it — no container name assumed. Falls back to checking `./docker-compose.yml`/`.yaml` in the current directory, then to just asking, exactly as if this detection didn't exist. |
| `wellness` / `check-ip <ip>` / `live-test <target-url>` | Which action to run — omit to get an interactive menu |
| `WIZARD_IMAGE` | Override the image to run (default `modem7/crowdsec-troubleshooter`) — useful for testing a locally-built image |
| `WIZARD_SKIP_PULL=1` | Skip the `docker pull` the wizard normally does before every run — needed when `WIZARD_IMAGE` points at a local-only tag that was never pushed to a registry |

The wizard always pulls the image fresh before running (unless
`WIZARD_SKIP_PULL=1`), so you're never silently testing against a stale
local copy. For the manual `docker run` route, `check_image_freshness.sh`
(tier 0, runs automatically, no flag needed) compares the commit your image
was actually built from against the latest on `master` and warns if you're
behind — see its own header comment for the one real caveat (a brief window
right after a push where the image hasn't finished publishing yet).

## Known placeholders — not fully implemented

Flagged clearly rather than silently dropped or presented with false
confidence. See `DESIGN.md` before touching these:

- **`check_capi.sh`** (tier 2) — whether CAPI/community-blocklist status is
  reachable via LAPI's HTTP API at all is unverified. Currently a no-op
  placeholder that says so.
- **`test_appsec_probe.sh`** (tier 2) — the exact AppSec probe path format
  is unverified against a live instance.
- **`versioncheck/cve.sh`** — has no real CrowdSec-version-detection
  mechanism; takes a manual `CROWDSEC_VERSION_HINT` instead.
