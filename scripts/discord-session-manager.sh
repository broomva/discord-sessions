#!/usr/bin/env bash
# discord-session-manager.sh — Spawn and track per-channel Claude Code sessions
#
# Each Discord channel/thread gets its own tmux session running Claude Code
# with --channels discord. Discord I/O is handled entirely within Claude.

set -euo pipefail

DISCORD_MAIN_DIR="$HOME/.claude/channels/discord"
SESSIONS_DIR="$HOME/.claude/discord-sessions"
SESSIONS_REGISTRY="$SESSIONS_DIR/sessions.json"
SESSIONS_MD="$SESSIONS_DIR/SESSIONS.md"
CONFIG_FILE="$SESSIONS_DIR/config.env"
WORKDIR_MAP="$SESSIONS_DIR/workdir-map.json"
TMUX_PREFIX="dc"

# ── Load config ──────────────────────────────────────────────────────────

_load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    set -a; source "$CONFIG_FILE"; set +a
  fi
}
_load_config

ALLOWED_USER_ID="${DISCORD_ALLOWED_USER_ID:-}"
GUILD_ID="${DISCORD_GUILD_ID:-}"
WORKDIR_MAP="$SESSIONS_DIR/workdir-map.json"
WORKDIR="${DISCORD_SESSION_WORKDIR:-$HOME}"

_require_config() {
  if [[ -z "$ALLOWED_USER_ID" ]]; then
    echo "ERROR: DISCORD_ALLOWED_USER_ID not set. Add it to $CONFIG_FILE"
    exit 1
  fi
  if [[ -z "$GUILD_ID" ]]; then
    echo "ERROR: DISCORD_GUILD_ID not set. Add it to $CONFIG_FILE"
    exit 1
  fi
}

# ── Helpers ──────────────────────────────────────────────────────────────

_require_main_config() {
  if [[ ! -f "$DISCORD_MAIN_DIR/.env" ]]; then
    echo "ERROR: No Discord bot token at $DISCORD_MAIN_DIR/.env"
    echo "Run: /discord:configure <token> first"
    exit 1
  fi
}

_session_name() { echo "${TMUX_PREFIX}-${1}"; }
_state_dir()    { echo "${SESSIONS_DIR}/${1}"; }

_ensure_dirs() {
  mkdir -p "$SESSIONS_DIR"
  [[ -f "$SESSIONS_REGISTRY" ]] || echo '{}' > "$SESSIONS_REGISTRY"
}

_ensure_state_dir() {
  local id="$1"
  local dir
  dir="$(_state_dir "$id")"
  mkdir -p "$dir/approved" "$dir/inbox"

  [[ -L "$dir/.env" ]] || ln -sf "$DISCORD_MAIN_DIR/.env" "$dir/.env"

  cat > "$dir/access.json" <<EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["$ALLOWED_USER_ID"],
  "groups": {
    "$id": { "requireMention": false, "allowFrom": [] }
  },
  "pending": {}
}
EOF
}

_registry_set() {
  local id="$1" type="$2" name="$3" parent="${4:-}"
  _ensure_dirs
  python3 -c "
import json, datetime
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
reg['$id'] = {
    'type': '$type',
    'name': '$name',
    'tmux': '$(echo $(_session_name $id))',
    'parent': '$parent' or None,
    'created': datetime.datetime.now().isoformat(timespec='seconds')
}
with open('$SESSIONS_REGISTRY', 'w') as f: json.dump(reg, f, indent=2)
"
  _rebuild_md
}

_registry_remove() {
  local id="$1"
  python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
reg.pop('$id', None)
with open('$SESSIONS_REGISTRY', 'w') as f: json.dump(reg, f, indent=2)
"
  _rebuild_md
}

_rebuild_md() {
  python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
lines = ['# Active Discord Sessions\n']
lines.append('| Channel/Thread ID | Type | tmux Session | Name | Parent | Created |')
lines.append('|---|---|---|---|---|---|')
for cid, info in sorted(reg.items(), key=lambda x: x[1].get('created','')):
    lines.append(f'| {cid} | {info[\"type\"]} | \`{info[\"tmux\"]}\` | {info[\"name\"]} | {info.get(\"parent\") or \"-\"} | {info[\"created\"]} |')
lines.append('')
with open('$SESSIONS_MD', 'w') as f: f.write('\n'.join(lines))
"
}

