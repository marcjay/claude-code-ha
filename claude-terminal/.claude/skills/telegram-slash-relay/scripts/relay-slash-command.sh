#!/bin/sh
# relay-slash-command.sh <chat_id> <reply_to_message_id> <command text>
#
# Types <command text> into the "claude" tmux pane's stdin (the same pane this
# script's caller is itself running in) as if a human had typed it, then polls
# the pane until new output appears and stabilizes, and posts that output back
# to the given Telegram chat via the Bot API directly (curl), bypassing the
# assistant conversation entirely — this script keeps running after the
# assistant's turn that launched it has ended, which is required: injected
# keystrokes only get consumed by the CLI's input loop once the current turn
# finishes and control returns to the idle prompt, so no in-turn tool call can
# observe the result.
#
# Requires: tmux, curl. Reads the bot token from the same .env the telegram
# plugin uses, so no separate credential is needed.

set -eu

CHAT_ID="${1:?chat_id required}"
REPLY_TO="${2:?reply_to_message_id required}"
COMMAND="${3:?command text required}"

TMUX_SESSION="claude"
ENV_FILE="$HOME/.claude/channels/telegram/.env"
MAX_WAIT_SECONDS=120
POLL_INTERVAL_SECONDS=2
STABLE_POLLS_REQUIRED=3
TELEGRAM_MAX_CHARS=3800

if [ ! -f "$ENV_FILE" ]; then
    echo "relay-slash-command: no telegram .env at $ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "relay-slash-command: TELEGRAM_BOT_TOKEN not set in $ENV_FILE" >&2
    exit 1
fi

if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    echo "relay-slash-command: no tmux session named '$TMUX_SESSION'" >&2
    exit 1
fi

send_telegram_message() {
    # $1 = message text
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d reply_to_message_id="${REPLY_TO}" \
        --data-urlencode text="$1" \
        >/dev/null
}

before_file="$(mktemp)"
cur_file="$(mktemp)"
prev_file="$(mktemp)"
trap 'rm -f "$before_file" "$cur_file" "$prev_file"' EXIT

tmux capture-pane -t "$TMUX_SESSION" -p >"$before_file"

# Type the command into the pane's stdin, then Enter as a separate key so
# tmux doesn't try to interpret the command text itself as tmux flags/keys.
tmux send-keys -t "$TMUX_SESSION" -l -- "$COMMAND"
tmux send-keys -t "$TMUX_SESSION" Enter

cp "$before_file" "$prev_file"
stable_count=0
changed=0
elapsed=0

while [ "$elapsed" -lt "$MAX_WAIT_SECONDS" ]; do
    sleep "$POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
    tmux capture-pane -t "$TMUX_SESSION" -p >"$cur_file"

    if ! cmp -s "$before_file" "$cur_file"; then
        changed=1
    fi

    if cmp -s "$prev_file" "$cur_file"; then
        stable_count=$((stable_count + 1))
    else
        stable_count=0
    fi
    cp "$cur_file" "$prev_file"

    if [ "$changed" -eq 1 ] && [ "$stable_count" -ge "$STABLE_POLLS_REQUIRED" ]; then
        break
    fi
done

if [ "$changed" -eq 0 ]; then
    send_telegram_message "Sent \`${COMMAND}\` but saw no change in the terminal after ${MAX_WAIT_SECONDS}s — it may not have run, or the session is still busy with something else."
    exit 0
fi

# Naive diff: lines present in the "after" capture but not in the "before"
# capture, in order. Good enough for a scrolling terminal transcript; a
# full-screen redraw (rare for slash-command output) may produce a noisy diff.
# Note: busybox diff only speaks unified format (+/-/@@), never the classic
# >/< POSIX format, regardless of flags passed — so added lines are "+"
# lines, and "+++" (the unified header) must be excluded explicitly.
diff_output="$(diff "$before_file" "$cur_file" 2>/dev/null | grep '^+' | grep -v '^+++' | sed 's/^+//' || true)"

if [ -z "$diff_output" ]; then
    diff_output="(ran, but the visible output was identical to before — likely just a prompt redraw)"
fi

truncated_output="$(printf '%s' "$diff_output" | tail -c "$TELEGRAM_MAX_CHARS")"

reply_text="$(printf 'Output of `%s`:\n```\n%s\n```' "$COMMAND" "$truncated_output")"
send_telegram_message "$reply_text"
