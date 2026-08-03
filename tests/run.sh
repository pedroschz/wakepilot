#!/bin/bash
# wakepilot test suite.
#
# Sources bin/wakepilot as a library and drives it against stubbed pmset, curl,
# ioreg, pgrep, ps, launchctl and sysctl. No root, no network, no real sleeping.
#
#   ./tests/run.sh            run everything
#   ./tests/run.sh quiet      run only tests whose name contains "quiet"
#
# Assertions and test bodies are dispatched by name, and config variables are
# consumed by the sourced library, so shellcheck can't see either being used.
# shellcheck disable=SC2034,SC2329
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${1:-}"
CURRENT=""

TALLY=$(mktemp -d "${TMPDIR:-/tmp}/wakepilot-tally.XXXXXX")
export TALLY
: > "$TALLY/pass"; : > "$TALLY/fail"
trap 'rm -rf "$TALLY"' EXIT

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

ok()  { echo . >> "$TALLY/pass"; }
bad() { echo . >> "$TALLY/fail"; red "  ✗ $CURRENT — $*"; }

assert_eq() {
  if [ "$1" = "$2" ]; then ok; else bad "expected '$2', got '$1'${3:+  ($3)}"; fi
}
assert_contains() {
  case "$1" in *"$2"*) ok ;; *) bad "expected '$2' in: $(printf '%s' "$1" | tr '\n' ' ' | head -c 200)" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) bad "did not expect '$2' here" ;; *) ok ;; esac
}
assert_true()  { if "$@" >/dev/null 2>&1; then ok; else bad "expected success: $*"; fi; }
assert_false() { if "$@" >/dev/null 2>&1; then bad "expected failure: $*"; else ok; fi; }

# --------------------------------------------------------------- environment ---
# A fresh sandbox per test: stub PATH, temp state dir, temp config.

setup() {
  CURRENT="$1"
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/wakepilot-test.XXXXXX")
  export STUB_DIR="$SANDBOX/stub"
  mkdir -p "$STUB_DIR"
  : > "$STUB_DIR/calls"
  : > "$STUB_DIR/sched"
  : > "$STUB_DIR/posts"
  : > "$STUB_DIR/ntfy_messages"
  echo 0 > "$STUB_DIR/disablesleep"
  echo 3600 > "$STUB_DIR/hid_idle"
  echo 0.0 > "$STUB_DIR/claude_cpu"
  printf "Now drawing from 'AC Power'\n -InternalBattery-0\t80%%; charged\n" > "$STUB_DIR/batt"

  export PATH="$ROOT/tests/stubs:$PATH"
  export WAKEPILOT_STATE_DIR="$SANDBOX/state"
  export WAKEPILOT_LOG="$SANDBOX/wakepilot.log"
  export WAKEPILOT_CONF="$SANDBOX/wakepilot.conf"
  {
    echo 'NTFY_SERVER="https://ntfy.example"'
    echo 'NTFY_TOPIC="test-topic"'
    echo 'SHARED_SECRET="s3cret"'
    echo 'POLL_MINUTES=5'
    echo 'HOLD_MINUTES=45'
    echo 'MAX_HOLD_MINUTES=180'
    echo 'BATTERY_FLOOR=25'
    echo 'BATTERY_SAVER_POLL_MINUTES=60'
    echo 'QUIET_HOURS=""'
    printf 'CLAUDE_USER="%s"\n' "$(id -un)"
    printf 'REMOTE_LOG="%s/remote.log"\n' "$SANDBOX"
  } > "$WAKEPILOT_CONF"
  : > "$SANDBOX/remote.log"

  # shellcheck source=/dev/null
  WAKEPILOT_LIB=1 . "$ROOT/bin/wakepilot"

  # Test seams: no root, no waiting, no watchdog killing the test runner.
  is_root()        { return 0; }
  pause()          { :; }
  start_watchdog() { WATCHDOG_PID=""; }
  sync()           { :; }
}

teardown() { rm -rf "$SANDBOX"; }

run() {
  local name="$1"
  case "$name" in *"$FILTER"*) : ;; *) return 0 ;; esac
  dim "  $name"
  ( setup "$name"; "test_$2"; teardown ) || true
}

