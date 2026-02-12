#!/usr/bin/env bash
set -euo pipefail

# Clear Game Reminder State
# Usage: clear-state.sh
#
# Resets the notification tracker so reminders can be re-sent.

STATE_FILE="$HOME/.openclaw/game-reminders/notified.json"

if [[ -f "$STATE_FILE" ]]; then
  echo '{}' > "$STATE_FILE"
  echo '{"ok":true,"message":"Notification state cleared"}'
else
  echo '{"ok":true,"message":"No state file found (nothing to clear)"}'
fi
