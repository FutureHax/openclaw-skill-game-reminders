---
name: game-reminders
description: Send proactive game session reminders to Discord channels. Queries the Zordon API for upcoming sessions and posts embed notifications at configurable intervals.
metadata: {"openclaw":{"requires":{"env":["ZORDON_API_URL","ZORDON_API_KEY","DISCORD_BOT_TOKEN"]}}}
---

# Game Reminders

Send automated reminders about upcoming game sessions to Discord. This skill queries the Zordon API schedule and posts rich embed notifications to the relevant channels.

## When to use

Use this skill when:
- The owner asks to set up or manage game reminders
- The owner wants a weekly schedule digest posted
- You need to manually trigger a reminder check (e.g., "send reminders for tonight's games")

## Tools

### `check-and-notify.sh` -- Check for upcoming sessions and send reminders

```bash
bash {baseDir}/tools/check-and-notify.sh [hours_ahead] [channel_id]
```

**Arguments:**
- `hours_ahead` (optional, default: 24) -- How many hours ahead to look for sessions
- `channel_id` (optional) -- Override channel; if omitted, posts to the default announcements channel

The script:
1. Queries `/games/schedule?days=1` from the Zordon API
2. Checks each session against a "last notified" state file to avoid duplicates
3. Sends a rich embed for each upcoming session that hasn't been notified yet
4. Records the notification in the state file

### `weekly-digest.sh` -- Post a weekly schedule summary

```bash
bash {baseDir}/tools/weekly-digest.sh [channel_id]
```

Posts a single embed summarizing all sessions in the next 7 days. Ideal for a Monday morning cron job.

### `clear-state.sh` -- Reset the notification state

```bash
bash {baseDir}/tools/clear-state.sh
```

Clears the "last notified" tracker. Use if reminders need to be re-sent.

## Automated scheduling

For fully automated reminders, set up a cron job or systemd timer on the VPS:

```bash
# Example crontab entries (run as marvin on VPS):
# Daily reminder check at 9 AM for sessions in the next 24 hours
0 9 * * * export PATH="$HOME/.npm-global/bin:$PATH" && bash ~/.openclaw/skills/game-reminders/tools/check-and-notify.sh 24

# Weekly digest every Monday at 8 AM
0 8 * * 1 export PATH="$HOME/.npm-global/bin:$PATH" && bash ~/.openclaw/skills/game-reminders/tools/weekly-digest.sh
```

## State management

The skill tracks which sessions have already been notified in:
```
~/.openclaw/game-reminders/notified.json
```

This prevents duplicate reminders when the check script runs multiple times. The state file is a JSON object mapping game ID + session date to the notification timestamp.

## Guidelines

- Always use Discord embed format (via the Discord REST API) for reminder messages
- Always use Discord dynamic timestamps (`<t:UNIX:F>` and `<t:UNIX:R>`)
- Include: game name, system, GM, time, price, available seats, and a link
- Use the Zordon embed color scheme (green for open seats, yellow for needs players, red for full)
- Keep automated reminders to one embed per game session -- no spam
