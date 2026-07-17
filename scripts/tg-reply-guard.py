#!/usr/bin/env python3
"""Stop hook: nag if a Telegram channel message was answered without sending the
reply through the telegram reply tool.

The assistant repeatedly writes its answer as plain transcript text (which never
reaches the Telegram user) instead of calling mcp__plugin_telegram_telegram__reply.
This hook inspects the current turn and, if the triggering user message is a
Telegram <channel> message but no telegram reply tool_use happened this turn,
blocks the stop with a reminder so the assistant sends it for real.
"""
import sys
import json


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    # Avoid infinite loops: if we already blocked once this stop cycle, let it go.
    if data.get("stop_hook_active"):
        sys.exit(0)

    tp = data.get("transcript_path")
    if not tp:
        sys.exit(0)

    try:
        with open(tp) as fh:
            lines = [json.loads(l) for l in fh if l.strip()]
    except Exception:
        sys.exit(0)

    def role_of(entry):
        if entry.get("type") in ("user", "assistant"):
            return entry["type"]
        return (entry.get("message", {}) or {}).get("role")

    # Index of the last user message.
    last_user_idx = None
    for i, entry in enumerate(lines):
        if role_of(entry) == "user":
            last_user_idx = i
    if last_user_idx is None:
        sys.exit(0)

    # Extract text of that user message.
    msg = lines[last_user_idx].get("message", {}) or {}
    content = msg.get("content")
    text = ""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        for c in content:
            if isinstance(c, dict):
                text += c.get("text", "") or ""

    # Only enforce for real Telegram channel messages (not background events,
    # terminal input, or task notifications).
    if "plugin:telegram:telegram" not in text:
        sys.exit(0)
    # Background/system notifications are not user turns that need a reply.
    if "SYSTEM NOTIFICATION" in text or "task-notification" in text:
        sys.exit(0)

    # Did any assistant turn since then call the telegram reply tool?
    replied = False
    for entry in lines[last_user_idx + 1:]:
        if role_of(entry) != "assistant":
            continue
        for c in (entry.get("message", {}) or {}).get("content", []) or []:
            if isinstance(c, dict) and c.get("type") == "tool_use":
                name = c.get("name", "") or ""
                if "telegram" in name and "reply" in name:
                    replied = True
                    break
        if replied:
            break

    if replied:
        sys.exit(0)

    print(json.dumps({
        "decision": "block",
        "reason": (
            "You answered a Telegram channel message but did NOT send your reply "
            "through the telegram reply tool (mcp__plugin_telegram_telegram__reply). "
            "Your transcript text never reaches the user. Send the reply now via the "
            "reply tool (pass chat_id). React-only turns still need this unless a text "
            "reply is genuinely not warranted."
        ),
    }))
    sys.exit(0)


if __name__ == "__main__":
    main()