_is_alive() { tmux has-session -t "$(_session_name "$1")" 2>/dev/null; }

_resolve_workdir() {
  local name="$1"
  if [[ -z "$name" || ! -f "$WORKDIR_MAP" ]]; then
    echo "$WORKDIR"
    return
  fi
  local mapped
  mapped=$(python3 -c "
import json, sys, os
try:
    with open('$WORKDIR_MAP') as f:
        m = json.load(f)
    path = m.get('$name', '')
    if path:
        print(os.path.expandvars(path))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null) || mapped=""
  if [[ -n "$mapped" ]]; then
    echo "$mapped"
  else
    echo "$WORKDIR"
  fi
}

# UUID v5 namespace for discord-sessions (fixed, generated once)
_UUID_NAMESPACE="a1b2c3d4-e5f6-4789-abcd-ef0123456789"

_generate_session_id() {
  local channel_id="$1"
  python3 -c "
import uuid
ns = uuid.UUID('$_UUID_NAMESPACE')
print(uuid.uuid5(ns, '$channel_id'))
"
}

_persist_session_id() {
  local id="$1" session_uuid="$2"
  local dir
  dir="$(_state_dir "$id")"
  printf '%s' "$session_uuid" > "$dir/.session-id"
}

_read_session_id() {
  local id="$1"
  local f
  f="$(_state_dir "$id")/.session-id"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

_read_bot_token() {
  sed -n 's/^DISCORD_BOT_TOKEN=//p' "$DISCORD_MAIN_DIR/.env"
}

_fetch_channel_messages() {
  local channel_id="$1" limit="${2:-20}"
  local token
  token="$(_read_bot_token)"
  curl -sS -H "Authorization: Bot $token" \
    "https://discord.com/api/v10/channels/${channel_id}/messages?limit=${limit}" \
  | python3 -c "
import json, sys
msgs = json.load(sys.stdin)
if isinstance(msgs, dict) and 'message' in msgs:
    print(f'ERROR: {msgs[\"message\"]}', file=sys.stderr); sys.exit(1)
for m in reversed(msgs):
    print(f'[{m[\"timestamp\"][:19]}] {m[\"author\"][\"username\"]}: {m[\"content\"]}')
"
}

_spawn_tmux() {
  local id="$1" name="$2" system_prompt="${3:-}" workdir="${4:-$WORKDIR}" session_uuid="${5:-}"
  local session_name state_dir claude_cmd
  session_name="$(_session_name "$id")"
  state_dir="$(_state_dir "$id")"

  # Generate a deterministic session ID if none provided
  if [[ -z "$session_uuid" ]]; then
    session_uuid="$(_read_session_id "$id")"
  fi
  if [[ -z "$session_uuid" ]]; then
    session_uuid="$(_generate_session_id "$id")"
  fi

  # Persist the session ID so respawns can resume the conversation
  _persist_session_id "$id" "$session_uuid"

  claude_cmd="DISCORD_STATE_DIR='$state_dir' claude"
  claude_cmd+=" --channels plugin:discord@claude-plugins-official"
  claude_cmd+=" --dangerously-skip-permissions"
  claude_cmd+=" --session-id '${session_uuid}'"
  claude_cmd+=" --name '${name}'"

  if [[ -n "$system_prompt" ]]; then
    local pf="$state_dir/.system-prompt"
    printf '%s' "$system_prompt" > "$pf"
    claude_cmd+=" --system-prompt \"\$(cat '$pf')\""
  fi

  echo "$workdir" > "$state_dir/.workdir"

  tmux new-session -d -s "$session_name" -c "$workdir" "bash -c '${claude_cmd}'"
  echo "$session_name"
}

# ── Commands ─────────────────────────────────────────────────────────────

cmd_spawn() {
  local channel_id="" label="" system_prompt="" workdir="" fresh=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)          label="$2"; shift 2 ;;
      --system-prompt) system_prompt="$2"; shift 2 ;;
      --workdir)       workdir="$2"; shift 2 ;;
      --fresh)         fresh=true; shift ;;
      *)               channel_id="$1"; shift ;;
    esac
  done
  [[ -n "$channel_id" ]] || { echo "Usage: spawn <channel_id> [--name <label>] [--workdir <path>] [--fresh]"; exit 1; }

  _require_main_config
  _require_config
  _ensure_dirs

  if _is_alive "$channel_id"; then
    echo "ALIVE  $(_session_name "$channel_id")"
    return 0
  fi

  local name="${label:-ch-${channel_id: -6}}"
  _ensure_state_dir "$channel_id"

  # --fresh: generate a new UUID to start a clean conversation
  local session_uuid=""
  if $fresh; then
    session_uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    echo "FRESH  new session-id=$session_uuid"
  fi

  _spawn_tmux "$channel_id" "$name" "$system_prompt" "$workdir" "$session_uuid"
  _registry_set "$channel_id" "channel" "$name"

  echo "SPAWNED  $(_session_name "$channel_id")  name=$name  workdir=${workdir:-$WORKDIR}"
}

