# Custom parser: OpenSSH 9.6+ failed-auth message additions

## The gap

`crowdsecurity/sshd-logs` (hub, confirmed current as of Sep 2026 via
`cscli hub list`) does not match two message shapes produced by OpenSSH
9.6p1 (seen on Ubuntu-3ubuntu13.19):

```
Sep  4 23:15:41 uptimekuma sshd[1714650]: error: maximum authentication attempts exceeded for invalid user nonexistentuser123 from 127.0.0.1 port 56876 ssh2 [preauth]
Sep  4 23:15:41 uptimekuma sshd[1714650]: Disconnecting invalid user nonexistentuser123 127.0.0.1 port 56876: Too many authentication failures [preauth]
```

Confirmed with `cscli explain --type syslog -v` against real, freshly
generated log lines on a native (non-Docker) install: `s00-raw` (timestamp
and syslog parsing) was green; `s01-parse` failed to match either line
against any grok pattern in `sshd-logs.yaml`, so neither is ever
classified as `ssh_failed-auth` and neither is visible to any scenario
(e.g. `crowdsecurity/ssh-bf`).

The closest existing hub patterns don't fit, checked against the actual
upstream file
([`parsers/s01-parse/crowdsecurity/sshd-logs.yaml`](https://github.com/crowdsecurity/hub/blob/master/parsers/s01-parse/crowdsecurity/sshd-logs.yaml)):

- `SSHD_INVALID_USER` requires the line to start with `Invalid user ...`.
  The "maximum authentication attempts exceeded" line never starts with
  that phrase — it's a different sentence entirely, just one that happens
  to contain the substring "invalid user".
- `SSHD_PREAUTH_AUTHENTICATING_USER_ALT` requires `Disconnected from
  (authenticating|invalid) user ...`. OpenSSH 9.6 instead logs
  `Disconnecting (authenticating|invalid) user ...` — present tense, no
  "from" — a different literal, so the grok doesn't match.

## The fix

[`custom-sshd-openssh96.yaml`](./custom-sshd-openssh96.yaml) adds two new
grok patterns as a **separate file**, not an edit to the hub-managed
`sshd-logs.yaml`:

- `SSHD_MAX_AUTH_ATTEMPTS_EXCEEDED` — matches the "maximum authentication
  attempts exceeded" line, for both invalid and valid usernames.
- `SSHD_DISCONNECTING_USER` — matches the present-tense "Disconnecting
  (authenticating|invalid) user ..." line.

Both nodes set `log_type: ssh_failed-auth` plus `target_user` and
`source_ip`, the same statics shape `sshd-logs.yaml` itself uses (via
`sshd_invalid_user`/`sshd_client_ip` intermediate fields), so downstream
scenarios that key off `evt.Parsed.log_type == "ssh_failed-auth"` (like
`crowdsecurity/ssh-bf`) pick these events up exactly as they would a
hub-matched one.

### Install

```bash
sudo cp custom-sshd-openssh96.yaml /etc/crowdsec/parsers/s01-parse/
sudo crowdsec -t                 # validate config syntax
sudo systemctl reload crowdsec   # or: sudo systemctl restart crowdsec
```

Do **not** name it `sshd-logs.yaml` or place it under
`/etc/crowdsec/hub/...` — that's hub-managed territory and `cscli hub
update && cscli hub upgrade` will overwrite or flag-as-tainted anything
there. A plain, distinctly-named file directly in the stage directory
(`s01-parse/`) is loaded by the engine alongside the hub file and is left
alone by hub commands.

### Validate

```bash
cscli explain --file fixture-openssh96.log --type syslog -v
```

Expected: all four lines in `fixture-openssh96.log` go green through
`s01-parse`, each producing a `ssh_failed-auth` event with `target_user`
and `source_ip` populated. Before installing the custom parser, re-run the
same command to confirm they currently fail at `s01-parse` — that's the
before/after that proves the fix, not just that the file loads without
error.

You can also test a single line directly:

```bash
cscli explain --log 'Sep  4 23:15:41 uptimekuma sshd[1714650]: error: maximum authentication attempts exceeded for invalid user nonexistentuser123 from 127.0.0.1 port 56876 ssh2 [preauth]' --type syslog -v
```

## Why no bats test in this repo

`crowdsec-troubleshooter`'s bats suite (see its `CLAUDE.md`/`CONTRIBUTING.md`)
tests this repo's own bash health-check scripts against a mocked LAPI HTTP
server — it has no CrowdSec engine or `cscli` binary in CI to run a real
`cscli explain` against. There's nothing to mock here (grok matching is
the CrowdSec engine's own logic, not code this repo owns), so a bats test
would either be vacuous or would need a real `cscli`/engine in CI, which
is out of scope for this tool. The `cscli explain` commands above are the
actual validation step and must be run against a real install, per this
repo's own "verify against something real, not just a mock" convention.

## Upstream issue

This is worth reporting to `crowdsecurity/hub` since anyone on OpenSSH
9.6+ (Ubuntu 24.04's default) likely hits the same gap. Draft below.

---

**Title:** `sshd-logs`: missing patterns for OpenSSH 9.6+ "maximum
authentication attempts exceeded" and "Disconnecting ... user" wording

**Body:**

`crowdsecurity/sshd-logs` doesn't match two message shapes emitted by
OpenSSH 9.6p1 (Ubuntu-3ubuntu13.19, i.e. Ubuntu 24.04's default sshd):

```
error: maximum authentication attempts exceeded for invalid user <user> from <ip> port <port> ssh2 [preauth]
Disconnecting invalid user <user> <ip> port <port>: Too many authentication failures [preauth]
```

Confirmed via `cscli explain --type syslog -v` against real log lines:
`s00-raw` parses fine, `s01-parse` fails to match either against
`sshd-logs.yaml`, so these auth failures are never classified as
`ssh_failed-auth` and never reach `ssh-bf` (or any other scenario keyed
off that log_type).

The closest existing patterns don't cover the new wording:
- `SSHD_INVALID_USER` only matches lines starting with `Invalid user ...`.
- `SSHD_PREAUTH_AUTHENTICATING_USER_ALT` matches `Disconnected from
  (authenticating|invalid) user ...`, but OpenSSH 9.6 logs `Disconnecting
  (authenticating|invalid) user ...` (present tense, no "from") instead.

Suggested additional grok patterns (tested locally as a supplemental
parser file, happy to open a PR if useful):

```yaml
SSHD_MAX_AUTH_ATTEMPTS_EXCEEDED: 'error: maximum authentication attempts exceeded for (invalid user )?%{USERNAME:sshd_invalid_user} from %{IP_WORKAROUND:sshd_client_ip} port \d+ ssh2( \[preauth\])?'
SSHD_DISCONNECTING_USER: 'Disconnecting (authenticating|invalid) user %{USERNAME:sshd_invalid_user} %{IP_WORKAROUND:sshd_client_ip} port \d+: %{GREEDYDATA} \[preauth\]'
```

Environment: CrowdSec (native/systemd install), OpenSSH 9.6p1
Ubuntu-3ubuntu13.19, Ubuntu 24.04.