# do_tick installs an EXIT trap that only fires when the shell exits, which is
# too late for assertions. Tests call this instead.
tick() { do_tick; local rc=$?; release_tick_guard; return "$rc"; }

calls() { cat "$STUB_DIR/calls" 2>/dev/null; }
posts() { cat "$STUB_DIR/posts" 2>/dev/null; }
sched() { cat "$STUB_DIR/sched" 2>/dev/null; }
slept() { grep -q SLEEPNOW "$STUB_DIR/calls" 2>/dev/null; }
held()  { [ "$(cat "$STUB_DIR/disablesleep" 2>/dev/null)" = "1" ]; }

# A window guaranteed to contain the current time, whenever the suite runs.
quiet_window_covering_now() { printf '%s-%s' "$(date -v-1H '+%H:%M')" "$(date -v+1H '+%H:%M')"; }

# An ntfy JSON line the way the real server sends it.
ntfy_line() {
  printf '{"id":"%s","time":%s,"expires":9999999999,"event":"message","topic":"test-topic","message":"%s"}\n' \
    "$1" "$2" "$3"
}
inbox() { ntfy_line "m$RANDOM" "$(now)" "$1" > "$STUB_DIR/ntfy_messages"; }

# =============================================================== the tests ===

# --- quiet hours -------------------------------------------------------------

test_quiet_hours_window() {
  QUIET_HOURS="01:00-07:00"
  assert_true  in_quiet_hours 120      # 02:00
  assert_true  in_quiet_hours 60       # 01:00, inclusive start
  assert_false in_quiet_hours 420      # 07:00, exclusive end
  assert_false in_quiet_hours 1380     # 23:00
}

test_quiet_hours_across_midnight() {
  QUIET_HOURS="23:00-06:30"
  assert_true  in_quiet_hours 1400     # 23:20
  assert_true  in_quiet_hours 10       # 00:10
  assert_true  in_quiet_hours 389      # 06:29
  assert_false in_quiet_hours 390      # 06:30
  assert_false in_quiet_hours 720      # 12:00
}

test_quiet_hours_disabled() {
  QUIET_HOURS=""
  assert_false in_quiet_hours 120
}

# Regression: cancelling every wake at the start of quiet hours without
# scheduling one for the end left the Mac asleep until someone opened the lid.
test_quiet_hours_still_schedules_a_way_back() {
  QUIET_HOURS=$(quiet_window_covering_now)
  local times
  times=$(wake_schedule)
  assert_eq "$(printf '%s\n' "$times" | grep -c .)" "1" "exactly one wake, at the end of quiet hours"
  assert_true [ "$times" -gt "$(now)" ]
}

test_quiet_hours_tick_sleeps_but_leaves_a_wake_queued() {
  QUIET_HOURS=$(quiet_window_covering_now)
  touch "$WAKEPILOT_STATE_DIR/armed"
  tick
  assert_true slept
  assert_eq "$(sched | grep -c .)" "1"
  assert_contains "$(sched)" "by 'wakepilot'"
}

# --- scheduled wakes ---------------------------------------------------------

# Regression: pmset prints a four-digit year but only accepts a two-digit one,
# so the old cancel path never matched and scheduled wakes piled up forever.
test_clear_wakes_cancels_our_own() {
  schedule_wakes
  assert_eq "$(sched | grep -c .)" "4" "four slots queued"
  assert_contains "$(sched)" "by 'wakepilot'"
  assert_contains "$(sched)" "/20"     # four-digit year on the way out
  clear_wakes
  assert_eq "$(sched | grep -c .)" "0" "all of ours cancelled"
}

# Regression: cancelling by bare timestamp also killed Do Not Disturb and the
# OS analytics timer.
test_clear_wakes_leaves_other_owners_alone() {
  printf " [0]  wake at 08/02/2026 22:00:00 by 'com.apple.alarm.user-visible-donotdisturb'\n" > "$STUB_DIR/sched"
  schedule_wakes
  clear_wakes
  assert_eq "$(sched | grep -c .)" "1" "only Apple's event survives"
  assert_contains "$(sched)" "com.apple.alarm"
}

test_schedule_wakes_is_idempotent() {
  schedule_wakes; schedule_wakes; schedule_wakes
  assert_eq "$(sched | grep -c .)" "4" "no duplicate pile-up"
}

