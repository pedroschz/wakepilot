# wakepilot

**Lid closed. Asleep. Barely sipping power. Then you text it, and it wakes up and hands you a live Claude Code session on your phone.**

That's the whole pitch, and it works, because Claude Code's Remote Control already solved the hard half of the problem for you.

[![CI](https://github.com/pedroschz/wakepilot/actions/workflows/ci.yml/badge.svg)](https://github.com/pedroschz/wakepilot/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey)

---

## Why this is easier than it looks

Remote Control makes **only outbound HTTPS requests and never opens inbound ports**. There is no VPN to configure, no port to forward, no Tailscale, no SSH tunnel, no dynamic DNS. Your Mac dials out; your phone dials out; Anthropic brokers between them.

So the entire engineering problem reduces to one sentence:

> How do I make a sleeping MacBook wake up when I say so, and go back to sleep when I'm done?

That's what wakepilot is. It is about 700 lines of shell, one LaunchDaemon, one LaunchAgent, and a lot of care about not leaving your laptop awake in a bag.

---

## Pick your tier

### Tier 0 — plugged in? Just never sleep.

If the Mac is on AC at home, you don't need any of this:

```bash
sudo pmset -a disablesleep 1
```

Lid closed, display off, `claude remote-control` running. Zero wake latency, zero battery cost, zero complexity. **If this describes your situation, stop reading and do this.** (`sudo pmset -a disablesleep 0` to undo.)

### Tier 1 — on battery: the heartbeat (this repo)

The Mac sleeps for real. Every few minutes it wakes for a few seconds, checks a mailbox, and either goes straight back to sleep or stays up and hands you a session.

The numbers below are **back-of-envelope, not measured** — treat them as shape, not truth, and measure your own machine with `pmset -g log`:

| Mode | Rough cost |
|---|---|
| Pure sleep, no wakepilot | baseline |
| wakepilot @ 15-min polling | baseline plus a rounding error |
| wakepilot @ 5-min polling | baseline plus a slightly larger rounding error |
| Awake with lid closed | your whole afternoon |

The shape is the point: polling costs you very little, staying awake costs you the day.

### Tier 2 — instant wake, no polling delay

Genuinely possible via Bonjour Sleep Proxy / Wake-on-LAN: an always-on device on your LAN (Apple TV, HomePod, a Pi, a capable router) pokes the sleeping Mac and it wakes in about two seconds.

**The catch worth knowing up front:** Apple only supports "Wake for network access" on notebooks *when connected to power*. And if you're connected to power… Tier 0 is simpler and instant. So Tier 2 mostly earns its keep for people who want AC-powered sleep for thermal or noise reasons. Tier 1 is the right answer for the actual unplugged case.

---

## Architecture

```
  Phone  ──POST──▶  ntfy.sh topic
                        │
                        │ (polled)
  ┌─────────────────────┴──────────────────────────────────┐
  │  MacBook, lid shut                                      │
  │                                                          │
  │  pmset schedule wake ──▶ wakes every POLL_MINUTES        │
  │            │                                             │
  │            ▼                                             │
  │  LaunchDaemon (root) ──▶ wakepilot tick                  │
  │            │              ├─ no message? ──▶ pmset sleepnow
  │            │              └─ message! ─────▶ pmset -a disablesleep 1
  │            ▼                                             │
  │  LaunchAgent (you) ──▶ claude remote-control --spawn worktree
  │            │                                             │
  └────────────┼─────────────────────────────────────────────┘
               │ outbound HTTPS only
               ▼
        claude.ai/code  ◀──── your phone
```

Two halves make the wake work and **you need both**:

1. `pmset schedule wake` tells the *hardware* to power on at a given moment.
2. `StartCalendarInterval` in launchd tells *macOS* to run the script at that moment.

The root daemon owns all `pmset` calls. The user agent owns Claude Code, because Remote Control needs your claude.ai login from your keychain — root must never hold that.

---

## Install

```bash
git clone https://github.com/pedroschz/wakepilot.git
cd wakepilot
sudo ./install.sh --project ~/code
```

Then:

```bash
sudo nano /usr/local/etc/wakepilot.conf     # NTFY_TOPIC + SHARED_SECRET
sudo wakepilot selftest
sudo wakepilot arm
```

`selftest` is not decorative. It publishes to your own ntfy topic and reads the message back, schedules and cancels a real `pmset` wake, starts the agent, and waits for Remote Control to actually print **Connected** — then prints your session URL. If something is going to be wrong, it is wrong here rather than at 2am in an airport.

Close the lid and, from anywhere:

```bash
curl -d "my-secret wake" ntfy.sh/my-topic
```

Within `POLL_MINUTES` your phone buzzes with a tappable link into the live environment.

**iOS Shortcut version:** *Get Contents of URL* → `https://ntfy.sh/<topic>` → POST → body `<secret> wake`. Name it "Wake the Mac" and it becomes a Siri phrase and a Lock Screen button.

### Commands you can text it

| Message | Effect |
|---|---|
| `<secret> wake` | wake and hold for `HOLD_MINUTES` |
| `<secret> hold 90` | wake and hold for 90 minutes |
| `<secret> sleep` (or `stop`, `down`) | sleep immediately |
| `<secret> status` | push back a one-line status |
| `<secret> ping` | push back battery and liveness, without holding |
| anything else | treated as `wake` |

### Commands you can run locally

```bash
sudo wakepilot status      # armed? holding? battery? session URL? queued wakes?
sudo wakepilot hold 60     # force it up for an hour
sudo wakepilot release     # drop the hold and sleep now
sudo wakepilot arm         # start the heartbeat
sudo wakepilot disarm      # stop it, cancel our wakes, restore sleep
sudo wakepilot selftest    # end-to-end check
sudo wakepilot logs        # tail -f the log
```

---

## Claude Code prerequisites

From the [Remote Control docs](https://code.claude.com/docs/en/remote-control) — check these before blaming the wake logic:

- **Pro, Max, Team, or Enterprise.** Remote Control refuses API-key auth outright: *"Remote Control is only available with claude.ai subscriptions."* Sign in with `/login`, and unset `ANTHROPIC_API_KEY` if it's in your shell.
- **Workspace trust:** run `claude` in the project directory once by hand and accept the trust dialog. Without it, Remote Control exits immediately with `Error: Workspace not trusted` — the LaunchAgent's `ThrottleInterval` keeps that from becoming a hot restart loop, but nothing will work until you accept it.
- **Don't set** `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, or `DISABLE_GROWTHBOOK` — each disables the feature-flag evaluation Remote Control depends on.
- **`ANTHROPIC_BASE_URL`** must point at `api.anthropic.com`. Bedrock, Vertex, and LLM gateways are out.
- **Turn on push:** `/config` → *Push when Claude decides* and *Push when actions required*. This is what makes the whole thing feel alive — your phone buzzes when Claude finishes or needs a decision.
- **Permissions still get approved from your phone.** `--dangerously-skip-permissions` is not the escape hatch here; write allow-rules into `.claude/settings.json` for the tools you want running unattended.
- **Keep Claude Code current.** Developed and verified against 2.1.212; `install.sh` refuses to proceed if `claude remote-control --help` doesn't work.

`--spawn worktree` is the installer default: every session your phone opens gets its own git worktree, so a task you fire off from a café can't collide with whatever's checked out on your desk. It requires the project to be a git repo — `install.sh` checks. Use `--spawn same-dir` if you'd rather it didn't.

---

## Safety rails (the part that saves your battery when something goes wrong)

The failure mode that actually costs you is: script dies with `disablesleep 1` set, Mac stays awake in a bag, battery gone. wakepilot has layered guards against exactly that:

- **`BATTERY_FLOOR`** — below 25% on battery it sleeps regardless of anything else, and drops to hourly check-ins instead of stopping dead, so plugging in gets you back.
- **`MAX_HOLD_MINUTES`** — hard ceiling, never awake longer than 3 hours, even mid-task.
- **`HOLD_MINUTES`** — idle timeout, auto-extended while Claude is actually burning CPU.
- **`TICK_TIMEOUT_SECONDS`** — a watchdog kills any tick that hangs, and an `EXIT` trap drops the sleep hold on the way out.
- **A stale hold is discarded on reboot** — a hold file written before the last boot is ignored rather than silently keeping a fresh boot awake.
- **One tick at a time** — a lock directory stops two overlapping ticks fighting over `pmset`.
- **Never sleep without a way back** — every sleep path schedules the next wake first. Including quiet hours, which schedules a single wake for the moment quiet hours end.

Plus two politeness guards so it never fights you:

- **`IDLE_GUARD_SECONDS`** — if you touched the keyboard in the last 5 minutes, wakepilot stands down entirely.
- **`RESPECT_OTHER_ASSERTIONS`** — won't force sleep during someone else's build, download, or call.

⚠️ **Thermals:** lid-closed means no keyboard-deck venting. Fine for a Claude Code session; be thoughtful about kicking off a 40-minute Rust build in a padded backpack.

---

## Security, honestly

The thing you are putting on the internet is *a button that wakes your laptop*. The thing behind it is *a full Claude Code session with your repo checked out*. Those deserve different amounts of worry.

- **ntfy.sh sees your messages.** The topic name is the only access control ntfy gives you, so generate it with `openssl rand -hex 16` and never publish it. `SHARED_SECRET` is a second lock so that guessing the topic isn't enough. Neither is encryption. If you care, self-host ntfy and set `NTFY_TOKEN`.
- **The wake command carries no payload.** wakepilot never runs a message as a command — the body only selects between `wake`, `hold`, `sleep`, `status` and `ping`.
- **Real access control lives in Claude Code**, behind your claude.ai login. Someone who learns your topic and secret can wake your Mac and spin the fans. They cannot open a session.
- **The config file holds your secret** and is installed `chmod 600 root:wheel`. Keep it that way.
- **Never fully shut the Mac down.** FileVault's pre-boot login can't be answered remotely. Sleep, always; power off, never.

Found something? See [SECURITY.md](SECURITY.md).

---

## Troubleshooting

```bash
sudo wakepilot status              # everything at a glance
sudo wakepilot logs

pmset -g sched                     # are wakes actually queued?
pmset -g | grep SleepDisabled      # is the hold active?
pmset -g assertions                # who's keeping it awake?
pmset -g log | grep -iE 'wake|sleep' | tail -40   # why did it wake?
```

**It wakes but immediately sleeps again.** The tick isn't taking its hold in time. Confirm the LaunchDaemon `Minute` array matches `POLL_MINUTES` — if the hardware wakes at :05 and launchd doesn't fire until :10, you sleep through the window. `install.sh` generates the array from your config, so this usually means the config changed after installing: re-run `sudo ./install.sh`.

**Nothing happens when I send a message.** Run `sudo wakepilot selftest`. It will tell you which of the six or seven possible things is actually broken.

**Wakes are slow (20–30 s).** Deep standby / hibernation. Push it out:

```bash
sudo pmset -a standbydelaylow 86400 standbydelayhigh 86400
```

Costs a little idle drain, buys much faster wakes.

**Session gone after a long trip.** If the machine is *awake* but can't reach the network for roughly ten minutes, the session times out and the process exits. `KeepAlive` in the agent restarts it — check `~/Library/Logs/wakepilot-remote.log`.

**The remote log is enormous.** It shouldn't be — Remote Control repaints its UI into stdout continuously, which is tens of megabytes a day, and wakepilot trims it on every tick (`REMOTE_LOG_MAX_BYTES`). If it's growing anyway, the daemon isn't ticking.

---

## Development

```bash
./tests/run.sh                # 90 assertions, no root, no network, ~2 seconds
./tests/run.sh quiet          # just the quiet-hours tests
shellcheck -s bash bin/wakepilot install.sh uninstall.sh tests/run.sh
```

The suite sources `bin/wakepilot` as a library and drives it against stubbed `pmset`, `curl`, `ioreg`, `pgrep`, `ps`, `launchctl` and `sysctl`. The `pmset` stub deliberately reproduces the real one's asymmetry — it accepts a two-digit year and prints a four-digit one — because that mismatch is what silently broke wake cancellation in the first place.

Swapping ntfy for a private repo, an S3 object, or a Cloudflare Worker is a rewrite of exactly one function, `poll_mailbox()` in [`bin/wakepilot`](bin/wakepilot). It just has to print one command per line.

## Uninstall

```bash
sudo ./uninstall.sh           # keeps your config and logs
sudo ./uninstall.sh --purge   # removes everything
```

---

## Worth knowing: three official alternatives

Anthropic ships adjacent features that might replace parts of this:

- **[Dispatch](https://code.claude.com/docs/en/desktop)** — message a task from the Claude mobile app and it spawns a Code session on your Mac. Closest thing to "an activation message" out of the box, and needs almost no setup. Still needs the Mac awake, so wakepilot pairs with it rather than competing.
- **[Channels](https://code.claude.com/docs/en/channels)** — pipes Telegram, Discord, or iMessage into a session. Swap ntfy for a channel plugin if you'd rather trigger from a chat app.
- **[Scheduled tasks](https://code.claude.com/docs/en/scheduled-tasks)** — recurring automation, no phone required.

---

## Credits

By **Pedro Sánchez-Gil** ([@pedroschz](https://github.com/pedroschz)).

MIT licensed — see [LICENSE](LICENSE). Contributions welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
