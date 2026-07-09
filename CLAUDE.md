# CLAUDE.md

Read this automatically at the start of every session in this repo. See
`DESIGN.md` for *why* things are built this way — this file is the *how* for
actually working on it.

## Ground rules, non-negotiable

- **No `docker.sock`, ever, in this tool.** If a task seems to need it,
  that's a signal to find a network-only or read-only-mount alternative
  instead, not a reason to add it. See `DESIGN.md` for the reasoning.
- **No daemon mode.** Everything is `docker run --rm`. Don't add a
  `restart:` policy, a `HEALTHCHECK` that implies long-running, or a loop.
- **No `CAP_ADD`/`--privileged` in the troubleshooter's own container.**
  The firewall bouncer needs `NET_ADMIN`/`NET_RAW` for its own job — that's
  fine, it's a different container. This tool's own container should never
  need any capability beyond making an HTTP request.
- **Every credential-gated check must degrade gracefully.** If
  `capability_check.sh` didn't confirm access, the check must call `skip()`
  from `lib/common.sh` and exit 0 — never error, never crash the whole run.
- **Every `add_*` setup script needs a matching `remove_*` counterpart,**
  and the `add_*` script should print the removal command as part of its
  own output. Don't add one without the other.

## Before considering any check "done"

1. Run `bash -n` on it — syntax errors should never reach a commit.
2. Actually run it against a mock server (see the smoke-test pattern used
   for `check_lapi_alive.sh` and `check_metrics_liveness.sh` in git history
   — spin up a throwaway `python3 -m http.server`-style mock, don't just
   read the code and assume it's correct). Two real bugs were caught this
   way already (see the second commit) — assume more exist until tested.
3. Test both the happy path AND the unreachable/failure path explicitly.
   A check that only handles success isn't finished.

## Open items — check DESIGN.md before "fixing" these

- `check_capi.sh` and `test_appsec_probe.sh` are flagged placeholders with
  unresolved open questions, not incomplete code to finish blindly. Read
  the comment block at the top of each before touching them.
- `check_ip.sh`'s `jq` logic is reviewed-but-unexecuted (no `jq` available
  in the environment this was scaffolded in). Verify it actually works
  against a real LAPI response before trusting it.
- `versioncheck/cve.sh` has no real implementation yet — it takes a manual
  hint. Don't invent an LAPI-version-detection mechanism without confirming
  it actually exists in the API first (see the bouncer-listing lesson in
  `DESIGN.md` — assuming an endpoint exists without checking cost real
  rework once already).

## Commit style

Look at the two existing commits for the expected level of detail — explain
*what broke and how it was caught*, not just *what changed*. This project's
history is meant to be readable as a record of what was actually verified,
not just a changelog.
