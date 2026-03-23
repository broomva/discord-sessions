---
name: discord-sessions
description: >
  Per-channel Discord sessions for Claude Code — each Discord channel or thread gets its
  own isolated Claude Code session via tmux, with per-channel access control, project-specific
  workdirs, and automatic CLAUDE.md chain loading. Includes a session manager (spawn, kill,
  discover, create-channel), a watchdog daemon (auto-respawn every 30s, auto-discover new
  channels/threads every 60s), thread context injection from parent channels, and launchd
  boot persistence. Use when: (1) setting up per-channel Discord sessions for Claude Code,
  (2) managing multiple Claude Code sessions across Discord channels, (3) auto-discovering
  new Discord channels or threads, (4) spawning thread sessions with parent conversation
  context, (5) keeping Discord agent sessions alive with a watchdog, (6) user says
  "discord sessions", "per-channel discord", "discord watchdog", "spawn discord session",
  "discord channel session", "discord thread session".
---

# Discord Sessions

Each Discord channel or thread maps to its own independent Claude Code session running
in a tmux pane. Discord messaging is handled natively by the MCP plugin inside each
session. A watchdog daemon keeps sessions alive and auto-discovers new channels/threads.

## Prerequisites

- Claude Code with `--channels` support (v2.1.80+)
- Discord bot configured: `/discord:configure <token>`
- tmux installed
- Discord bot invited to your server with permissions: View Channels, Send Messages,
  Read History, Attach Files, Add Reactions, Manage Channels, Create Threads

## Setup

### 1. Configure environment

Create `~/.claude/discord-sessions/config.env`:

```bash
# Required
DISCORD_ALLOWED_USER_ID="your-discord-user-id"
DISCORD_GUILD_ID="your-guild-server-id"

# Optional (defaults shown)
DISCORD_SESSION_WORKDIR="$HOME"          # Default workdir for new sessions
DISCORD_WATCHDOG_INTERVAL=30             # Respawn check frequency (seconds)
DISCORD_DISCOVER_INTERVAL=60             # Channel/thread discovery frequency (seconds)
```

Find your user ID: Discord Settings → Advanced → Enable Developer Mode → right-click your name → Copy User ID.
Find your guild ID: Right-click your server name → Copy Server ID.

### 2. Install scripts

Copy scripts to your project:

```bash
cp scripts/discord-session-manager.sh ~/your-project/scripts/
cp scripts/discord-watchdog.sh ~/your-project/scripts/
chmod +x ~/your-project/scripts/discord-session-manager.sh
chmod +x ~/your-project/scripts/discord-watchdog.sh
```

### 3. Start

```bash
# Discover all channels + threads and spawn sessions
./scripts/discord-session-manager.sh discover-all

# Start the watchdog (auto-respawn + auto-discover every 60s)
./scripts/discord-watchdog.sh --daemon
```

## Session Manager

Script: `scripts/discord-session-manager.sh`

### Spawn

```bash
# Channel session
./scripts/discord-session-manager.sh spawn <channel_id> --name <label> [--workdir <path>]

# Thread session (fetches last 20 parent messages as context)
./scripts/discord-session-manager.sh spawn-thread <thread_id> <parent_id> [--name <label>] [--workdir <path>]
```

Default workdir comes from `config.env`. Override per-session with `--workdir` to scope
a session to a specific project — it loads that project's CLAUDE.md chain automatically.

Each session gets:
- A tmux session `dc-<id>` running Claude Code with `--channels discord`
- A per-channel `DISCORD_STATE_DIR` with scoped `access.json`
- A registry entry in `sessions.json`

### Auto-Discovery

```bash
./scripts/discord-session-manager.sh discover           # new channels
./scripts/discord-session-manager.sh discover-threads    # new threads with parent context
./scripts/discord-session-manager.sh discover-all        # both
```

The watchdog runs `discover-all` every 60 seconds. Create a channel or thread on
Discord → a session spawns automatically.

### Create a Channel

```bash
./scripts/discord-session-manager.sh create-channel <name>
```

Creates the Discord channel via API AND spawns its session.

### Manage

```bash
./scripts/discord-session-manager.sh list           # UP/DOWN status
./scripts/discord-session-manager.sh status          # overview
./scripts/discord-session-manager.sh attach <id>     # attach to tmux session
./scripts/discord-session-manager.sh kill <id>       # kill and deregister
./scripts/discord-session-manager.sh kill-all        # kill everything
```

## Watchdog Daemon

Script: `scripts/discord-watchdog.sh`

```bash
./scripts/discord-watchdog.sh --daemon    # start in tmux: dc-watchdog
./scripts/discord-watchdog.sh --stop      # stop
./scripts/discord-watchdog.sh --status    # check if running
```

Every 30s: respawns dead sessions. Every 60s: discovers new channels and threads.

### Boot Persistence (macOS)

See [references/launchd.md](references/launchd.md) for a launchd plist template
that starts the watchdog on login.

## Thread Detection (In-Session)

When a session receives a message where `chat_id` differs from its assigned channel,
it is a thread message. The session should:

1. Check if a session exists: `./scripts/discord-session-manager.sh list`
2. If not, spawn one: `./scripts/discord-session-manager.sh spawn-thread <chat_id> <channel_id>`
3. Reply acknowledging the handoff

In practice, the watchdog handles this automatically via `discover-threads`.

## Architecture

```
Discord #general   →  tmux: dc-<a>  →  Claude Code (workdir A, CLAUDE.md chain A)
Discord #project-x →  tmux: dc-<b>  →  Claude Code (workdir B, CLAUDE.md chain B)
Thread: "design"   →  tmux: dc-<c>  →  Claude Code (parent context injected)
                      dc-watchdog    →  Respawns dead + discovers new every 60s
```
