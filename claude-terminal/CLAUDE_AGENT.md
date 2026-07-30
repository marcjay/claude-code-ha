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

## SSH

`enable_ssh: true` + a non-empty `ssh_password` starts `sshd` (installed
on demand) for `root`. Map container port 22 to a free host port in the add-on
**Network** panel (e.g. `2222` — the official SSH add-on already uses 22).
Logins land in the add-on's environment (native `claude` on `PATH`,
persistent packages), so `tmux attach -t claude` drops you straight into the
live session.

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