cmd_spawn_thread() {
  local thread_id="" parent_id="" limit=20 label="" workdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)   limit="$2"; shift 2 ;;
      --name)    label="$2"; shift 2 ;;
      --workdir) workdir="$2"; shift 2 ;;
      *)
        if [[ -z "$thread_id" ]]; then thread_id="$1"
        elif [[ -z "$parent_id" ]]; then parent_id="$1"
        fi; shift ;;
    esac
  done
  [[ -n "$thread_id" && -n "$parent_id" ]] || { echo "Usage: spawn-thread <thread_id> <parent_channel_id> [--limit <n>] [--workdir <path>]"; exit 1; }

  _require_main_config
  _require_config
  _ensure_dirs

  if _is_alive "$thread_id"; then
    echo "ALIVE  $(_session_name "$thread_id")"
    return 0
  fi

  local context
  context="$(_fetch_channel_messages "$parent_id" "$limit" 2>/dev/null)" || context=""

  local prompt="You are continuing a conversation from Discord channel $parent_id.
Prior context from the parent channel:
---
${context:-"(could not fetch parent messages)"}
---
You are now responding in thread $thread_id. Continue naturally."

  local name="${label:-th-${thread_id: -6}}"
  _ensure_state_dir "$thread_id"

  python3 -c "
import json
p = '$(_state_dir "$thread_id")/access.json'
with open(p) as f: cfg = json.load(f)
cfg['groups']['$parent_id'] = {'requireMention': False, 'allowFrom': []}
with open(p, 'w') as f: json.dump(cfg, f, indent=2)
"

  # Inherit workdir from parent channel session if not explicitly set
  if [[ -z "$workdir" ]]; then
    local parent_wd_file
    parent_wd_file="$(_state_dir "$parent_id")/.workdir"
    if [[ -f "$parent_wd_file" ]]; then
      workdir="$(cat "$parent_wd_file")"
    fi
  fi

  _spawn_tmux "$thread_id" "$name" "$prompt" "$workdir" ""
  _registry_set "$thread_id" "thread" "$name" "$parent_id"

  echo "SPAWNED  $(_session_name "$thread_id")  name=$name  parent=$parent_id  workdir=${workdir:-$WORKDIR}"
}

cmd_list() {
  _ensure_dirs
  echo "Discord Sessions:"
  python3 -c "
import json, subprocess
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
if not reg: print('  (none)'); exit()
for cid, info in sorted(reg.items(), key=lambda x: x[1].get('created','')):
    alive = subprocess.run(['tmux', 'has-session', '-t', info['tmux']], capture_output=True).returncode == 0
    status = 'UP' if alive else 'DOWN'
    parent = f'  parent={info[\"parent\"]}' if info.get('parent') else ''
    print(f'  [{status:4}]  {info[\"tmux\"]:30}  {info[\"type\"]:7}  {info[\"name\"]}{parent}')
"
}

cmd_attach() {
  local id="${1:?Usage: attach <channel_id>}"
  _is_alive "$id" || { echo "Session not running: $(_session_name "$id")"; exit 1; }
  tmux attach -t "$(_session_name "$id")"
}

cmd_kill() {
  local id="${1:?Usage: kill <channel_id>}"
  local sn
  sn="$(_session_name "$id")"
  if _is_alive "$id"; then
    tmux kill-session -t "$sn"
    echo "KILLED  $sn"
  fi
  _registry_remove "$id"
}

