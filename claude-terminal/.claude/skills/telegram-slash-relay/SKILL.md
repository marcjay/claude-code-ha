---
name: telegram-slash-relay
description: |
  Relay a Claude Code slash command (/compact, /clear, /mcp, /help, etc.) sent
  over the Telegram channel into the actual CLI session and report the result
  back to the Telegram sender.
  Use this when an inbound message with source="plugin:telegram:telegram" (or
  any future telegram channel plugin) consists of a real Claude Code slash
  command — text starting with "/" that names a CLI command, not a question
  or sentence that happens to start with "/". Do NOT use it for ordinary
  chat messages, and do not invent commands that don't exist — forward
  exactly what the sender typed and let the CLI itself decide if it's valid.
---

# Telegram Slash-Command Relay

## Why this exists

Slash commands (`/compact`, `/clear`, `/mcp`, `/help`, ...) are parsed by the
Claude Code CLI's own terminal input loop — not by anything in the message
content the Telegram channel plugin injects into the conversation. A slash
command arriving as ordinary Telegram message text is just text; the CLI
never sees it as a command unless it's actually typed into the pane's stdin.

This add-on always runs the CLI inside a persistent tmux session named
`claude` (see `claude-terminal/run.sh`), and — because that's the exact pane
this assistant process is itself running in — a slash command can be
delivered for real by shelling out to `tmux send-keys` into that same pane.

## The catch: it can't be observed in the same turn

Keys sent via `tmux send-keys` sit in the terminal's input buffer and are
only consumed by the CLI's REPL loop once the **current turn fully ends**
and control returns to the idle prompt. That means:

- You cannot send the command and then immediately `tmux capture-pane` to see
  its output within the same response — the command hasn't run yet.
- The observation step has to happen **after** this turn ends, as an
  independent process that outlives it.

`scripts/relay-slash-command.sh` handles this: it sends the keystrokes,
then polls the pane in a loop (outside of any model turn) until new output
appears and stabilizes, and posts that output straight to the Telegram Bot
API with `curl` — no MCP tool call needed for the follow-up, since by the
time it fires there is no active assistant turn to make one from.

## How to use it

When you receive a `<channel source="plugin:telegram:telegram" chat_id="..."
message_id="...">` message whose text is a real slash command:

1. Launch the relay script **in the background** (it must outlive this turn):

   ```bash
   nohup /config/.claude/skills/telegram-slash-relay/scripts/relay-slash-command.sh \
     "<chat_id>" "<message_id>" "<command text>" \
     >/tmp/telegram-slash-relay.log 2>&1 &
   disown
   ```

   Adjust the skill path if it's not installed at `/config/.claude/skills/...`
   in this container — locate it first if unsure.

2. Reply immediately in the same turn to acknowledge receipt — do **not**
   wait for the command's output, you don't have it yet:

   > Sent `/compact` to the session — I'll follow up here once it finishes.

3. End your turn. The command executes once you're idle; the script's own
   follow-up Telegram message (sent independently, minutes later is fine)
   delivers the actual output.

## Scope and safety

- The Telegram channel's own allowlist (`~/.claude/channels/telegram/access.json`)
  already gates who can reach the assistant at all — this skill doesn't add a
  second layer of confirmation on top, since only already-trusted senders can
  trigger it.
- This only relays slash-command syntax into the CLI's own trusted command
  namespace. Do not extend this mechanism to relay arbitrary shell/bash text
  — that would let an allowlisted Telegram user run arbitrary commands as
  the container's user, which is a materially different risk.
- `/clear` will wipe this session's context after it runs. That's expected
  and fine — the relay script is a plain shell process, independent of the
  assistant, so it still delivers its follow-up message normally.
- The output diff is a naive line-comparison between two `tmux capture-pane`
  snapshots. It works well for the CLI's normal scrolling transcript; a
  command that redraws the full screen (uncommon for slash commands) may
  produce a noisier diff than a human watching the terminal would see.
