#!/usr/bin/env bash
set -euo pipefail

# Game Session Reminder — Check and Notify
# Usage: check-and-notify.sh [hours_ahead] [channel_id]
#
# Queries the Zordon API for upcoming sessions within the lookahead window,
# checks against the notified state file, and sends Discord embed reminders
# for any sessions not yet notified.

HOURS_AHEAD="${1:-24}"
CHANNEL_OVERRIDE="${2:-}"

# --- Environment checks ---
for var in ZORDON_API_URL ZORDON_API_KEY DISCORD_BOT_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "{\"error\":\"${var} is not set\"}" >&2
    exit 1
  fi
done

# --- State file ---
STATE_DIR="$HOME/.openclaw/game-reminders"
STATE_FILE="${STATE_DIR}/notified.json"
mkdir -p "$STATE_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{}' > "$STATE_FILE"
fi

# --- Compute lookahead days (round up hours to days, minimum 1) ---
DAYS=$(( (HOURS_AHEAD + 23) / 24 ))

# --- Fetch upcoming schedule ---
SCHEDULE=$(curl -sfk --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer ${ZORDON_API_KEY}" \
  -H "Accept: application/json" \
  "${ZORDON_API_URL}/games/schedule?days=${DAYS}" 2>&1) || {
  echo '{"error":"Failed to fetch schedule from Zordon API"}' >&2
  exit 1
}

# --- Auto-detect a default channel if none provided ---
if [[ -z "$CHANNEL_OVERRIDE" ]]; then
  # Try to find an announcements or general channel from OpenClaw config
  CHANNEL_OVERRIDE=$(python3 -c "
import json, sys
try:
    with open('$HOME/.openclaw/openclaw.json') as f:
        c = json.load(f)
    guilds = c.get('channels',{}).get('discord',{}).get('guilds',{})
    guild = list(guilds.values())[0]
    channels = guild.get('channels', {})
    # Use first explicitly configured channel, or fall back
    for cid in channels:
        if cid != '*':
            print(cid)
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null) || true
fi

# --- Process sessions and send reminders ---
RESULT=$(SCHEDULE_JSON="$SCHEDULE" STATE_PATH="$STATE_FILE" \
  NOTIFY_CHANNEL="${CHANNEL_OVERRIDE}" HOURS="${HOURS_AHEAD}" \
  BOT_TOKEN="$DISCORD_BOT_TOKEN" \
  python3 << 'PYEOF'
import json, os, sys, time, urllib.request, urllib.error
from datetime import datetime, timezone, timedelta

schedule_raw = os.environ['SCHEDULE_JSON']
state_path = os.environ['STATE_PATH']
channel_id = os.environ.get('NOTIFY_CHANNEL', '')
hours_ahead = int(os.environ.get('HOURS', '24'))
bot_token = os.environ['BOT_TOKEN']

# Load state
with open(state_path) as f:
    notified = json.load(f)

# Parse schedule
try:
    sessions = json.loads(schedule_raw)
    if isinstance(sessions, dict) and 'error' in sessions:
        print(json.dumps({'error': sessions['error'], 'sent': 0}))
        sys.exit(0)
    if isinstance(sessions, dict) and 'sessions' in sessions:
        sessions = sessions['sessions']
    if not isinstance(sessions, list):
        sessions = []
except json.JSONDecodeError:
    print(json.dumps({'error': 'Invalid JSON from Zordon API', 'sent': 0}))
    sys.exit(0)

now = datetime.now(timezone.utc)
cutoff = now + timedelta(hours=hours_ahead)
sent_count = 0
errors = []

for session in sessions:
    game_id = str(session.get('gameId') or session.get('game_id') or session.get('id', 'unknown'))
    session_date = session.get('nextSession') or session.get('next_session') or session.get('date', '')
    state_key = f"{game_id}:{session_date}"

    # Skip if already notified
    if state_key in notified:
        continue

    # Parse session time
    try:
        if isinstance(session_date, str):
            dt = datetime.fromisoformat(session_date.replace('Z', '+00:00'))
        else:
            continue
    except (ValueError, TypeError):
        continue

    # Skip if outside our lookahead window
    if dt > cutoff or dt < now:
        continue

    # Build embed
    game_name = session.get('name') or session.get('gameName') or session.get('game_name', 'Unknown Game')
    system_name = session.get('system') or session.get('systemName') or session.get('system_name', '')
    gm_name = session.get('gm') or session.get('gmName') or session.get('gm_name', '')
    price = session.get('price', 'Free')
    if price == 0 or price == '0':
        price = 'Free'
    seats = session.get('seats') or session.get('availableSeats') or ''
    max_seats = session.get('maxSeats') or session.get('max_seats') or ''
    url = session.get('url') or session.get('link', '')

    unix_ts = int(dt.timestamp())

    # Color: green=open seats, yellow=needs players, red=full
    color = 39423  # default blue
    if seats and max_seats:
        try:
            s, ms = int(seats), int(max_seats)
            if s >= ms:
                color = 16711680  # red - full
            elif s > 0:
                color = 65280    # green - open
            else:
                color = 16776960 # yellow - needs players
        except (ValueError, TypeError):
            pass

    fields = []
    if system_name:
        fields.append({'name': 'System', 'value': system_name, 'inline': True})
    if gm_name:
        fields.append({'name': 'GM', 'value': gm_name, 'inline': True})
    fields.append({'name': 'Time', 'value': f'<t:{unix_ts}:F>\n<t:{unix_ts}:R>', 'inline': True})
    if price:
        fields.append({'name': 'Price', 'value': str(price), 'inline': True})
    if seats and max_seats:
        fields.append({'name': 'Seats', 'value': f'{seats}/{max_seats}', 'inline': True})

    embed = {
        'title': f'\U0001f3ae Reminder: {game_name}',
        'color': color,
        'fields': fields,
        'footer': {'text': 'Zordon \u2022 Game Reminder'},
        'timestamp': datetime.now(timezone.utc).isoformat()
    }
    if url:
        embed['url'] = url

    # Determine target channel
    target_channel = channel_id
    session_channel = session.get('channelId') or session.get('channel_id', '')
    if session_channel:
        target_channel = str(session_channel)
    elif not target_channel:
        continue  # no channel to post to

    # Send via Discord REST API
    payload = json.dumps({'embeds': [embed]}).encode('utf-8')
    req = urllib.request.Request(
        f'https://discord.com/api/v10/channels/{target_channel}/messages',
        data=payload,
        headers={
            'Authorization': f'Bot {bot_token}',
            'Content-Type': 'application/json',
        },
        method='POST'
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            resp.read()
        notified[state_key] = datetime.now(timezone.utc).isoformat()
        sent_count += 1
    except (urllib.error.URLError, urllib.error.HTTPError) as e:
        errors.append(f'{game_name}: {str(e)}')

# Save state
with open(state_path, 'w') as f:
    json.dump(notified, f, indent=2)

result = {'sent': sent_count, 'checked': len(sessions)}
if errors:
    result['errors'] = errors
print(json.dumps(result, indent=2))
PYEOF
)

echo "$RESULT"