test_wake_schedule_uses_the_poll_grid() {
  POLL_MINUTES=5
  local first second
  first=$(wake_schedule | head -1)
  second=$(wake_schedule | sed -n 2p)
  assert_eq "$(( second - first ))" "300" "five minutes apart"
  assert_eq "$(( first % 300 ))" "0" "aligned to the grid"
}

test_wake_schedule_backs_off_on_low_battery() {
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0\t9%%; discharging\n" > "$STUB_DIR/batt"
  local first second
  first=$(wake_schedule | head -1)
  second=$(wake_schedule | sed -n 2p)
  assert_eq "$(( second - first ))" "3600" "an hour apart once the battery is low"
}

# --- mailbox -----------------------------------------------------------------

test_ntfy_decode_reads_real_json() {
  local out
  out=$(ntfy_line "abc123" 1785724405 "s3cret wake" | _ntfy_decode)
  assert_eq "$out" "$(printf '1785724405\tabc123\ts3cret wake')"
}

test_ntfy_decode_survives_escapes() {
  local out
  out=$(printf '{"id":"i1","time":5,"event":"message","message":"say \\"hi\\" now"}\n' | _ntfy_decode)
  assert_contains "$out" 'say "hi" now'
}

test_ntfy_decode_ignores_keepalives() {
  local out
  out=$(printf '{"id":"k1","time":5,"event":"keepalive","topic":"t"}\n' | _ntfy_decode)
  assert_eq "$out" ""
}

test_mailbox_strips_the_shared_secret() {
  inbox "s3cret wake"
  assert_eq "$(poll_mailbox)" "wake"
}

test_mailbox_rejects_a_wrong_secret() {
  inbox "wrong wake"
  assert_eq "$(poll_mailbox)" ""
}

test_mailbox_treats_a_bare_secret_as_wake() {
  inbox "s3cret"
  assert_eq "$(poll_mailbox)" "wake"
}

test_mailbox_delivers_each_message_once() {
  inbox "s3cret wake"
  assert_eq "$(poll_mailbox)" "wake"
  assert_eq "$(poll_mailbox)" "" "the same id is not replayed"
}

test_mailbox_handles_a_curl_failure() {
  echo 7 > "$STUB_DIR/curl_rc"
  assert_eq "$(poll_mailbox)" ""
}

# --- session url -------------------------------------------------------------

test_session_url_from_a_real_log() {
  cp "$ROOT/tests/fixtures/remote-control.log" "$REMOTE_LOG"
  local u
  u=$(session_url)
  assert_eq "$u" "https://claude.ai/code?environment=env_0123456789abcdefgh"
  assert_not_contains "$u" "$(printf '\033')"
}

test_session_url_falls_back_when_the_log_is_empty() {
  assert_eq "$(session_url)" "https://claude.ai/code"
}

test_session_url_is_remembered_after_a_log_trim() {
  cp "$ROOT/tests/fixtures/remote-control.log" "$REMOTE_LOG"
  session_url > /dev/null
  : > "$REMOTE_LOG"
  assert_eq "$(session_url)" "https://claude.ai/code?environment=env_0123456789abcdefgh"
}

# --- log maintenance ---------------------------------------------------------

# Regression: remote-control repaints its UI into the log continuously, which
# is roughly 30 MB a day if nothing trims it.
test_trim_log_caps_a_runaway_log() {
  local f="$SANDBOX/big.log" i before after
  for i in $(seq 1 2000); do printf 'noisy repaint line %s\n' "$i" >> "$f"; done
  before=$(stat -f%z "$f")
  trim_log "$f" 4096
  after=$(stat -f%z "$f")
  assert_true [ "$before" -gt 4096 ]
  assert_true [ "$after" -le 4096 ]
  assert_true [ "$after" -gt 0 ]
  assert_contains "$(tail -1 "$f")" "line 2000"     # keeps the newest end
}

test_trim_log_leaves_a_small_log_alone() {
  local f="$SANDBOX/small.log"
  echo "hello" > "$f"
  trim_log "$f" 4096
  assert_eq "$(cat "$f")" "hello"
}

# --- the tick ----------------------------------------------------------------

