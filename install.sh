#!/bin/bash
# wakepilot installer.  Run:  sudo ./install.sh
#
#   --project DIR    directory Remote Control serves (default: prompt)
#   --spawn MODE     same-dir | worktree | session   (default: worktree)
#   --name NAME      session name shown in claude.ai/code (default: hostname)
#   --yes            never prompt
#
# Copyright (c) 2026 Pedro Sánchez-Gil. MIT licensed.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(uname)" = "Darwin" ] || { echo "wakepilot is macOS only."; exit 1; }

PROJECT_DIR="${WAKEPILOT_PROJECT_DIR:-}"
SPAWN_MODE="worktree"
SESSION_NAME=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="${2:-}"; shift 2 ;;
    --spawn)   SPAWN_MODE="${2:-}";  shift 2 ;;
    --name)    SESSION_NAME="${2:-}"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

case "$SPAWN_MODE" in
  same-dir|worktree|session) : ;;
  *) echo "--spawn must be same-dir, worktree or session."; exit 1 ;;
esac

# Everything past here writes to /Library and /usr/local.
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo:  sudo ./install.sh"; exit 1; }

REAL_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
[ "$REAL_USER" != "root" ] || { echo "Could not work out which user to run Claude Code as."; exit 1; }
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '{print $2}')
REAL_UID=$(id -u "$REAL_USER")
: "${SESSION_NAME:=$(scutil --get ComputerName 2>/dev/null || hostname -s)}"

echo "Installing wakepilot for $REAL_USER ($REAL_HOME)"

# --- find claude, and make sure this build has Remote Control -----------------
CLAUDE_BIN=$(sudo -u "$REAL_USER" -i bash -lc 'command -v claude' 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  echo "!! Couldn't find the 'claude' binary in $REAL_USER's login shell."
  echo "   Install Claude Code first, then re-run. Aborting."
  exit 1
fi
if ! sudo -u "$REAL_USER" -i bash -lc "$CLAUDE_BIN remote-control --help" 2>/dev/null | grep -q 'Remote Control'; then
  echo "!! This Claude Code build has no 'remote-control' command."
  echo "   Run 'claude update' and try again. Aborting."
  exit 1
fi
USER_PATH=$(sudo -u "$REAL_USER" -i bash -lc 'echo $PATH')
echo "   claude:  $CLAUDE_BIN ($(sudo -u "$REAL_USER" -i bash -lc "$CLAUDE_BIN --version" 2>/dev/null | head -1))"

# --- project dir --------------------------------------------------------------
if [ -z "$PROJECT_DIR" ]; then
  [ "$ASSUME_YES" -eq 1 ] && { echo "!! --project is required with --yes."; exit 1; }
  read -r -p "Project directory to serve [$REAL_HOME/code]: " PROJECT_DIR
  PROJECT_DIR="${PROJECT_DIR:-$REAL_HOME/code}"
fi
[ -d "$PROJECT_DIR" ] || { echo "!! $PROJECT_DIR doesn't exist."; exit 1; }
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)

if [ "$SPAWN_MODE" = "worktree" ] && ! sudo -u "$REAL_USER" git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "!! --spawn worktree needs a git repository, and $PROJECT_DIR isn't one."
  echo "   Either 'git init' it or re-run with --spawn same-dir. Aborting."
  exit 1
fi
echo "   project: $PROJECT_DIR (spawn: $SPAWN_MODE)"

# --- lay down files -----------------------------------------------------------
install -d -m 755 /usr/local/bin /usr/local/etc /usr/local/var/wakepilot /usr/local/var/log
install -m 755 "$SRC/bin/wakepilot" /usr/local/bin/wakepilot

if [ ! -f /usr/local/etc/wakepilot.conf ]; then
  install -m 600 -o root -g wheel "$SRC/wakepilot.conf.example" /usr/local/etc/wakepilot.conf
  echo "   wrote /usr/local/etc/wakepilot.conf  <-- EDIT THIS (topic + secret)"
else
  echo "   kept existing /usr/local/etc/wakepilot.conf"
fi

POLL_MINUTES=5
# shellcheck source=/dev/null
. /usr/local/etc/wakepilot.conf
if [ $(( 60 % POLL_MINUTES )) -ne 0 ] || [ "$POLL_MINUTES" -lt 1 ] || [ "$POLL_MINUTES" -gt 60 ]; then
  echo "!! POLL_MINUTES must divide 60 (1,2,3,4,5,6,10,12,15,20,30,60). Got $POLL_MINUTES."
  exit 1
fi

# --- daemon (root) ------------------------------------------------------------
MINUTES_TMP=$(mktemp)
trap 'rm -f "$MINUTES_TMP"' EXIT
for ((m = 0; m < 60; m += POLL_MINUTES)); do
  printf '        <dict><key>Minute</key><integer>%d</integer></dict>\n' "$m" >> "$MINUTES_TMP"
done

awk -v f="$MINUTES_TMP" '
  /__MINUTES__/ { while ((getline line < f) > 0) print line; next }
  { print }
' "$SRC/launchd/com.wakepilot.daemon.plist" > /Library/LaunchDaemons/com.wakepilot.daemon.plist

chown root:wheel /Library/LaunchDaemons/com.wakepilot.daemon.plist
chmod 644        /Library/LaunchDaemons/com.wakepilot.daemon.plist
plutil -lint /Library/LaunchDaemons/com.wakepilot.daemon.plist >/dev/null
launchctl bootout system/com.wakepilot.daemon 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.wakepilot.daemon.plist
echo "   daemon loaded (ticks every ${POLL_MINUTES}min)"

# --- agent (user) -------------------------------------------------------------
AGENT="$REAL_HOME/Library/LaunchAgents/com.wakepilot.remote.plist"
install -d -m 755 -o "$REAL_USER" "$REAL_HOME/Library/LaunchAgents" "$REAL_HOME/Library/Logs"
sed -e "s|__CLAUDE_BIN__|$CLAUDE_BIN|g" \
    -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
    -e "s|__HOME__|$REAL_HOME|g" \
    -e "s|__PATH__|$USER_PATH|g" \
    -e "s|__SESSION_NAME__|$SESSION_NAME|g" \
    -e "s|__SPAWN_MODE__|$SPAWN_MODE|g" \
    "$SRC/launchd/com.wakepilot.remote.plist" > "$AGENT"
chown "$REAL_USER" "$AGENT"; chmod 644 "$AGENT"
plutil -lint "$AGENT" >/dev/null

launchctl bootout "gui/$REAL_UID/com.wakepilot.remote" 2>/dev/null || true
launchctl bootstrap "gui/$REAL_UID" "$AGENT"
echo "   agent loaded (claude remote-control in $PROJECT_DIR)"

# --- power prefs --------------------------------------------------------------
pmset -a womp 1         >/dev/null 2>&1 || true   # wake for network access
pmset -a disablesleep 0 >/dev/null 2>&1 || true   # start from a clean slate

cat <<EOF

Done. Next:

  1. sudo nano /usr/local/etc/wakepilot.conf     # set NTFY_TOPIC + SHARED_SECRET
  2. cd $PROJECT_DIR && claude                   # once, to accept workspace trust
     ...then /config -> "Push when actions required" = on
  3. sudo wakepilot selftest                     # checks every moving part
  4. sudo wakepilot arm
  5. Close the lid. From your phone:
       curl -d "<secret> wake" ntfy.sh/<your-topic>

  sudo wakepilot status
  sudo wakepilot logs
EOF
