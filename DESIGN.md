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
  a genuinely separate integration surface from CrowdSec's LAPI. Originally
  kept in its own `checks/optional_traefik_api/` folder rather than
  bundled into the CrowdSec-specific checks, on the theory that a
  different integration surface deserved a different, opt-in home. That
  separation had a real cost nobody noticed until it was pointed out
  directly: `optional_traefik_api/` was never actually globbed by
  `troubleshoot.sh`'s tier0 sweep, so the plugin-bouncer check silently
  never ran for anyone, ever — `wizard.sh` happily collected
  `TRAEFIK_API_URL` and exported it into the container, but nothing
  downstream consumed it. Merged into `check_bouncer_type.sh` (tier0) so
  both bouncer types get the same automatic, always-attempted coverage —
  the plugin bouncer is CrowdSec's current recommended approach and
  deserves first-class detection, not a check nobody could actually reach.
- **`docker.sock:...:ro` is not the mitigation it looks like.** The `:ro`
  flag only stops a container rewriting the socket file itself — it does
  nothing to restrict which Docker API calls get made over that socket,
  since it's a Unix socket, not a regular file. Relevant to
  `check_compose_hardening.sh`'s docker.sock rule, and worth remembering
  generally.
- **CAPI status and the exact AppSec probe path are unverified.** Left in as
  clearly-flagged placeholders (`check_capi.sh`, `test_appsec_probe.sh`)
  rather than either silently dropped or presented with false confidence.
- **Machine credentials file held a `.token` field that nothing ever
  produced.** `test_live_block.sh` originally read a ready-made bearer
  token straight out of the credentials file, but `cscli machines add
  --auto` only ever prints a login/password pair — there's no token to
  save at setup time. Fixed by storing login+password instead and having
  the script POST to `/v1/watchers/login` itself on every run to mint a
  fresh short-lived JWT, which also sidesteps the token-expiry problem a
  save-once approach would have hit a few hours after setup. Caught by a
  user pointing out the README's `live-test` example didn't even mount the
  credentials file into the container in the first place — the token/login
  mismatch was found while checking that report, not by reading the code
  cold.
