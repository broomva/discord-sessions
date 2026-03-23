#!/usr/bin/env bun
/**
 * discord-slash-daemon.ts — Discord slash command daemon for Claude Remote Sessions
 *
 * A single Bun process that registers and handles slash commands, bridging them
 * to the tmux-managed Claude Code sessions via discord-session-manager.sh.
 *
 * Startup:
 *   bun scripts/discord-slash-daemon.ts
 *
 * Or via watchdog (auto-managed in dc-slash-daemon tmux session).
 */

import {
  Client,
  GatewayIntentBits,
  REST,
  Routes,
  EmbedBuilder,
  InteractionType,
  ApplicationCommandType,
  ApplicationCommandOptionType,
  type ChatInputCommandInteraction,
  type AutocompleteInteraction,
} from "discord.js";
import { readFileSync, existsSync, readdirSync, statSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { $ } from "bun";

// ── Config ────────────────────────────────────────────────────────────────

const DISCORD_ENV_PATH = join(homedir(), ".claude/channels/discord/.env");
const CONFIG_ENV_PATH = join(homedir(), ".claude/discord-sessions/config.env");
const SESSIONS_DIR = join(homedir(), ".claude/discord-sessions");
const SESSIONS_REGISTRY = join(SESSIONS_DIR, "sessions.json");
const WORKDIR_MAP_PATH = join(SESSIONS_DIR, "workdir-map.json");
const MANAGER_PATH = join(import.meta.dir, "discord-session-manager.sh");

function readEnvValue(filePath: string, key: string): string {
  if (!existsSync(filePath)) return "";
  const content = readFileSync(filePath, "utf8");
  const match = content.match(new RegExp(`^${key}=["']?(.+?)["']?$`, "m"));
  return match?.[1] ?? "";
}

const BOT_TOKEN = readEnvValue(DISCORD_ENV_PATH, "DISCORD_BOT_TOKEN");
if (!BOT_TOKEN) {
  console.error(
    `[slash-daemon] FATAL: No DISCORD_BOT_TOKEN found in ${DISCORD_ENV_PATH}`
  );
  console.error("Run: /discord:configure <token> first");
  process.exit(1);
}

const GUILD_ID = readEnvValue(CONFIG_ENV_PATH, "DISCORD_GUILD_ID");
if (!GUILD_ID) {
  console.error(
    `[slash-daemon] FATAL: No DISCORD_GUILD_ID found in ${CONFIG_ENV_PATH}`
  );
  process.exit(1);
}

// ── Helpers ───────────────────────────────────────────────────────────────

function readSessionsRegistry(): Record<
  string,
  {
    type: string;
    name: string;
    tmux: string;
    parent: string | null;
    created: string;
  }
> {
  try {
    if (!existsSync(SESSIONS_REGISTRY)) return {};
    return JSON.parse(readFileSync(SESSIONS_REGISTRY, "utf8"));
  } catch {
    return {};
  }
}

function readWorkdirMap(): Record<string, string> {
  try {
    if (!existsSync(WORKDIR_MAP_PATH)) return {};
    return JSON.parse(readFileSync(WORKDIR_MAP_PATH, "utf8"));
  } catch {
    return {};
  }
}

function findSessionByChannel(
  channelId: string
): {
  id: string;
  type: string;
  name: string;
  tmux: string;
  parent: string | null;
  created: string;
} | null {
  const registry = readSessionsRegistry();
  if (registry[channelId]) {
    return { id: channelId, ...registry[channelId] };
  }
  return null;
}

async function isTmuxAlive(sessionName: string): Promise<boolean> {
  try {
    const result = await $`tmux has-session -t ${sessionName} 2>/dev/null`.nothrow().quiet();
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

async function readWorkdir(channelId: string): Promise<string> {
  const wdFile = join(SESSIONS_DIR, channelId, ".workdir");
  try {
    if (existsSync(wdFile)) return readFileSync(wdFile, "utf8").trim();
  } catch {}
  return "(unknown)";
}

async function readSessionId(channelId: string): Promise<string> {
  const sidFile = join(SESSIONS_DIR, channelId, ".session-id");
  try {
    if (existsSync(sidFile)) return readFileSync(sidFile, "utf8").trim();
  } catch {}
  return "(none)";
}

async function runManager(...args: string[]): Promise<string> {
  try {
    const result = await $`bash ${MANAGER_PATH} ${args}`.text();
    return result.trim();
  } catch (e: any) {
    return e?.stdout?.toString()?.trim() || e?.message || "Command failed";
  }
}

function escapeForTmux(input: string): string {
  // Escape single quotes and newlines for tmux send-keys
  return input
    .replace(/'/g, "'\\''")
    .replace(/\n/g, " ")
    .replace(/\r/g, "");
}

function formatUptime(createdIso: string): string {
  try {
    const created = new Date(createdIso);
    const now = new Date();
    const diffMs = now.getTime() - created.getTime();
    const hours = Math.floor(diffMs / 3600000);
    const minutes = Math.floor((diffMs % 3600000) / 60000);
    if (hours > 24) {
      const days = Math.floor(hours / 24);
      return `${days}d ${hours % 24}h`;
    }
    return `${hours}h ${minutes}m`;
  } catch {
    return "unknown";
  }
}

// ── Slash Command Definitions ─────────────────────────────────────────────

const SLASH_COMMANDS = [
  {
    name: "session",
    description: "Manage the Claude Code session for this channel",
    type: ApplicationCommandType.ChatInput,
    options: [
      {
        name: "status",
        description: "Show session info (workdir, uptime, name) for this channel",
        type: ApplicationCommandOptionType.Subcommand,
      },
      {
        name: "restart",
        description: "Kill and respawn the session",
        type: ApplicationCommandOptionType.Subcommand,
        options: [
          {
            name: "fresh",
            description: "Start a clean conversation (new session ID)",
            type: ApplicationCommandOptionType.Boolean,
            required: false,
          },
        ],
      },
      {
        name: "refresh",
        description:
          "Kill and respawn with same session-id (picks up new skills/CLAUDE.md)",
        type: ApplicationCommandOptionType.Subcommand,
      },
      {
        name: "kill",
        description: "Kill the session",
        type: ApplicationCommandOptionType.Subcommand,
      },
      {
        name: "wake",
        description: "Wake a suspended session",
        type: ApplicationCommandOptionType.Subcommand,
      },
      {
        name: "workdir",
        description: "Show or change the session's working directory",
        type: ApplicationCommandOptionType.Subcommand,
        options: [
          {
            name: "path",
            description: "New working directory (leave empty to show current)",
            type: ApplicationCommandOptionType.String,
            required: false,
            autocomplete: true,
          },
        ],
      },
    ],
  },
  {
    name: "skills",
    description: "Manage skills for this channel's Claude session",
    type: ApplicationCommandType.ChatInput,
    options: [
      {
        name: "list",
        description: "List installed skills for this channel's session",
        type: ApplicationCommandOptionType.Subcommand,
      },
      {
        name: "install",
        description: "Install a skill (runs npx skills add in the session)",
        type: ApplicationCommandOptionType.Subcommand,
        options: [
          {
            name: "name",
            description: "Skill name to install",
            type: ApplicationCommandOptionType.String,
            required: true,
          },
        ],
      },
    ],
  },
  {
    name: "discover",
    description: "Trigger channel/thread discovery",
    type: ApplicationCommandType.ChatInput,
  },
  {
    name: "ask",
    description: "Send a prompt to the channel's Claude session",
    type: ApplicationCommandType.ChatInput,
    options: [
      {
        name: "prompt",
        description: "The prompt to send",
        type: ApplicationCommandOptionType.String,
        required: true,
      },
    ],
  },
];

// ── Command Handlers ──────────────────────────────────────────────────────

async function handleSessionStatus(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);

  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const alive = await isTmuxAlive(session.tmux);
  const workdir = await readWorkdir(channelId);
  const sessionId = await readSessionId(channelId);
  const uptime = formatUptime(session.created);
  const isSuspended = existsSync(
    join(SESSIONS_DIR, channelId, ".suspended")
  );

  let status = alive ? "UP" : "DOWN";
  if (isSuspended) status = "SUSPENDED";

  const embed = new EmbedBuilder()
    .setTitle(`Session: ${session.name}`)
    .setColor(alive ? 0x00ff00 : isSuspended ? 0xffaa00 : 0xff0000)
    .addFields(
      { name: "Status", value: status, inline: true },
      { name: "Type", value: session.type, inline: true },
      { name: "Uptime", value: uptime, inline: true },
      { name: "tmux", value: `\`${session.tmux}\``, inline: true },
      { name: "Session ID", value: `\`${sessionId.slice(0, 8)}...\``, inline: true },
      { name: "Workdir", value: `\`${workdir}\``, inline: false }
    );

  if (session.parent) {
    embed.addFields({
      name: "Parent",
      value: `<#${session.parent}>`,
      inline: true,
    });
  }

  // Return the embed as a serialized instruction — we'll handle this specially
  return JSON.stringify({ embed: embed.toJSON() });
}

async function handleSessionRestart(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const fresh = interaction.options.getBoolean("fresh") ?? false;

  // Kill existing session
  await runManager("kill", channelId);

  // Respawn
  const args = ["spawn", channelId, "--name", session.name];
  if (fresh) args.push("--fresh");

  const workdir = await readWorkdir(channelId);
  if (workdir && workdir !== "(unknown)") {
    args.push("--workdir", workdir);
  }

  const output = await runManager(...args);
  const freshNote = fresh ? " (fresh conversation)" : " (resumed conversation)";
  return `Session restarted${freshNote}\n\`\`\`\n${output}\n\`\`\``;
}

async function handleSessionRefresh(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  // Kill and respawn with the same session-id (no --fresh)
  await runManager("kill", channelId);

  const args = ["spawn", channelId, "--name", session.name];
  const workdir = await readWorkdir(channelId);
  if (workdir && workdir !== "(unknown)") {
    args.push("--workdir", workdir);
  }

  const output = await runManager(...args);
  return `Session refreshed (same session-id, picks up new skills/CLAUDE.md)\n\`\`\`\n${output}\n\`\`\``;
}

async function handleSessionKill(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel.";
  }

  const output = await runManager("kill", channelId);
  return `Session killed.\n\`\`\`\n${output}\n\`\`\``;
}

async function handleSessionWake(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const output = await runManager("wake", channelId);
  return `\`\`\`\n${output}\n\`\`\``;
}

async function handleSessionWorkdir(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const newPath = interaction.options.getString("path");

  if (!newPath) {
    // Show current workdir
    const workdir = await readWorkdir(channelId);
    return `Current workdir: \`${workdir}\``;
  }

  // Change workdir: kill + respawn with new workdir
  await runManager("kill", channelId);
  const output = await runManager(
    "spawn",
    channelId,
    "--name",
    session.name,
    "--workdir",
    newPath
  );
  return `Workdir changed to \`${newPath}\`. Session respawned.\n\`\`\`\n${output}\n\`\`\``;
}

async function handleSkillsList(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const workdir = await readWorkdir(channelId);
  if (workdir === "(unknown)") {
    return "Cannot determine session workdir.";
  }

  const skills: string[] = [];

  // Scan .claude/skills/ in the workdir
  const claudeSkillsDir = join(workdir, ".claude", "skills");
  if (existsSync(claudeSkillsDir)) {
    try {
      const entries = readdirSync(claudeSkillsDir);
      for (const entry of entries) {
        const skillMd = join(claudeSkillsDir, entry, "SKILL.md");
        if (existsSync(skillMd)) {
          skills.push(entry);
        }
      }
    } catch {}
  }

  // Scan skills/ in the workdir
  const skillsDir = join(workdir, "skills");
  if (existsSync(skillsDir)) {
    try {
      const entries = readdirSync(skillsDir);
      for (const entry of entries) {
        const skillMd = join(skillsDir, entry, "SKILL.md");
        if (existsSync(skillMd)) {
          skills.push(entry);
        }
      }
    } catch {}
  }

  if (skills.length === 0) {
    return `No skills found in \`${workdir}\`.\nLooked in \`.claude/skills/\` and \`skills/\`.`;
  }

  const list = skills.map((s) => `- \`${s}\``).join("\n");
  return `**Installed skills** (${skills.length}):\n${list}\n\nWorkdir: \`${workdir}\``;
}

async function handleSkillsInstall(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const skillName = interaction.options.getString("name", true);
  const alive = await isTmuxAlive(session.tmux);
  if (!alive) {
    return `Session \`${session.tmux}\` is not running. Use \`/session wake\` or \`/session restart\` first.`;
  }

  // Send the install command to the tmux session
  const escapedCmd = escapeForTmux(`npx @anthropic-ai/claude-code skills add ${skillName} -g -y`);
  try {
    await $`tmux send-keys -t ${session.tmux} ${escapedCmd} Enter`.quiet();
  } catch (e: any) {
    return `Failed to send install command: ${e.message}`;
  }

  // Wait a bit, then refresh the session to pick up the new skill
  return `Installing skill \`${skillName}\`... Command sent to session \`${session.tmux}\`.\nUse \`/session refresh\` after installation completes to reload.`;
}

async function handleDiscover(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const output = await runManager("discover-all");
  return `Discovery complete.\n\`\`\`\n${output}\n\`\`\``;
}

async function handleAsk(
  interaction: ChatInputCommandInteraction
): Promise<string> {
  const channelId = interaction.channelId;
  const session = findSessionByChannel(channelId);
  if (!session) {
    return "No session registered for this channel. Try `/discover` first.";
  }

  const alive = await isTmuxAlive(session.tmux);
  if (!alive) {
    return `Session \`${session.tmux}\` is not running. Use \`/session wake\` or \`/session restart\` first.`;
  }

  const prompt = interaction.options.getString("prompt", true);
  const escapedPrompt = escapeForTmux(prompt);

  try {
    await $`tmux send-keys -t ${session.tmux} ${escapedPrompt} Enter`.quiet();
  } catch (e: any) {
    return `Failed to send prompt: ${e.message}`;
  }

  return `Sent to session \`${session.name}\`:\n> ${prompt.length > 200 ? prompt.slice(0, 200) + "..." : prompt}`;
}

// ── Autocomplete Handler ──────────────────────────────────────────────────

async function handleAutocomplete(
  interaction: AutocompleteInteraction
): Promise<void> {
  const focused = interaction.options.getFocused(true);

  if (
    interaction.commandName === "session" &&
    focused.name === "path"
  ) {
    const workdirMap = readWorkdirMap();
    const typed = (focused.value as string).toLowerCase();

    const choices = Object.entries(workdirMap)
      .filter(
        ([name, path]) =>
          name.toLowerCase().includes(typed) ||
          path.toLowerCase().includes(typed)
      )
      .slice(0, 25)
      .map(([name, path]) => {
        // Expand $HOME in display
        const displayPath = path.replace(/\$HOME/g, "~");
        return {
          name: `${name} → ${displayPath}`.slice(0, 100),
          value: path.replace(/\$HOME/g, homedir()),
        };
      });

    await interaction.respond(choices);
  }
}

// ── Interaction Router ────────────────────────────────────────────────────

async function handleInteraction(
  interaction: ChatInputCommandInteraction
): Promise<void> {
  const { commandName } = interaction;

  // Determine if response should be ephemeral
  const isEphemeral =
    (commandName === "session" &&
      interaction.options.getSubcommand() === "status") ||
    (commandName === "skills" &&
      interaction.options.getSubcommand() === "list");

  // Defer reply
  await interaction.deferReply({ ephemeral: isEphemeral });

  let response: string;

  try {
    switch (commandName) {
      case "session": {
        const sub = interaction.options.getSubcommand();
        switch (sub) {
          case "status":
            response = await handleSessionStatus(interaction);
            break;
          case "restart":
            response = await handleSessionRestart(interaction);
            break;
          case "refresh":
            response = await handleSessionRefresh(interaction);
            break;
          case "kill":
            response = await handleSessionKill(interaction);
            break;
          case "wake":
            response = await handleSessionWake(interaction);
            break;
          case "workdir":
            response = await handleSessionWorkdir(interaction);
            break;
          default:
            response = `Unknown subcommand: ${sub}`;
        }
        break;
      }
      case "skills": {
        const sub = interaction.options.getSubcommand();
        switch (sub) {
          case "list":
            response = await handleSkillsList(interaction);
            break;
          case "install":
            response = await handleSkillsInstall(interaction);
            break;
          default:
            response = `Unknown subcommand: ${sub}`;
        }
        break;
      }
      case "discover":
        response = await handleDiscover(interaction);
        break;
      case "ask":
        response = await handleAsk(interaction);
        break;
      default:
        response = `Unknown command: ${commandName}`;
    }
  } catch (e: any) {
    response = `Error: ${e.message}`;
    console.error(`[slash-daemon] Error handling /${commandName}:`, e);
  }

  // Edit the deferred response
  try {
    // Check if response contains an embed
    if (response.startsWith("{") && response.includes('"embed"')) {
      const parsed = JSON.parse(response);
      await interaction.editReply({ embeds: [parsed.embed] });
    } else {
      // Truncate if too long for Discord
      if (response.length > 2000) {
        response = response.slice(0, 1997) + "...";
      }
      await interaction.editReply({ content: response });
    }
  } catch (e: any) {
    console.error("[slash-daemon] Failed to edit reply:", e);
  }
}

// ── Register Commands ─────────────────────────────────────────────────────

async function registerCommands(rest: REST): Promise<void> {
  console.log("[slash-daemon] Fetching application ID...");

  const app = (await rest.get(Routes.oauth2CurrentApplication())) as {
    id: string;
    name: string;
  };
  const appId = app.id;
  console.log(`[slash-daemon] Application: ${app.name} (${appId})`);

  console.log(
    `[slash-daemon] Registering ${SLASH_COMMANDS.length} slash commands for guild ${GUILD_ID}...`
  );

  await rest.put(Routes.applicationGuildCommands(appId, GUILD_ID), {
    body: SLASH_COMMANDS,
  });

  console.log("[slash-daemon] Slash commands registered successfully.");
}

// ── Main ──────────────────────────────────────────────────────────────────

async function main() {
  console.log("[slash-daemon] Starting Discord slash command daemon...");
  console.log(`[slash-daemon] Sessions dir: ${SESSIONS_DIR}`);
  console.log(`[slash-daemon] Manager: ${MANAGER_PATH}`);

  // Set up REST client and register commands
  const rest = new REST({ version: "10" }).setToken(BOT_TOKEN);
  await registerCommands(rest);

  // Create the Gateway client (Guilds intent only — message content handled by per-channel sessions)
  const client = new Client({
    intents: [GatewayIntentBits.Guilds],
  });

  client.on("ready", () => {
    console.log(
      `[slash-daemon] Connected as ${client.user?.tag} — listening for slash commands`
    );
  });

  client.on("interactionCreate", async (interaction) => {
    if (interaction.isAutocomplete()) {
      try {
        await handleAutocomplete(interaction as AutocompleteInteraction);
      } catch (e) {
        console.error("[slash-daemon] Autocomplete error:", e);
      }
      return;
    }

    if (interaction.isChatInputCommand()) {
      await handleInteraction(interaction as ChatInputCommandInteraction);
    }
  });

  // Graceful shutdown
  const shutdown = () => {
    console.log("[slash-daemon] Shutting down...");
    client.destroy();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  await client.login(BOT_TOKEN);
}

main().catch((e) => {
  console.error("[slash-daemon] Fatal error:", e);
  process.exit(1);
});
