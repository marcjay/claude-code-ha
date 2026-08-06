#!/usr/bin/env python3
"""Stop hook: block ending the turn if the most recent inbound Telegram
message (origin.kind == "channel", origin.server == "plugin:telegram:telegram")
was never followed by a mcp__plugin_telegram_telegram__reply tool call."""
import sys
import json
import re


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    if data.get("stop_hook_active"):
        return 0

    transcript_path = data.get("transcript_path")
    if not transcript_path:
        return 0

    try:
        with open(transcript_path) as f:
            lines = f.readlines()
    except Exception:
        return 0

    last_telegram_idx = None
    last_chat_id = None
    for i, line in enumerate(lines):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "user":
            continue
        msg = d.get("message", {})
        if msg.get("role") != "user":
            continue
        origin = d.get("origin", {})
        if origin.get("kind") == "channel" and origin.get("server") == "plugin:telegram:telegram":
            last_telegram_idx = i
            content = msg.get("content")
            text = content if isinstance(content, str) else json.dumps(content)
            m = re.search(r'chat_id="([^"]+)"', text)
            if m:
                last_chat_id = m.group(1)

    if last_telegram_idx is None:
        return 0

    replied = False
    for line in lines[last_telegram_idx + 1:]:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "assistant":
            continue
        content = d.get("message", {}).get("content", [])
        if not isinstance(content, list):
            continue
        for block in content:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name") == "mcp__plugin_telegram_telegram__reply"
            ):
                replied = True
                break
        if replied:
            break

    if not replied:
        reason = (
            "You received an inbound Telegram message but ended your turn "
            "without calling mcp__plugin_telegram_telegram__reply."
        )
        if last_chat_id:
            reason += f' Call it now with chat_id="{last_chat_id}" before stopping.'
        print(json.dumps({"decision": "block", "reason": reason}))

    return 0


if __name__ == "__main__":
    sys.exit(main())