- **`cscli machines add --auto` collides with crowdsec's own credentials
  file.** Fixing the `.token` issue above got the *shape* of the command
  right (login+password, not a token) but not the full picture: `cscli
  machines add <name> --auto` writes to `/etc/crowdsec/
  local_api_credentials.yaml` by default, and that file already exists on
  a running instance (crowdsec's own engine already uses it) — so the
  documented command failed with a real "credentials file already exists"
  error the moment a user actually tried it. The fix (`-f -`, print
  credentials to stdout instead of writing any file) was quoted directly
  from cscli's own error message, not guessed — the error text itself
  names `-f -` as the documented escape hatch. Caught by the user actually
  running the command against their live CrowdSec instance, not by
  reasoning about what `cscli` might do.

## Why no daemon mode

See README. Short version: the only real argument for one (continuous
monitoring) is already served by a scheduled one-shot run, and a daemon
means a machine credential sitting live indefinitely, which undoes the
credential-hygiene design of everything else in this tool.

## Why wizard.sh runs on the host, not inside the container

Every credential-collection UX up to this point assumed the user would
type `-e CROWDSEC_LAPI_URL=...` by hand each run, or read it from their own
shell history/scripts. That gets old fast, especially for
`CROWDSEC_MACHINE_CREDENTIALS_FILE`, which also needs a `-v` mount most
people forget (see the earlier corrections-list entry on that). The fix
looks obvious in hindsight: prompt once, save the answers, reuse them next
time. But it can't be *inside* `troubleshoot.sh` or the image at all — a
`docker run --rm` container has no persistent filesystem across
invocations, and no TTY unless `-it` is explicitly passed, which nothing
in the documented usage does. Both requirements (persist a file across
runs, prompt interactively) can only be satisfied by something that runs
*before* `docker run` is invoked, on the host itself. `wizard.sh` is
therefore a separate, host-executed, Linux-only script, not something
`COPY`'d into the Dockerfile — it builds the `docker run` invocation and
`exec`s it, rather than being run by it. Its docker-compose parsing is
scoped the same way as `check_lapi_url_scope.sh`'s heuristics: best-effort
regex/awk over YAML, never claimed as authoritative, always overridable at
the prompt it feeds into.

## Known-issues KB as data, not more check scripts

Researching common CrowdSec/Traefik problems (top GitHub issues across
`crowdsecurity/crowdsec`, `crowdsecurity/cs-firewall-bouncer`, and
`maxlerebourg/crowdsec-bouncer-traefik-plugin`) turned up far more
Docker-relevant, not-yet-covered gotchas than would fit as actual checks —
most of them (upstream version regressions, nftables internals, "which
release broke this") are things this tool has no reliable, credential-free
way to detect. They're reference material for a human reading the output,
not something a check script can assert pass/fail on. Rather than growing
every check script with more string literals to cover cases it can't
actually test for, they live in `lib/known_issues.sh` as plain data — an
associative array of id → title/component/symptom/fix/link, browsable via
`troubleshoot.sh issues`. The links are plain text for the user to read or
copy elsewhere — this tool never dereferences them itself, so it works
the same whether or not the host it's running on can actually reach them.

A check pointing at *another script in this tool* instead of an actual
resolution isn't a resolution — it just relocates the same question.
`check_bouncer_type.sh` told the user CrowdSec's docs "now recommend the
Traefik plugin bouncer instead," with no link, which (a) gave no way to
actually act on it, and (b) attributed the recommendation to CrowdSec's
own docs without that having been verified — searching `docs.crowdsec.net`
directly turned up no such explicit claim; the real, citable source turned
out to be the plugin's own README "About" section explaining why it
replaced the ForwardAuth architecture. Fixed by adding a `kb_hint <id>`
helper that a check can call to print a real, link-checked resolution
straight from `lib/known_issues.sh` inline in its own OK/WARN/CRIT output —
see `traefik-legacy-forwardauth-vs-plugin` in that file and its use in
`check_bouncer_type.sh`. Every link in the KB is verified to actually
resolve before being added, not just assumed to still be live from when it
was found.

Two decisions worth recording:
- **Pure bash, not JSON+jq.** `jq` is a hard dependency elsewhere in this
  tool (`require_jq`), but the KB itself has no reason to need it — a
  bash associative array needs no parser at all.
- **Sourced lazily, and gated before `capability_check.sh`, not after.**
  `troubleshoot.sh` originally sourced `capability_check.sh` first,
  always — which hard-fails without `CROWDSEC_LAPI_URL` by design ("nothing
  in this tool is meaningful without it"). That stopped being true the
  moment `issues` existed: a KB lookup is meaningful with zero
  credentials and zero network access, which is the entire point of
  shipping it inside the image for use on a restricted network. Caught
  before it shipped by actually running `troubleshoot.sh issues` with a
  clean env rather than just reading the dispatch logic — it failed
  demanding a LAPI URL it never needed. Fixed by special-casing `issues`
  before `capability_check.sh` is even sourced, not by relaxing that
  script's hard-fail (which is still correct for every other action).
- **`declare -gA`, not `declare -A`, for the data array.** Sourcing a file
  that does `declare -A FOO=(...)` from inside a shell function (a bats
  `setup()`, or any future non-top-level caller) makes `FOO` local to that
  function under bash's scoping rules — it silently vanishes the moment
  the function returns, and lookups afterward fail in a confusing way
  (`set -u` turns a hyphenated missing-array-key lookup into an "unbound
  variable" error naming an unrelated word from the key, not the actual
  missing-array problem). Caught by `known_issues.bats` sourcing the file
  from its own `setup()` — exactly the scenario this would otherwise only
  surface for whoever next tried to source this file from a function
  rather than top-level `troubleshoot.sh`.

## Why no init system (s6/tini/dumb-init)

Considered when the question of signal handling for `test_live_block.sh`'s
cleanup trap came up. s6-overlay specifically is for supervising *multiple*
long-running processes in one container — overkill for a single-process
one-shot tool, and it doesn't even solve the actual problem here.

The real problem: `troubleshoot.sh` runs as PID 1 in the container, and
Linux gives PID 1 special treatment — any signal without an explicitly
installed handler is silently ignored by the kernel. A bare `trap cleanup
EXIT` (verified empirically to work fine for a normal, non-PID-1 process)
may not count as an explicit SIGTERM handler in a PID-1 context, meaning
`docker stop` could be ignored until the grace period expires and SIGKILL
forces it — skipping cleanup of the test ban entirely, and SIGKILL can't be
trapped by anything regardless of what supervises the process.

The actual fix costs nothing: `trap cleanup EXIT SIGTERM SIGINT` — naming
the signals explicitly is what makes it a real handler. No tini, no
dumb-init, no s6, no image size or dependency cost. See
`checks/tier2_machine/test_live_block.sh`.