test_tick_disarmed_clears_everything() {
  schedule_wakes
  tick
  assert_eq "$(sched | grep -c .)" "0" "no wakes while disarmed"
  assert_false held
  assert_false slept
}

test_tick_wake_message_holds_the_mac_up() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  inbox "s3cret wake"
  tick
  assert_false slept
  assert_true held
  assert_true [ "$(hold_until)" -gt "$(now)" ]
  assert_contains "$(calls)" "launchctl kickstart"
  assert_contains "$(posts)" "Awake and listening"
  assert_true [ "$(sched | grep -c .)" -gt 0 ]
}

test_tick_hold_message_honours_a_duration() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  inbox "s3cret hold 10"
  tick
  local remaining=$(( $(hold_until) - $(now) ))
  assert_true [ "$remaining" -gt 500 ]
  assert_true [ "$remaining" -le 600 ]
}

test_tick_sleep_message_sleeps_now() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  inbox "s3cret sleep"
  tick
  assert_true slept
  assert_false held
  assert_eq "$(hold_until)" "0"
}

# Regression: the Mac must never be put to sleep without a scheduled way back.
test_tick_always_schedules_a_wake_before_sleeping() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  tick
  assert_true slept
  assert_true [ "$(sched | grep -c .)" -gt 0 ]
  assert_contains "$(sched)" "by 'wakepilot'"
}

test_tick_stands_down_when_you_are_at_the_keyboard() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  echo 5 > "$STUB_DIR/hid_idle"
  tick
  assert_false slept
  assert_false held      # hands off, but not held awake either
}

test_tick_respects_another_apps_assertion() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  cat > "$STUB_DIR/assertions" <<'A'
Listed by owning process:
  pid 900(Xcode): [0x0001] 00:20:00 PreventUserIdleSystemSleep named: "build"
A
  tick
  assert_false slept
}

test_tick_sleeps_at_the_battery_floor() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  printf "Now drawing from 'Battery Power'\n -InternalBattery-0\t11%%; discharging\n" > "$STUB_DIR/batt"
  begin_hold 45
  tick
  assert_true slept
  assert_contains "$(posts)" "Battery down to 11%"
  assert_contains "$(sched)" "by 'wakepilot'"
}

test_tick_ignores_the_battery_floor_on_ac() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  printf "Now drawing from 'AC Power'\n -InternalBattery-0\t11%%; charging\n" > "$STUB_DIR/batt"
  begin_hold 45
  tick
  assert_false slept
  assert_true held
}

test_tick_extends_the_hold_while_claude_works() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  echo 65.0 > "$STUB_DIR/claude_cpu"
  begin_hold 45
  echo $(( $(now) - 30 )) > "$WAKEPILOT_STATE_DIR/hold_until"   # already expired
  tick
  assert_false slept
  assert_true [ "$(hold_until)" -gt "$(now)" ]
}

test_tick_sleeps_when_an_idle_hold_expires() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  begin_hold 45
  echo $(( $(now) - 30 )) > "$WAKEPILOT_STATE_DIR/hold_until"
  tick
  assert_true slept
  assert_contains "$(posts)" "Idle for"
}

test_tick_enforces_the_max_hold_ceiling() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  echo 99.0 > "$STUB_DIR/claude_cpu"        # busy, but out of time regardless
  begin_hold 45
  echo $(( $(now) - 4 * 3600 )) > "$WAKEPILOT_STATE_DIR/hold_started"
  tick
  assert_true slept
  assert_contains "$(posts)" "ceiling"
}

# Regression: a hold file surviving a reboot used to keep a freshly booted Mac
# awake indefinitely.
test_tick_discards_a_hold_from_before_the_last_boot() {
  begin_hold 45
  echo $(( $(now) - 10000 )) > "$WAKEPILOT_STATE_DIR/hold_started"
  echo $(( $(now) - 60 ))    > "$STUB_DIR/boottime"     # booted a minute ago
  assert_eq "$(hold_until)" "0"
}

test_tick_keeps_a_hold_from_this_boot() {
  begin_hold 45
  assert_true [ "$(hold_until)" -gt "$(now)" ]
}

test_tick_refuses_to_run_twice_at_once() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  mkdir -p "$WAKEPILOT_STATE_DIR/tick.lock"
  do_tick
  assert_false slept
  assert_contains "$(cat "$WAKEPILOT_LOG")" "another tick is already running"
}

