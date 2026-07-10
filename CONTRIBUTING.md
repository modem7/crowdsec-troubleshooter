# Contributing

## Issues

- Search existing issues before opening a new one.
- Use the provided templates for bug reports and feature requests.

## Before considering any change "done"

Same checklist `CLAUDE.md` holds Claude to — applies to any contributor:

1. `bash -n` on every script you touched — syntax errors should never
   reach a commit.
2. `shellcheck --severity=warning` against every script you touched.
   `.shellcheckrc` handles the dynamic-source-path noise; a real warning
   is a real warning.
3. Add a `bats` test in `tests/` and actually run it — see the existing
   `tests/*.bats` files for the mock-server pattern
   (`tests/test_helper.bash`). Real bugs in this project have consistently
   been caught this way, not by reading the code — assume more exist
   until tested. Test both the happy path *and* the failure path.
4. `bats tests/*.bats` and `docker build .` locally before opening a PR —
   CI runs the same checks, but a red CI run over something catchable
   locally is just wasted round-trips.

If you can, verify against something real, not just a mock — a real LAPI
instance, a real `docker inspect`, a real Traefik config. Several real bugs
in this project's history shipped past mocks and code review because the
external system (a LAPI endpoint, a CLI's output format, a middleware's
syntax) behaved subtly differently than assumed — see `DESIGN.md`'s
"Corrections made mid-design" section for the specific examples. A mock
only proves your code does what your mock says it should; it can't catch
the mock itself being wrong.

## Verify external behavior before relying on it

If your change calls a LAPI endpoint, a CLI command (`docker inspect`,
`cscli ...`), or relies on a specific third-party syntax (a Traefik
middleware, a Compose label), check what it actually does — read the real
source, hit the real endpoint, run the real command — before writing code
against an assumed shape. This has cost real rework in this project more
than once (see `DESIGN.md`); it's cheaper to check first.

## Pull Requests

- Fork the repo and create your branch from `master`.
- **One concern per PR.** If a fix surfaces an unrelated bug or a bigger
  idea along the way, flag it and split it into its own PR rather than
  bundling it in — makes review and any future revert far cleaner. Small,
  frequent PRs are preferred over one large one.
- Ensure your changes don't break existing functionality — the checklist
  above is how you confirm that, not just eyeballing the diff.
- Update documentation if needed: `README.md`/`FLAGS.md` for anything
  user-facing (a new flag, mount, or check), `DESIGN.md` for *why* a
  non-obvious decision was made or a real bug was found and fixed,
  `CLAUDE.md` for a new working convention or gotcha future contributors
  (human or AI) should know about.
- Write commit messages that explain *what broke and how it was caught*,
  not just *what changed* — see the existing commit history for the
  expected level of detail. This project's history is meant to be
  readable as a record of what was actually verified.

## Adding a new check

- Pick the right tier directory (`checks/tier{0,1,2,3}_*`) based on what
  credential or mount it needs — see the tier model in `README.md`.
- Every credential/mount-gated check must call `skip()` from
  `lib/common.sh` and exit 0 when its input isn't configured — never
  error, never crash the whole run. The one exception is advice that's
  universally relevant regardless of setup (see
  `check_hub_update_cron.sh` and its own header comment for why that one
  doesn't use `skip()`).
- If the check's finding is really "here's a known external
  limitation/bug, not something this tool can fix," consider whether it
  belongs in `lib/known_issues.sh` (with a `kb_hint <id>` call from the
  check) instead of inline text — see `check_bouncer_type.sh` for the
  pattern. Every KB entry's link must actually resolve (`curl` it) before
  it's added.
- A new `setup/add_*.sh` needs a matching `setup/remove_*.sh` (same for
  `register_*`/`unregister_*`) — CI enforces this pairing exists, but the
  `add_*` script should also print its own removal command as part of its
  output, which CI can't check for you.

## Code Style

- Follow the `.editorconfig` settings (LF line endings, UTF-8, trailing
  newline).
- Bash, not POSIX sh — every script already assumes bash-specific features
  (arrays, `[[`, herestrings, `local -n` namerefs), so there's no reason
  to write around that. Every script must start with `set -uo pipefail`
  (CI enforces this).
- Prefer `cmd <<<"$var"` over `echo "$var" | cmd` — a herestring produces
  identical input to what `echo | cmd` would, without forking a separate
  `echo` process. Reserve `cat` for genuinely concatenating multiple files
  (`cat "$a" "$b" | ...`), not piping a single file/variable into a
  command that could just read it directly.
- A bare `[[ cond ]] && action` as the *last* statement in a function
  leaks `cond`'s exit status as the function's own return value when
  false — use `if cond; then action; fi` instead if that matters (it
  usually does), or add an explicit trailing `return 0`.
- A `grep` (or similar) that legitimately finds nothing inside a
  `$(...)` pipeline needs `|| true` at the end — under `set -o pipefail`
  (which every script here sets), a clean "no match" otherwise reads as a
  pipeline failure, which trips `set -e` immediately in any context where
  it's active (bats test bodies run under `-e`, even though this
  project's own scripts don't set it themselves).