cmd_kill_all() {
  _ensure_dirs
  local killed=0
  for sn in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${TMUX_PREFIX}-" || true); do
    tmux kill-session -t "$sn"; echo "KILLED  $sn"; killed=$((killed + 1))
  done
  echo '{}' > "$SESSIONS_REGISTRY"
  _rebuild_md
  echo "Total: $killed"
}

cmd_respawn_dead() {
  _ensure_dirs
  python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
for cid, info in reg.items():
    print(f'{cid} {info[\"type\"]} {info[\"name\"]} {info.get(\"parent\") or \"-\"}')
" | while IFS=' ' read -r cid type name parent; do
    if ! _is_alive "$cid"; then
      # Skip suspended sessions
      if [[ -f "$(_state_dir "$cid")/.suspended" ]]; then
        continue
      fi
      echo "RESPAWNING $(_session_name "$cid") ($type: $name)"
      _ensure_state_dir "$cid"
      local wd=""
      [[ -f "$(_state_dir "$cid")/.workdir" ]] && wd="$(cat "$(_state_dir "$cid")/.workdir")"

      # Read the persisted session ID so the respawned session resumes the conversation
      local session_uuid=""
      session_uuid="$(_read_session_id "$cid")"

      if [[ "$type" == "thread" && "$parent" != "-" ]]; then
        local pf="$(_state_dir "$cid")/.system-prompt"
        local sp=""
        [[ -f "$pf" ]] && sp="$(cat "$pf")"
        _spawn_tmux "$cid" "$name" "$sp" "$wd" "$session_uuid"
      else
        _spawn_tmux "$cid" "$name" "" "$wd" "$session_uuid"
      fi
    fi
  done
}

cmd_suspend_idle() {
  # Kill sessions that have been idle (no tmux activity) beyond the threshold
  local idle_minutes="${DISCORD_IDLE_TIMEOUT:-30}"
  local idle_seconds=$((idle_minutes * 60))
  _ensure_dirs

  local suspended=0
  local now
  now=$(date +%s)

  python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
for cid, info in reg.items():
    print(f'{cid} {info[\"name\"]}')
" | while IFS=' ' read -r cid name; do
    if _is_alive "$cid"; then
      local sn
      sn="$(_session_name "$cid")"
      # Get tmux pane last activity timestamp
      local last_activity
      last_activity=$(tmux display-message -t "$sn" -p '#{pane_last_activity}' 2>/dev/null || echo "$now")
      local idle_for=$((now - last_activity))

      if (( idle_for > idle_seconds )); then
        local idle_min=$((idle_for / 60))
        echo "  SUSPEND  ${name} (idle ${idle_min}m)"
        tmux kill-session -t "$sn" 2>/dev/null || true
        # Mark as suspended so respawn-dead skips it
        echo "$now" > "$(_state_dir "$cid")/.suspended"
        suspended=$((suspended + 1))
      fi
    fi
  done
  echo "Suspended $suspended sessions (threshold: ${idle_minutes}m)"
}

