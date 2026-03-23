# Telegram Sessions — Setup Guide

Per-chat Telegram sessions for Claude Code. Each Telegram chat gets its own
isolated Claude Code session via tmux, with per-chat access control,
project-specific workdirs, and automatic CLAUDE.md chain loading.

## Prerequisites

- Claude Code with `--channels` support (v2.1.80+)
- Telegram bot configured: `/telegram:configure <token>`
- tmux installed
- A Telegram bot token from [@BotFather](https://t.me/BotFather)

## How It Works

Unlike Discord, the Telegram Bot API does not expose a channel/group listing
endpoint. This means:

- **No auto-discover.** You spawn sessions manually for each chat you want.
- **No thread support.** Telegram threads are handled within the same chat context.
- The watchdog only respawns dead sessions (no discovery cycle).

Each chat session gets:
- A tmux session `tg-<chat_id>` running Claude Code with `--channels telegram`
- A per-chat `TELEGRAM_STATE_DIR` with scoped `access.json`
- A registry entry in `sessions.json`

## Setup

### 1. Create your Telegram bot

1. Message [@BotFather](https://t.me/BotFather) on Telegram
2. Send `/newbot` and follow the prompts
3. Copy the bot token (e.g., `123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11`)
4. Configure it in Claude Code: `/telegram:configure <token>`

### 2. Get your Telegram user ID

Your numeric Telegram user ID is needed for the access allowlist. To find it:

1. Message [@userinfobot](https://t.me/userinfobot) on Telegram
2. It replies with your user ID (a number like `123456789`)

### 3. Configure the session manager

Run the interactive setup:

```bash
./scripts/telegram-session-manager.sh init
```

This creates `~/.claude/telegram-sessions/config.env`:

```bash
TELEGRAM_ALLOWED_USER_ID="123456789"
TELEGRAM_SESSION_WORKDIR="$HOME"
```

Or create it manually. The only required field is `TELEGRAM_ALLOWED_USER_ID`.

### 4. Get chat IDs

To find the chat ID for a conversation:

1. Start your bot in the target chat (DM it or add it to a group)
2. Send a message to the bot
3. Check for updates: `curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool`
4. Look for `"chat": {"id": ...}` in the response

For groups, the chat ID is typically negative (e.g., `-1001234567890`).

### 5. Spawn sessions

```bash
# Spawn a session for a specific chat
./scripts/telegram-session-manager.sh spawn 123456789 --name "my-dm"

# Spawn with a project-specific workdir
./scripts/telegram-session-manager.sh spawn -1001234567890 --name "team-group" --workdir ~/projects/myapp

# Spawn with a custom system prompt
./scripts/telegram-session-manager.sh spawn 123456789 --name "code-helper" --system-prompt "You are a code review assistant."
```

### 6. Start the watchdog

```bash
./scripts/telegram-watchdog.sh --daemon
```

The watchdog checks every 30s and respawns any dead sessions.

## Commands Reference

### Session Manager

```bash
./scripts/telegram-session-manager.sh init                # Interactive setup
./scripts/telegram-session-manager.sh spawn <chat_id>     # Spawn a session
./scripts/telegram-session-manager.sh list                # List with UP/DOWN status
./scripts/telegram-session-manager.sh status              # Overview
./scripts/telegram-session-manager.sh attach <chat_id>    # Attach to tmux session
./scripts/telegram-session-manager.sh kill <chat_id>      # Kill and deregister
./scripts/telegram-session-manager.sh kill-all            # Kill all Telegram sessions
./scripts/telegram-session-manager.sh respawn-dead        # Respawn DOWN sessions
```

### Watchdog

```bash
./scripts/telegram-watchdog.sh --daemon    # Start in tmux: tg-watchdog
./scripts/telegram-watchdog.sh --stop      # Stop
./scripts/telegram-watchdog.sh --status    # Check if running
```

### Configuration

`~/.claude/telegram-sessions/config.env`:

```bash
# Required
TELEGRAM_ALLOWED_USER_ID="123456789"

# Optional (defaults shown)
TELEGRAM_SESSION_WORKDIR="$HOME"            # Default workdir for new sessions
TELEGRAM_WATCHDOG_INTERVAL=30               # Respawn check frequency (seconds)
```

## Boot Persistence (macOS)

Save to `~/Library/LaunchAgents/com.telegram-sessions.watchdog.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.telegram-sessions.watchdog</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/youruser</string>
    </dict>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/scripts/telegram-watchdog.sh</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/youruser/.claude/telegram-sessions/watchdog-launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/youruser/.claude/telegram-sessions/watchdog-launchd.log</string>
</dict>
</plist>
```

Replace paths with actual values, then:

```bash
launchctl load ~/Library/LaunchAgents/com.telegram-sessions.watchdog.plist
```

## Boot Persistence (Linux)

Save to `~/.config/systemd/user/telegram-watchdog.service`:

```ini
[Unit]
Description=Telegram Sessions Watchdog
After=network.target

[Service]
ExecStart=/path/to/scripts/telegram-watchdog.sh
Restart=always
Environment=HOME=/home/youruser

[Install]
WantedBy=default.target
```

Then:

```bash
systemctl --user enable telegram-watchdog
systemctl --user start telegram-watchdog
```

## Architecture

```
Telegram DM (user 123)   ->  tmux: tg-123456789   ->  Claude Code (workdir A)
Telegram Group (-100...)  ->  tmux: tg-1001234...  ->  Claude Code (workdir B)
                              tg-watchdog           ->  Respawns dead every 30s
```

## Differences from Discord Sessions

| Feature | Discord | Telegram |
|---------|---------|----------|
| Auto-discover channels | Yes (via Guild API) | No (no listing API) |
| Thread support | Yes (spawn-thread) | No (threads in same chat) |
| Watchdog discover cycle | Every 60s | None (respawn only) |
| Session prefix | `dc-` | `tg-` |
| Config key | `DISCORD_GUILD_ID` | Not needed |
| State dir env var | `DISCORD_STATE_DIR` | `TELEGRAM_STATE_DIR` |
| Channel plugin | `plugin:discord@claude-plugins-official` | `plugin:telegram@claude-plugins-official` |
