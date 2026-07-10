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

1. Run `bash -n` on it — syntax errors should never reach a commit. CI
   enforces this, but don't rely on CI to catch what you can catch locally.
2. Run `shellcheck --severity=warning` against it. `.shellcheckrc` handles
   the dynamic-source-path noise; a real warning is a real warning.
3. Add a `bats` test in `tests/` and actually run it — see the existing
   `tests/*.bats` files for the mock-server pattern (`tests/test_helper.bash`).
   Two real bugs were only caught this way, not by reading the code — assume
   more exist until tested. Test both the happy path AND the failure path.
4. `bash tests/*.bats` and `docker build .` locally before pushing — CI runs
   the same checks, but a red CI run on a solo project is just wasted time.

## Verify external behavior before relying on it — don't guess

The single most common source of real bugs in this project's history
(`DESIGN.md`'s "Corrections made mid-design" section has the full list):
code written against an *assumed* shape of an external system — a LAPI
endpoint, a `docker inspect --format` template, a Traefik middleware
syntax — that turned out subtly wrong the first time it ran against the
real thing. Concrete examples already paid for the hard way: `POST
/v1/decisions` doesn't exist (LAPI only exposes GET/DELETE there; adding a
decision means POSTing a full synthetic `Alert` to `/v1/alerts`, traced
from CrowdSec's actual Go source); `cscli bouncers list` is database-only,
unreachable over LAPI's HTTP API at any credential tier; `docker inspect
--format` renders a missing label differently depending on whether the
template uses `index` (empty string) or dot-notation (`"<no value>"`).

Before writing a check or fix against an external command/API/tool:
verify the real behavior (read the actual source, hit the actual
endpoint, run the actual command against a real instance) rather than
inferring it from documentation prose, a plausible-looking example, or
what "should" be true. This cost real rework more than once already —
treat it as cheaper to check first every time.

## Two bash gotchas that have caused real, hard-to-spot bugs here

- **A bare `[[ cond ]] && action` as the *last* statement in a function
  leaks `cond`'s exit status as the whole function's return value when
  `cond` is false** — unlike `if cond; then action; fi`, which correctly
  returns 0 regardless. Bit `wizard.sh`'s `parse_compose()` this way: a
  legitimately-false condition mid-function silently became the whole
  function's failure, only caught by a test that happened to hit that
  exact code path. If a conditional action is genuinely the last thing a
  function does, either convert it to real `if`/`fi`, or add an explicit
  trailing `return 0`/`exit 0` as a second, independent guard.
- **A `grep` that legitimately finds nothing, inside a `$(...)` pipeline,
  under `set -o pipefail`, trips `set -e` immediately if `-e` happens to
  be active anywhere in the call chain** — even though none of this
  tool's own scripts set `-e` themselves. bats test bodies *do* run under
  `-e`, which is exactly how this was found: a manual `source wizard.sh;
  someFunc` run looked completely fine, while the equivalent bats test
  aborted mid-function pointing at the exact `grep` line. Any pipeline
  where "no match" is a normal, expected outcome (not an error) needs
  `|| true` at the end — see `extract_label_value()` and the several call
  sites around it in `wizard.sh` for the pattern.

## Known-issues KB (`lib/known_issues.sh`)

If a check's finding is really "here's a known external limitation/bug,
not something this tool can fix" (a CrowdSec/Traefik/bouncer quirk, a
version regression, an upstream API gap), it likely belongs as an entry in
`lib/known_issues.sh` with a `kb_hint <id>` call from the check, rather
than growing the check's own inline text. Every entry's link must be
verified to actually resolve (`curl` it) before adding — see
`check_bouncer_type.sh`'s `kb_hint` call for the pattern, and `DESIGN.md`'s
"Known-issues KB as data" section for why this is a separate data file
instead of more check-script string literals. Browse the current set with
`troubleshoot.sh issues`.

## Open items — check DESIGN.md before "fixing" these

- `check_capi.sh` and `test_appsec_probe.sh` are flagged placeholders with
  unresolved open questions, not incomplete code to finish blindly. Read
  the comment block at the top of each before touching them.
- `versioncheck/cve.sh` has no real implementation yet — it takes a manual
  hint. Don't invent an LAPI-version-detection mechanism without confirming
  it actually exists in the API first (see the bouncer-listing lesson in
  `DESIGN.md` — assuming an endpoint exists without checking cost real
  rework once already).

## Commit style

Look at the existing commit history for the expected level of detail —
explain *what broke and how it was caught*, not just *what changed*. This
project's history is meant to be readable as a record of what was actually
verified, not just a changelog.
