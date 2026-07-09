# Design notes

Condensed record of the architectural decisions behind this tool, including
a few corrections made along the way — kept here so the reasoning isn't lost
and doesn't need re-litigating later.

## Scope: CrowdSec-centric, not a three-way chain-walker

Early drafts of this tool tried to diagnose Traefik, CrowdSec, and
Cloudflare as three independent layers that might each decide to block a
request. That's wrong: only LAPI decides anything. Bouncers (Traefik plugin,
Cloudflare Worker, the firewall bouncer) authenticate with a simple API key
and can only *read* decisions — they have no independent judgment. So the
tool is built around LAPI as the single source of truth, with
Traefik/Cloudflare treated as "is this bouncer in sync" checks rather than
peer diagnostic layers.

## No `docker.sock`, ever

Querying host-level facts (is the `DOCKER-USER` iptables chain attached, is
a port published) initially seemed to require either `docker.sock` or host
networking + `NET_ADMIN`/`NET_RAW`. Neither is used. Instead:

- **`DOCKER-USER` chain evidence** comes from reading the firewall bouncer's
  own config and log file (read-only mounts) — the bouncer already needs
  `network_mode: host` + `NET_ADMIN`/`NET_RAW` to do its actual job, so this
  tool piggybacks on what it already reports rather than duplicating that
  privilege.
- **Port-exposure findings** come from reading a mounted `docker-compose.yml`
  as plain text, or from a heuristic on `CROWDSEC_LAPI_URL` itself. Neither
  can *confirm* something is reachable from the internet (that's a
  router/firewall fact no container can see) — they flag the underlying
  misconfiguration pattern instead, and say so explicitly rather than
  overclaiming.

## No `CAP_ADD`, anywhere

An early tier draft assumed a "network checks" tier would need `CAP_ADD`.
It doesn't — every check in this tool is a plain outbound HTTP call, which
needs zero Linux capabilities. `CAP_ADD` only matters for raw sockets or
touching the host's network stack directly, which this tool deliberately
avoids (see above). The two axes that actually matter are credential
strength (API key type) and file-mount access — not capabilities.

## Corrections made mid-design (kept here so they don't get re-made)

- **`/health` exists.** An early draft proposed probing `/v1/watchers/login`
  with a bogus payload to infer LAPI liveness without a credential. LAPI has
  a real, purpose-built, unauthenticated `/health` endpoint — use that
  instead, it's the documented mechanism.
- **Bouncer listing is database-only.** `cscli bouncers list` — including
  the self-reported Type/Version fields — was assumed to be reachable via
  LAPI's HTTP API with a machine credential. CrowdSec's own docs say
  otherwise: bouncer commands "interact directly with the database,"
  same as add/delete. This is NOT reachable over the network at any
  credential tier. Bouncer-type detection instead fingerprints the
  bouncer's own service endpoint directly (`GET /api/v1/ping` on the legacy
  ForwardAuth-style bouncer) — a completely different, and it turns out
  simpler, zero-credential mechanism.
- **The Traefik plugin bouncer has no separate service to probe.** It runs
  in-process inside Traefik. Positively confirming it (rather than just
  failing to find the legacy bouncer) means querying Traefik's own API —
  a genuinely separate integration surface from CrowdSec's LAPI, kept in
  `checks/optional_traefik_api/` rather than silently bundled into the
  CrowdSec-specific checks.
- **`docker.sock:...:ro` is not the mitigation it looks like.** The `:ro`
  flag only stops a container rewriting the socket file itself — it does
  nothing to restrict which Docker API calls get made over that socket,
  since it's a Unix socket, not a regular file. Relevant to
  `check_compose_hardening.sh`'s docker.sock rule, and worth remembering
  generally.
- **CAPI status and the exact AppSec probe path are unverified.** Left in as
  clearly-flagged placeholders (`check_capi.sh`, `test_appsec_probe.sh`)
  rather than either silently dropped or presented with false confidence.

## Why no daemon mode

See README. Short version: the only real argument for one (continuous
monitoring) is already served by a scheduled one-shot run, and a daemon
means a machine credential sitting live indefinitely, which undoes the
credential-hygiene design of everything else in this tool.
