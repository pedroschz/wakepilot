#!/bin/bash
# Remove wakepilot and put the machine's power settings back.
#   sudo ./uninstall.sh [--purge]     --purge also deletes config, state and logs
#
# Copyright (c) 2026 Pedro Sánchez-Gil. MIT licensed.
set -euo pipefail

[ "$(uname)" = "Darwin" ] || { echo "macOS only."; exit 1; }
[ "$(id -u)" -eq 0 ]      || { echo "Run with sudo:  sudo ./uninstall.sh"; exit 1; }

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

REAL_USER="${SUDO_USER:-$(stat -f%Su /dev/console)}"
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '{print $2}')
REAL_UID=$(id -u "$REAL_USER")

# Disarm first so the machine can't be left held awake.
if [ -x /usr/local/bin/wakepilot ]; then
  /usr/local/bin/wakepilot disarm >/dev/null 2>&1 || true
fi
pmset -a disablesleep 0 >/dev/null 2>&1 || true

# Cancel anything we scheduled, in case disarm couldn't.
pmset -g sched 2>/dev/null | grep -iF "'wakepilot'" | awk '{
  for (i = 1; i < NF; i++)
    if ($i ~ /^[0-9]{1,2}\/[0-9]{1,2}\/[0-9]{2,4}$/ && $(i+1) ~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/) {
      n = split($i, d, "/"); y = d[3]; if (length(y) > 2) y = substr(y, length(y) - 1)
      printf "%02d/%02d/%s %s\n", d[1], d[2], y, $(i+1); break
    }
}' | while IFS= read -r stamp; do
  pmset schedule cancel wake "$stamp" "wakepilot" >/dev/null 2>&1 || true
done

launchctl bootout system/com.wakepilot.daemon 2>/dev/null || true
launchctl bootout "gui/$REAL_UID/com.wakepilot.remote" 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.wakepilot.daemon.plist
rm -f "$REAL_HOME/Library/LaunchAgents/com.wakepilot.remote.plist"
rm -f /usr/local/bin/wakepilot
echo "Removed the daemon, the agent and /usr/local/bin/wakepilot."

if [ "$PURGE" -eq 1 ]; then
  rm -rf /usr/local/var/wakepilot
  rm -f  /usr/local/etc/wakepilot.conf
  rm -f  /usr/local/var/log/wakepilot.log /usr/local/var/log/wakepilot.daemon.log
  rm -f  "$REAL_HOME/Library/Logs/wakepilot-remote.log"
  echo "Purged config, state and logs."
else
  echo "Kept /usr/local/etc/wakepilot.conf and /usr/local/var/wakepilot (use --purge to remove)."
fi

echo "Sleep settings restored. Check with: pmset -g | grep SleepDisabled"
