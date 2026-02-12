#!/usr/bin/env bash
set -euo pipefail

# Weekly Game Schedule Digest
# Usage: weekly-digest.sh [channel_id]
#
# Posts a single rich embed summarizing all sessions in the next 7 days.

CHANNEL_ID="${1:-}"

# --- Environment checks ---
for var in ZORDON_API_URL ZORDON_API_KEY DISCORD_BOT_TOKEN; do
  if [[ -z "${!var:-}" ]]; then
    echo "{\"error\":\"${var} is not set\"}" >&2
    exit 1
  fi
done

# --- Fetch 7-day schedule ---
SCHEDULE=$(curl -sfk --connect-timeout 5 --max-time 15 \
  -H "Authorization: Bearer ${ZORDON_API_KEY}" \
  -H "Accept: application/json" \
  "${ZORDON_API_URL}/games/schedule?days=7" 2>&1) || {
  echo '{"error":"Failed to fetch schedule from Zordon API"}' >&2
  exit 1
}

# --- Auto-detect channel if not provided ---
if [[ -z "$CHANNEL_ID" ]]; then
  CHANNEL_ID=$(python3 -c "
import json, sys
try:
    with open('$HOME/.openclaw/openclaw.json') as f:
        c = json.load(f)
    guilds = c.get('channels',{}).get('discord',{}).get('guilds',{})
    guild = list(guilds.values())[0]
    channels = guild.get('channels', {})
    for cid in channels:
        if cid != '*':
            print(cid)
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null) || {
    echo '{"error":"No channel ID provided and could not auto-detect one"}' >&2
    exit 1
  }
fi

# --- Build and send digest embed ---
RESULT=$(SCHEDULE_JSON="$SCHEDULE" TARGET_CHANNEL="$CHANNEL_ID" \
  BOT_TOKEN="$DISCORD_BOT_TOKEN" \
  python3 << 'PYEOF'
import json, os, sys, urllib.request, urllib.error
from datetime import datetime, timezone

schedule_raw = os.environ['SCHEDULE_JSON']
channel_id = os.environ['TARGET_CHANNEL']
bot_token = os.environ['BOT_TOKEN']

try:
    sessions = json.loads(schedule_raw)
    if isinstance(sessions, dict) and 'sessions' in sessions:
        sessions = sessions['sessions']
    if isinstance(sessions, dict) and 'error' in sessions:
        print(json.dumps({'error': sessions['error'], 'sent': 0}))
        sys.exit(0)
    if not isinstance(sessions, list):
        sessions = []
except json.JSONDecodeError:
    print(json.dumps({'error': 'Invalid JSON from Zordon API', 'sent': 0}))
    sys.exit(0)

if not sessions:
    print(json.dumps({'sent': 0, 'message': 'No sessions in the next 7 days'}))
    sys.exit(0)

# Sort sessions by date
def parse_date(s):
    d = s.get('nextSession') or s.get('next_session') or s.get('date', '')
    try:
        return datetime.fromisoformat(str(d).replace('Z', '+00:00'))
    except:
        return datetime.max.replace(tzinfo=timezone.utc)

sessions.sort(key=parse_date)

# Build fields (one per session, max 25 for Discord embed limit)
fields = []
for session in sessions[:25]:
    game_name = session.get('name') or session.get('gameName') or session.get('game_name', 'Unknown')
    system_name = session.get('system') or session.get('systemName') or session.get('system_name', '')
    gm_name = session.get('gm') or session.get('gmName') or session.get('gm_name', '')
    price = session.get('price', 'Free')
    if price == 0 or price == '0':
        price = 'Free'
    seats = session.get('seats') or session.get('availableSeats') or ''
    max_seats = session.get('maxSeats') or session.get('max_seats') or ''

    session_date = session.get('nextSession') or session.get('next_session') or session.get('date', '')
    try:
        dt = datetime.fromisoformat(str(session_date).replace('Z', '+00:00'))
        unix_ts = int(dt.timestamp())
        time_str = f'<t:{unix_ts}:F> (<t:{unix_ts}:R>)'
    except:
        time_str = str(session_date)

    parts = [time_str]
    if system_name:
        parts.append(f'**System:** {system_name}')
    if gm_name:
        parts.append(f'**GM:** {gm_name}')
    detail_parts = []
    if price:
        detail_parts.append(str(price))
    if seats and max_seats:
        detail_parts.append(f'{seats}/{max_seats} seats')
    if detail_parts:
        parts.append(' \u2022 '.join(detail_parts))

    fields.append({
        'name': game_name,
        'value': '\n'.join(parts),
        'inline': False
    })

embed = {
    'title': '\U0001f4c5 Weekly Game Schedule',
    'description': f'{len(sessions)} session{"s" if len(sessions) != 1 else ""} scheduled this week:',
    'color': 7506394,  # Discord blurple
    'fields': fields,
    'footer': {'text': 'Zordon \u2022 Weekly Digest'},
    'timestamp': datetime.now(timezone.utc).isoformat()
}

# Send
payload = json.dumps({'embeds': [embed]}).encode('utf-8')
req = urllib.request.Request(
    f'https://discord.com/api/v10/channels/{channel_id}/messages',
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
    print(json.dumps({'sent': 1, 'sessions': len(sessions), 'channel': channel_id}))
except (urllib.error.URLError, urllib.error.HTTPError) as e:
    print(json.dumps({'error': str(e), 'sent': 0}))
PYEOF
)

echo "$RESULT"
