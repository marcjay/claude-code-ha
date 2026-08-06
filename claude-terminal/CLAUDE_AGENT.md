# Claude Agent layer

This fork adds a thin "always-on agent" layer on top of
[esjavadex/claude-code-ha](https://github.com/esjavadex/claude-code-ha)
(itself a fork of [heytcass/home-assistant-addons](https://github.com/heytcass/home-assistant-addons)).
Everything the base add-on does — persistent OAuth login, tmux session that
survives restarts, `ha`/`gh`/git/python, image paste, persistent packages — is
unchanged. The add-on slug is renamed to `claude_agent` so it installs
alongside (not over) the original.

The goal: one Claude Code session that runs 24/7 and is reachable **four** ways.

## Reaching the session

| Method | How | Needs |
| --- | --- | --- |
| **Web terminal** | The "Claude Agent" item in the HA sidebar (ingress). | nothing |
| **SSH** | `ssh root@<ha-ip> -p <mapped-port>` then `tmux attach -t claude`. | `enable_ssh` + `ssh_password` |
| **Remote Control (`/rc`)** | In the session, run `/rc`, then attach from the Claude mobile app / claude.ai. | subscription login |
| **Telegram** | Message your bot; Claude replies in the chat. | `enable_telegram` + `telegram_bot_token` |

All four attach to the **same** persistent tmux session named `claude`, so a
conversation started in the browser can be continued from your phone.

## Authentication

Subscription login (Pro/Max), not an API key. On first run, open the web
terminal and complete the `claude` OAuth login once; the token is persisted to
`/data` and reused across restarts. Remote Control (`/rc`) requires this
subscription login — it does not work with a bare `ANTHROPIC_API_KEY`.

## Home Assistant MCP

Set `enable_ha_mcp: true` and paste the connect URL from the
[HA-MCP integration](https://github.com/homeassistant-ai/ha-mcp-integration)
(HACS → install → Settings → Devices & Services → HA-MCP → Configure) into
`ha_mcp_url`. On startup the add-on registers it with:

```
claude mcp add --transport http --scope user ha-home-assistant "<ha_mcp_url>"
```

It is registered at **user** scope so it persists in `/data`. Leaving
`ha_mcp_url` empty just logs a warning and skips registration (the add-on still
starts). This is the *remote streamable-HTTP* MCP server from the HACS
integration — separate from any MCP the base image may bundle.

## Telegram (research preview)

Telegram uses Claude Code's **Channels** feature, which is a research preview —
plugin and flag names may change upstream.

1. Create a bot with [@BotFather](https://t.me/BotFather) (`/newbot`) and copy the token.
2. Set `enable_telegram: true` and paste the token into `telegram_bot_token`.

On startup the add-on writes the token to
`~/.claude/channels/telegram/.env`, best-effort installs the plugin, and
launches Claude with `--channels plugin:telegram@claude-plugins-official`.
If the non-interactive plugin install fails, run it once from the web terminal:

```
/plugin install telegram@claude-plugins-official
```

then restart the add-on.

### Requirements & locking it down

The channel plugins are [Bun](https://bun.sh) scripts, so **Bun is baked into
the image** (amd64 uses the *baseline* build so it runs on CPUs without AVX2;
arm64 uses the musl build; 32-bit ARM has no Bun and can't use channels).

By default **anyone who messages the bot gets a pairing code** — you must switch
to an allowlist. After the add-on's first start with Telegram enabled, DM the
bot, then in the Claude session run:

```
/telegram:access pair <code>          # code the bot replied with — adds your user ID
/telegram:access policy allowlist      # now only you can send; everyone else dropped
```

The allowlist gates *who can approve tool-use prompts* too, so keep it to
yourself — especially before enabling `--permission-mode`/skip-permissions. If
the `/telegram:*` commands are missing, the plugin didn't load; run
`/plugin marketplace add anthropics/claude-plugins-official`,
`/plugin install telegram@claude-plugins-official`, `/reload-plugins`, then
restart the add-on.

> **iMessage / Discord:** iMessage's plugin needs macOS (it reads the Messages
> DB and drives AppleScript), so it cannot run in this Linux add-on. Discord
> works the same way as Telegram if you'd prefer it.

### Forcing Telegram replies (Stop hook)

Claude can compose a good answer for an inbound Telegram message as plain
assistant text and then simply forget to call the channel's `reply` tool — the
text sits in the transcript and never reaches the chat. A `Stop` hook closes
this gap: it runs every time Claude finishes a turn and blocks the turn from
ending if the most recent inbound Telegram message was never followed by a
`mcp__plugin_telegram_telegram__reply` tool call.

The script ships at `.claude/hooks/telegram-reply-check.py` in this repo. It
reads `transcript_path` off the hook's stdin JSON, scans the session's JSONL
transcript for the last entry with `origin.kind == "channel"` and
`origin.server == "plugin:telegram:telegram"`, and checks whether any
assistant `tool_use` for the reply tool appears after it. If not — and the
hook isn't already mid-retry (`stop_hook_active`, to avoid looping) — it
prints `{"decision": "block", "reason": "..."}`, which forces Claude to
actually send the reply before the turn can end.

To wire it up, add this to `~/.claude/settings.json` (merge into the existing
object — don't replace it):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/telegram-reply-check.py"
          }
        ]
      }
    ]
  }
}
```

and copy the script itself to `~/.claude/hooks/telegram-reply-check.py` (or
point the `command` at wherever this repo is checked out — see the skill
symlink pattern used for `telegram-slash-relay` above for a live-edit setup).
No `matcher` is needed since `Stop` hooks aren't tool-scoped. Requires
`python3` on `PATH`, which the add-on image already provides.

## SSH

SSH host keys are persisted to `/data/ssh`, so they stay stable across rebuilds (no repeated "host key changed" prompts). `enable_ssh: true` + a non-empty `ssh_password` starts `sshd` (installed
on demand) for `root`. Map container port 22 to a free host port in the add-on
**Network** panel (e.g. `2222` — the official SSH add-on already uses 22).
Logins land in the add-on's environment (native `claude` on `PATH`,
persistent packages), so `tmux attach -t claude` drops you straight into the
live session.

**Passwordless login:** put your public key(s) in the `ssh_authorized_keys` option (e.g. the contents of `~/.ssh/id_ed25519.pub`) and you can SSH with no password. Set *only* keys and leave `ssh_password` empty for key-only access (password login is then disabled). Keys are re-applied on every boot, so they survive rebuilds.

> Password root login on the LAN — enable it deliberately. Prefer `/rc` or the
> web terminal if you don't specifically need SSH.

## New options

| Option | Default | Purpose |
| --- | --- | --- |
| `enable_ha_mcp` | `true` | Register the HA MCP server on startup. |
| `ha_mcp_url` | `""` | Connect URL from the HA-MCP integration. |
| `enable_ssh` | `false` | Start an SSH server. |
| `ssh_password` | `""` | Root SSH password (required when `enable_ssh`). |
| `enable_telegram` | `false` | Attach the Telegram channel. |
| `telegram_bot_token` | `""` | BotFather token (required when `enable_telegram`). |
| `claude_extra_args` | `""` | Extra flags appended to every `claude` launch. |

## Keeping in sync with upstream

```
git fetch upstream
git merge upstream/main   # resolve the small rebrand hunks in config.yaml/README
```

The added logic lives in new `run.sh` functions (`setup_ha_mcp`,
`setup_telegram`, `start_ssh`) plus a few one-line hooks, so merges stay small.
