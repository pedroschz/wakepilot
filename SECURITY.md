# Security Policy

## Reporting a vulnerability

Please open a [private security advisory](https://github.com/pedroschz/wakepilot/security/advisories/new)
rather than a public issue. I'll acknowledge within a few days.

## Threat model, briefly

wakepilot exposes **one capability to the internet: a button that wakes your
Mac.** It does not expose a shell, and it never executes message content. A
message body only selects between `wake`, `hold`, `sleep`, `status` and `ping`;
anything unrecognised is treated as `wake`.

The valuable thing behind the button — a Claude Code session with your repo in
it — is protected by your claude.ai login, not by wakepilot. Someone who learns
your ntfy topic and shared secret can wake your laptop and drain its battery.
They cannot open a session.

## What is and isn't protected

| | |
|---|---|
| ntfy topic name | The only access control ntfy offers. Generate with `openssl rand -hex 16`, never publish it. |
| `SHARED_SECRET` | A second lock, checked as an exact prefix. Guessing the topic alone isn't enough. |
| Message contents | **Visible to ntfy.sh in plaintext.** Self-host ntfy and set `NTFY_TOKEN` if that matters to you. |
| `/usr/local/etc/wakepilot.conf` | Holds the secret. Installed `chmod 600`, owner `root:wheel`. |
| Claude Code session access | Your claude.ai account. Out of wakepilot's hands entirely. |
| Tool permissions in a remote session | Approved from your phone, or by allow-rules you write into `.claude/settings.json`. |

## Notes for anyone auditing

- The root daemon deliberately never touches Claude credentials. Claude Code
  runs as your user via a separate LaunchAgent, and the two communicate only
  through `launchctl kickstart` and a log file.
- `poll_mailbox()` parses ntfy JSON with awk and never evaluates it.
- The shared secret is compared with a shell prefix match, which is not
  constant time. For a wake button that is an acceptable trade; if you disagree,
  self-host ntfy with token auth and the comparison stops being the weak link.
