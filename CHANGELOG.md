# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-08-02

First public release. The prototype worked in outline but had several bugs that
only show up after hours of unattended running; this release fixes them and adds
a test suite that would have caught each one.

### Fixed

- **Scheduled wakes were never cancelled.** `pmset` prints a four-digit year
  (`08/02/2026`) but only accepts a two-digit one, so the cancel path matched
  nothing and scheduled events accumulated indefinitely.
- **Cancelling wakes clobbered other apps' events.** Cancellation now matches on
  an owner tag, so Do Not Disturb and the OS analytics timer are left alone.
- **Quiet hours left the Mac asleep forever.** The start of the window cancelled
  every wake without scheduling one for the end. Every sleep path now queues the
  next wake before sleeping, and quiet hours queues one for its own end.
- **Boot time was parsed wrong.** A greedy `sed` matched `usec` instead of
  `sec` in `kern.boottime`, so uptime always came back as the current epoch and
  stale-hold detection never fired.
- **The installer couldn't find its own files.** It referenced `bin/` and
  `launchd/` subdirectories in a flat source tree.
- **The remote-control log grew without bound.** Remote Control repaints its UI
  into stdout continuously — roughly 30 MB/day. Both logs are now trimmed on
  every tick.
- **`< file 2>/dev/null` printed to stderr anyway** when the file was missing,
  because the input redirect is applied before stderr is silenced.
- **The battery floor only applied during an active hold**, so a machine idling
  below the floor kept waking on the normal schedule.
- **Session URLs were scraped with ANSI escapes attached.** Output is stripped
  and the environment deep link is preferred, with the last known URL cached.

### Added

- `uninstall.sh`, with `--purge`.
- A real `selftest`: publishes to your ntfy topic and reads it back, schedules
  and cancels a live `pmset` wake, starts the agent and waits for Remote Control
  to print `Connected`.
- Test suite — 90 assertions against stubbed `pmset`, `curl`, `ioreg`, `pgrep`,
  `ps`, `launchctl` and `sysctl`. No root, no network.
- GitHub Actions CI running shellcheck and the suite on `macos-latest`.
- Message commands `hold <minutes>`, `status` and `ping`.
- A tick watchdog and an `EXIT` trap, so a hung tick can't leave the machine
  held awake.
- A lock directory, so two overlapping ticks can't fight over `pmset`.
- `BATTERY_SAVER_POLL_MINUTES`: below the battery floor, check in hourly rather
  than stopping dead, so plugging in brings the machine back.
- Notification de-duplication, so a repeating condition doesn't buzz your phone
  every tick.
- Installer flags `--project`, `--spawn`, `--name`, `--yes`; validation that
  `POLL_MINUTES` divides 60, that the project is a git repo when spawning
  worktrees, that this Claude Code build has `remote-control`, and `plutil`
  linting of both generated plists.

### Changed

- The daemon's `ProcessType` is `Standard` rather than `Background`, which is
  throttled — a tick has a short wake window to spend a network round trip in.
- The agent's `ThrottleInterval` is 60s, so an untrusted workspace or a signed-out
  account can't become a hot restart loop.
- ntfy polling reads JSON with awk instead of `grep`/`sed`, tracks a cursor by
  message timestamp, and de-duplicates by message id, so a message arriving
  mid-poll is re-seen rather than lost.