test_tick_answers_a_status_request() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  inbox "s3cret status"
  tick
  assert_contains "$(posts)" "armed=yes"
}

test_tick_ignores_a_message_with_the_wrong_secret() {
  touch "$WAKEPILOT_STATE_DIR/armed"
  inbox "guess wake"
  tick
  assert_true slept          # treated as no message at all
  assert_false held
}

# --- packaging ---------------------------------------------------------------

lint_plist() { plutil -lint "$1" >/dev/null 2>&1; }

test_daemon_plist_is_valid_after_substitution() {
  local out="$SANDBOX/daemon.plist" minutes="$SANDBOX/minutes" m
  for m in 0 15 30 45; do
    printf '        <dict><key>Minute</key><integer>%d</integer></dict>\n' "$m" >> "$minutes"
  done
  awk -v f="$minutes" '/__MINUTES__/ { while ((getline line < f) > 0) print line; next } { print }' \
    "$ROOT/launchd/com.wakepilot.daemon.plist" > "$out"
  assert_true lint_plist "$out"
  assert_not_contains "$(cat "$out")" "__MINUTES__"
  assert_eq "$(grep -c '<key>Minute</key>' "$out")" "4" "the comment must not be expanded too"
}

test_remote_plist_is_valid_after_substitution() {
  local out="$SANDBOX/remote.plist"
  sed -e 's|__CLAUDE_BIN__|/opt/homebrew/bin/claude|g' \
      -e 's|__PROJECT_DIR__|/Users/demo/code|g' \
      -e 's|__HOME__|/Users/demo|g' \
      -e 's|__PATH__|/usr/bin:/bin|g' \
      -e 's|__SESSION_NAME__|MacBook|g' \
      -e 's|__SPAWN_MODE__|worktree|g' \
      "$ROOT/launchd/com.wakepilot.remote.plist" > "$out"
  assert_true lint_plist "$out"
  assert_not_contains "$(cat "$out")" "__"
}

# Regression: scutil hands back whatever the user named their Mac. An "&" broke
# the plist XML, and a bare "&" in a sed replacement expands to the whole match.
test_remote_plist_survives_an_awkward_computer_name() {
  local out="$SANDBOX/awkward.plist" name="Ana & Luis's <MacBook>"
  xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  sed_esc() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
  subst()   { sed_esc "$(xml_esc "$1")"; }

  sed -e "s|__CLAUDE_BIN__|$(subst /opt/homebrew/bin/claude)|g" \
      -e "s|__PROJECT_DIR__|$(subst "/Users/demo/R&D")|g" \
      -e "s|__HOME__|$(subst /Users/demo)|g" \
      -e "s|__PATH__|$(subst /usr/bin:/bin)|g" \
      -e "s|__SESSION_NAME__|$(subst "$name")|g" \
      -e "s|__SPAWN_MODE__|$(subst worktree)|g" \
      "$ROOT/launchd/com.wakepilot.remote.plist" > "$out"

  assert_true lint_plist "$out"
  assert_contains "$(cat "$out")" "Ana &amp; Luis's &lt;MacBook&gt;"
  assert_contains "$(cat "$out")" "/Users/demo/R&amp;D"
  # And it must survive the round trip back out of the plist.
  assert_eq "$(plutil -extract ProgramArguments.3 raw -o - "$out")" "$name"
}

test_config_example_covers_every_documented_setting() {
  local key missing=""
  for key in NTFY_SERVER NTFY_TOPIC NTFY_TOKEN SHARED_SECRET POLL_MINUTES \
             HOLD_MINUTES MAX_HOLD_MINUTES QUIET_HOURS BATTERY_FLOOR \
             BATTERY_SAVER_POLL_MINUTES IDLE_GUARD_SECONDS \
             RESPECT_OTHER_ASSERTIONS TICK_TIMEOUT_SECONDS LOG_MAX_BYTES \
             REMOTE_LOG_MAX_BYTES CLAUDE_USER REMOTE_LOG; do
    grep -q "^$key=" "$ROOT/wakepilot.conf.example" || missing="$missing $key"
  done
  assert_eq "$missing" ""
}

