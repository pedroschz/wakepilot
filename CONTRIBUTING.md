# Contributing to wakepilot

Thanks for looking. This is a small project with an unusually unforgiving
failure mode — a bug here can leave someone's laptop awake in a bag with the
lid shut — so the bar for changes to the power logic is "prove it".

## Before you open a PR

```bash
./tests/run.sh
shellcheck -s bash bin/wakepilot install.sh uninstall.sh tests/run.sh tests/stubs/*
```

Both must be clean. CI runs exactly these on `macos-latest`.

## Ground rules

**Never sleep without scheduling a wake first.** Every path that calls
`pmset sleepnow` must have queued the next wake. `go_to_sleep()` does this for
you; don't route around it.

**Every new failure mode needs a guard and a test.** If you add a branch that
can hold the machine awake, add the condition that releases it, and add a test
that proves the release happens.

**Regressions get a named test.** The suite is deliberately full of tests whose
comment starts with "Regression:" and explains the real-world breakage. If you
fix something subtle, write that down the same way — the comment is worth more
than the assertion.

**Target bash 3.2.** That's what `/bin/bash` is on macOS. No associative
arrays, no `${var,,}`, no `mapfile`.

**macOS only.** `pmset`, `launchd`, `ioreg` and BSD `date`/`stat` are load
bearing. This will never run on Linux and that's fine.

## The test suite

`tests/run.sh` sources `bin/wakepilot` with `WAKEPILOT_LIB=1`, which skips the
CLI dispatch and leaves every function callable. Real system commands are
replaced by stubs in `tests/stubs/` that read and write canned state under
`$STUB_DIR`.

The stubs are meant to be *faithful*, not convenient. `tests/stubs/pmset`
reproduces the real `pmset`'s two-digit-in / four-digit-out year handling
specifically because that asymmetry caused a real bug. If you find another
place where a stub is kinder than reality, make it meaner.

Tests override three seams so they can run fast and rootless:
`is_root`, `pause`, and `start_watchdog`. If you add something that sleeps,
shells out to a slow tool, or spawns a background process, give it a seam too.

## Anything touching pmset

The one thing the suite cannot check is whether real `pmset schedule` behaves
the way the stub says it does. If you change `schedule_wakes` or `clear_wakes`,
run this on a real machine and paste the output in the PR:

```bash
sudo wakepilot selftest      # includes a live schedule/cancel round trip
pmset -g sched               # before and after
```

## Reporting bugs

Include `sudo wakepilot status`, the tail of `/usr/local/var/log/wakepilot.log`,
your `POLL_MINUTES`, and whether the machine was on AC. Redact your topic and
secret before pasting anything.