cmd_wake() {
  # Wake a specific suspended session
  local id="${1:?Usage: wake <channel_id>}"
  local suspend_file
  suspend_file="$(_state_dir "$id")/.suspended"
  [[ -f "$suspend_file" ]] && rm -f "$suspend_file"

  if ! _is_alive "$id"; then
    # Trigger respawn
    local name="" wd="" session_uuid=""
    name=$(python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
print(reg.get('$id', {}).get('name', 'unknown'))
" 2>/dev/null)
    [[ -f "$(_state_dir "$id")/.workdir" ]] && wd="$(cat "$(_state_dir "$id")/.workdir")"
    session_uuid="$(_read_session_id "$id")"
    _ensure_state_dir "$id"
    _spawn_tmux "$id" "$name" "" "$wd" "$session_uuid"
    echo "WOKE  $(_session_name "$id")  name=$name"
  else
    echo "ALIVE  $(_session_name "$id") (not suspended)"
  fi
}

cmd_wake_all() {
  _ensure_dirs
  local woke=0
  for sf in "$SESSIONS_DIR"/*/.suspended; do
    [[ -f "$sf" ]] || continue
    local cid
    cid=$(basename "$(dirname "$sf")")
    rm -f "$sf"
    woke=$((woke + 1))
  done
  echo "Cleared $woke suspend flags. Run respawn-dead to bring them back."
  cmd_respawn_dead
}

cmd_cleanup_stale() {
  _require_main_config
  _ensure_dirs
  local token
  token="$(_read_bot_token)"

  local cleaned=0 checked=0

  # Build list of registered channel IDs first, then check each
  local ids
  ids=$(python3 -c "
import json
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
for cid, info in reg.items():
    print(f'{cid} {info[\"type\"]} {info[\"name\"]}')
")

  if [[ -z "$ids" ]]; then
    echo "No registered sessions to check."
    return 0
  fi

  while IFS=' ' read -r cid type name; do
    checked=$((checked + 1))
    local response http_code body
    response=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bot $token" \
      "https://discord.com/api/v10/channels/${cid}" 2>/dev/null) || true
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    local stale=false reason=""
    if [[ "$http_code" == "404" ]]; then
      stale=true
      reason="channel deleted (404)"
    elif echo "$body" | python3 -c "
import json, sys
try:
    ch = json.load(sys.stdin)
    md = ch.get('thread_metadata', {})
    if md.get('archived', False):
        sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null; then
      stale=true
      reason="thread archived"
    fi

    if [[ "$stale" == "true" ]]; then
      echo "  STALE   ${name} (${cid}) — ${reason}"
      local sn
      sn="$(_session_name "$cid")"
      if _is_alive "$cid"; then
        tmux kill-session -t "$sn" 2>/dev/null || true
        echo "          killed tmux session $sn"
      fi
      _registry_remove "$cid"
      cleaned=$((cleaned + 1))
    else
      echo "  OK      ${name} (${cid})"
    fi
  done <<< "$ids"

  echo ""
  echo "Checked $checked sessions, cleaned $cleaned stale"
}

cmd_discover() {
  _require_main_config
  _require_config
  _ensure_dirs
  local token
  token="$(_read_bot_token)"

  local manager_path="$0"
  curl -sS -H "Authorization: Bot $token" \
    "https://discord.com/api/v10/guilds/${GUILD_ID}/channels" \
  | REGISTRY="$SESSIONS_REGISTRY" MANAGER="$manager_path" WORKDIR_MAP_FILE="$WORKDIR_MAP" DEFAULT_WORKDIR="$WORKDIR" python3 -c "
import json, subprocess, sys, os

channels = json.load(sys.stdin)
registry = os.environ['REGISTRY']
manager = os.environ['MANAGER']
workdir_map_file = os.environ['WORKDIR_MAP_FILE']
default_workdir = os.environ['DEFAULT_WORKDIR']

# Load workdir map (graceful fallback if missing or invalid)
workdir_map = {}
try:
    with open(workdir_map_file) as f:
        workdir_map = json.load(f)
except Exception:
    pass

def resolve_workdir(name):
    path = workdir_map.get(name, '')
    if path:
        return os.path.expandvars(path)
    return default_workdir

with open(registry) as f:
    reg = json.load(f)

text_channels = [c for c in channels if c['type'] in (0, 5)]
new_count = 0

for ch in sorted(text_channels, key=lambda c: c.get('position', 0)):
    cid = ch['id']
    name = ch['name']
    if cid in reg:
        print(f'  EXISTS  {name:25} ({cid})')
    else:
        wd = resolve_workdir(name)
        wd_note = f'  workdir={wd}' if wd != default_workdir else ''
        print(f'  NEW     {name:25} ({cid}) — spawning...{wd_note}')
        cmd = [manager, 'spawn', cid, '--name', name]
        if wd != default_workdir:
            cmd += ['--workdir', wd]
        subprocess.run(cmd, check=True)
        new_count += 1

print(f'\nDiscovered {len(text_channels)} channels, spawned {new_count} new sessions')
"
}

cmd_discover_threads() {
  _require_main_config
  _require_config
  _ensure_dirs
  local token
  token="$(_read_bot_token)"

  curl -sS -H "Authorization: Bot $token" \
    "https://discord.com/api/v10/guilds/${GUILD_ID}/threads/active" \
  | REGISTRY="$SESSIONS_REGISTRY" MANAGER="$0" WORKDIR_MAP_FILE="$WORKDIR_MAP" DEFAULT_WORKDIR="$WORKDIR" python3 -c "
import json, subprocess, sys, os

data = json.load(sys.stdin)
threads = data.get('threads', [])
registry = os.environ['REGISTRY']
manager = os.environ['MANAGER']
workdir_map_file = os.environ['WORKDIR_MAP_FILE']
default_workdir = os.environ['DEFAULT_WORKDIR']

# Load workdir map (graceful fallback if missing or invalid)
workdir_map = {}
try:
    with open(workdir_map_file) as f:
        workdir_map = json.load(f)
except Exception:
    pass

def resolve_workdir(name):
    path = workdir_map.get(name, '')
    if path:
        return os.path.expandvars(path)
    return default_workdir

with open(registry) as f:
    reg = json.load(f)

new_count = 0
for t in sorted(threads, key=lambda x: x.get('name', '')):
    tid = t['id']
    name = t['name'][:30]
    parent = t['parent_id']
    if tid in reg:
        print(f'  EXISTS  {name:30} ({tid})  parent={parent}')
    else:
        wd = resolve_workdir(name)
        wd_note = f'  workdir={wd}' if wd != default_workdir else ''
        print(f'  NEW     {name:30} ({tid})  parent={parent} — spawning...{wd_note}')
        cmd = [manager, 'spawn-thread', tid, parent, '--name', name]
        if wd != default_workdir:
            cmd += ['--workdir', wd]
        subprocess.run(cmd, check=True)
        new_count += 1

print(f'\nDiscovered {len(threads)} active threads, spawned {new_count} new sessions')
"
}

_update_workdir_map() {
  # Add or update a channel name → workdir entry in workdir-map.json
  local name="$1" workdir="$2"
  [[ -z "$name" || -z "$workdir" ]] && return 0
  python3 -c "
import json, os
path = '$WORKDIR_MAP'
try:
    with open(path) as f: m = json.load(f)
except Exception:
    m = {}
m['$name'] = '$workdir'
with open(path, 'w') as f: json.dump(m, f, indent=2)
" 2>/dev/null || true
}

cmd_create_channel() {
  local name="" workdir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --workdir) workdir="$2"; shift 2 ;;
      *)         name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || { echo "Usage: create-channel <name> [--workdir <path>]"; exit 1; }

  _require_main_config
  _require_config
  local token
  token="$(_read_bot_token)"

  local result
  result=$(curl -sS -X POST \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\", \"type\": 0}" \
    "https://discord.com/api/v10/guilds/${GUILD_ID}/channels" \
  | python3 -c "import json,sys; ch=json.load(sys.stdin); print(f'{ch[\"id\"]} {ch[\"name\"]}')")

  local channel_id channel_name
  channel_id="${result%% *}"
  channel_name="${result#* }"

  # Update workdir map if workdir specified
  if [[ -n "$workdir" ]]; then
    _update_workdir_map "$channel_name" "$workdir"
    echo "CREATED  #$channel_name ($channel_id)  workdir=$workdir"
    cmd_spawn "$channel_id" --name "$channel_name" --workdir "$workdir"
  else
    local resolved
    resolved="$(_resolve_workdir "$channel_name")"
    echo "CREATED  #$channel_name ($channel_id)  workdir=$resolved"
    cmd_spawn "$channel_id" --name "$channel_name" --workdir "$resolved"
  fi
}

_count_active_sessions() {
  _ensure_dirs
  python3 -c "
import json, subprocess
with open('$SESSIONS_REGISTRY') as f: reg = json.load(f)
count = sum(1 for info in reg.values()
  if subprocess.run(['tmux', 'has-session', '-t', info['tmux']], capture_output=True).returncode == 0)
print(count)
"
}

cmd_motd() {
  local up
  up="$(_count_active_sessions)"
  local total
  total=$(python3 -c "import json; print(len(json.load(open('$SESSIONS_REGISTRY'))))" 2>/dev/null || echo 0)
  echo "$up/$total sessions active | watchdog: $(./scripts/discord-watchdog.sh --status 2>/dev/null | head -1)"
}

cmd_set_channel_topic() {
  local STATUS_CHANNEL_ID="${DISCORD_STATUS_CHANNEL_ID:-}"
  [[ -z "$STATUS_CHANNEL_ID" ]] && return 0

  _require_main_config
  local token
  token="$(_read_bot_token)"
  local topic
  topic="$(cmd_motd)"

  local escaped_topic
  escaped_topic=$(python3 -c "import json,sys; print(json.dumps('$topic'))")

  curl -sS -X PATCH \
    -H "Authorization: Bot $token" \
    -H "Content-Type: application/json" \
    -d "{\"topic\": $escaped_topic}" \
    "https://discord.com/api/v10/channels/${STATUS_CHANNEL_ID}" > /dev/null 2>&1 || true
}

cmd_status() {
  echo "Discord Session Manager"
  echo "═══════════════════════"
  [[ -f "$DISCORD_MAIN_DIR/.env" ]] && echo "Bot token: configured" || echo "Bot token: MISSING"
  [[ -n "$GUILD_ID" ]] && echo "Guild: $GUILD_ID" || echo "Guild: NOT SET"
  echo "Sessions dir: $SESSIONS_DIR"
  echo ""
  cmd_list
}

cmd_init() {
  # Interactive setup
  _ensure_dirs
  echo "Discord Sessions — Setup"
  echo "========================"
  echo ""

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "Config exists at $CONFIG_FILE"
    cat "$CONFIG_FILE"
    echo ""
    read -p "Overwrite? [y/N] " -r
    [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Kept existing config."; return 0; }
  fi

  read -p "Your Discord user ID: " uid
  read -p "Your Discord guild (server) ID: " gid
  read -p "Default workdir [$HOME]: " wd
  wd="${wd:-$HOME}"

  cat > "$CONFIG_FILE" <<EOF
DISCORD_ALLOWED_USER_ID="$uid"
DISCORD_GUILD_ID="$gid"
DISCORD_SESSION_WORKDIR="$wd"
EOF

  echo ""
  echo "Config saved to $CONFIG_FILE"
  echo "Next: ./scripts/discord-session-manager.sh discover-all"
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-help}" in
  spawn)             shift; cmd_spawn "$@" ;;
  spawn-thread)      shift; cmd_spawn_thread "$@" ;;
  discover)          cmd_discover ;;
  discover-threads)  cmd_discover_threads ;;
  discover-all)      cmd_discover; echo ""; cmd_discover_threads ;;
  cleanup-stale)     cmd_cleanup_stale ;;
  suspend-idle)      cmd_suspend_idle ;;
  wake)              shift; cmd_wake "$@" ;;
  wake-all)          cmd_wake_all ;;
  create-channel)    shift; cmd_create_channel "$@" ;;
  motd)              cmd_motd ;;
  set-status)        cmd_set_channel_topic ;;
  init)              cmd_init ;;
  list)              cmd_list ;;
  attach)            shift; cmd_attach "$@" ;;
  kill)              shift; cmd_kill "$@" ;;
  kill-all)          cmd_kill_all ;;
  respawn-dead)      cmd_respawn_dead ;;
  status)            cmd_status ;;
  help|--help|-h)
    cat <<'HELP'
Discord Session Manager — per-channel Claude Code sessions via tmux

  init                Setup — configure user ID, guild ID, workdir
  spawn <channel_id> [--name <label>] [--workdir <path>] [--system-prompt <text>] [--fresh]
  spawn-thread <thread_id> <parent_channel_id> [--limit <n>] [--name <label>] [--workdir <path>]
  discover            Auto-detect guild channels and spawn sessions
  discover-threads    Auto-detect active threads and spawn sessions
  discover-all        Both channels + threads
  cleanup-stale       Kill sessions for deleted channels or archived threads
  suspend-idle        Suspend sessions idle beyond DISCORD_IDLE_TIMEOUT (default: 30m)
  wake <id>           Wake a suspended session
  wake-all            Wake all suspended sessions
  create-channel <name> [--workdir <path>]  Create a Discord channel + spawn its session
  motd                Show active session count and watchdog status
  set-status          Update the status channel topic with session count
  list                List sessions with UP/DOWN status
  attach <id>         Attach to a tmux session
  kill <id>           Kill and deregister a session
  kill-all            Kill all Discord sessions
  respawn-dead        Respawn any DOWN sessions (used by watchdog)
  status              Overview

Channel-to-workdir mapping:
  Create ~/.claude/discord-sessions/workdir-map.json to map channel names
  to project directories. discover and discover-threads will use the mapped
  workdir when spawning new sessions. Example:
    { "general": "$HOME/myproject", "health-os": "$HOME/apps/healthOS" }

Flags:
  --fresh             (spawn only) Start a fresh conversation — generates a new
                      session ID instead of resuming the previous one
HELP
    ;;
  *) echo "Unknown: $1 (try --help)"; exit 1 ;;
esac