test_scripts_parse() {
  assert_true bash -n "$ROOT/bin/wakepilot"
  assert_true bash -n "$ROOT/install.sh"
  assert_true bash -n "$ROOT/uninstall.sh"
}

# =================================================================== driver ===

echo "wakepilot tests"

run "quiet hours: window"                    quiet_hours_window
run "quiet hours: across midnight"           quiet_hours_across_midnight
run "quiet hours: disabled"                  quiet_hours_disabled
run "quiet hours: schedules a way back"      quiet_hours_still_schedules_a_way_back
run "quiet hours: tick leaves a wake queued" quiet_hours_tick_sleeps_but_leaves_a_wake_queued

run "wakes: cancels our own"                 clear_wakes_cancels_our_own
run "wakes: leaves other owners alone"       clear_wakes_leaves_other_owners_alone
run "wakes: scheduling is idempotent"        schedule_wakes_is_idempotent
run "wakes: uses the poll grid"              wake_schedule_uses_the_poll_grid
run "wakes: backs off on low battery"        wake_schedule_backs_off_on_low_battery

run "mailbox: decodes real json"             ntfy_decode_reads_real_json
run "mailbox: survives escapes"              ntfy_decode_survives_escapes
run "mailbox: ignores keepalives"            ntfy_decode_ignores_keepalives
run "mailbox: strips the shared secret"      mailbox_strips_the_shared_secret
run "mailbox: rejects a wrong secret"        mailbox_rejects_a_wrong_secret
run "mailbox: bare secret means wake"        mailbox_treats_a_bare_secret_as_wake
run "mailbox: delivers each message once"    mailbox_delivers_each_message_once
run "mailbox: handles a curl failure"        mailbox_handles_a_curl_failure

run "url: from a real log"                   session_url_from_a_real_log
run "url: falls back when empty"             session_url_falls_back_when_the_log_is_empty
run "url: remembered after a trim"           session_url_is_remembered_after_a_log_trim

run "logs: caps a runaway log"               trim_log_caps_a_runaway_log
run "logs: leaves a small log alone"         trim_log_leaves_a_small_log_alone

run "tick: disarmed clears everything"       tick_disarmed_clears_everything
run "tick: wake message holds it up"         tick_wake_message_holds_the_mac_up
run "tick: hold message honours a duration"  tick_hold_message_honours_a_duration
run "tick: sleep message sleeps now"         tick_sleep_message_sleeps_now
run "tick: schedules a wake before sleep"    tick_always_schedules_a_wake_before_sleeping
run "tick: stands down at the keyboard"      tick_stands_down_when_you_are_at_the_keyboard
run "tick: respects other assertions"        tick_respects_another_apps_assertion
run "tick: sleeps at the battery floor"      tick_sleeps_at_the_battery_floor
run "tick: ignores the floor on AC"          tick_ignores_the_battery_floor_on_ac
run "tick: extends while claude works"       tick_extends_the_hold_while_claude_works
run "tick: sleeps when a hold expires"       tick_sleeps_when_an_idle_hold_expires
run "tick: enforces the max ceiling"         tick_enforces_the_max_hold_ceiling
run "tick: discards a pre-boot hold"         tick_discards_a_hold_from_before_the_last_boot
run "tick: keeps a hold from this boot"      tick_keeps_a_hold_from_this_boot
run "tick: refuses to run twice"             tick_refuses_to_run_twice_at_once
run "tick: answers a status request"         tick_answers_a_status_request
run "tick: ignores a bad secret"             tick_ignores_a_message_with_the_wrong_secret

run "packaging: daemon plist"                daemon_plist_is_valid_after_substitution
run "packaging: remote plist"                remote_plist_is_valid_after_substitution
run "packaging: awkward computer name"       remote_plist_survives_an_awkward_computer_name
run "packaging: config example"              config_example_covers_every_documented_setting
run "packaging: scripts parse"               scripts_parse

PASS=$(grep -c . "$TALLY/pass" 2>/dev/null); PASS=${PASS:-0}
FAIL=$(grep -c . "$TALLY/fail" 2>/dev/null); FAIL=${FAIL:-0}

echo
if [ "$FAIL" -eq 0 ]; then
  green "$PASS assertions passed."
  exit 0
else
  red "$FAIL assertion(s) failed, $PASS passed."
  exit 1
fi
