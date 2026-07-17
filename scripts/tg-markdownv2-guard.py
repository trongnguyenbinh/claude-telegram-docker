#!/usr/bin/env python3
"""PreToolUse hook for the Telegram reply tool: catch MarkdownV2 formatting
mistakes BEFORE the message is sent.

Two recurring failures this guards against:
  1. The message contains a ``` fenced code block but `format` is NOT 'markdownv2'
     -> Telegram renders the fences as literal backticks (no tap-to-copy block).
  2. `format` is 'markdownv2' but there are UNESCAPED MarkdownV2 special chars in
     the prose outside the code block -> Telegram Bot API returns HTTP 400.

On a violation the hook exits 2 (blocks the tool call) and writes the reason to
stderr so the model fixes the call and retries.
"""
import sys
import json
import re


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool_input = data.get("tool_input", {}) or {}
    text = tool_input.get("text", "") or ""
    fmt = tool_input.get("format", "text") or "text"

    has_fence = "```" in text

    # Rule 1: fenced code block but plain-text format -> fences render literally.
    if has_fence and fmt != "markdownv2":
        sys.stderr.write(
            "Telegram reply contains a ``` code block but format is not "
            "'markdownv2'. The fences will show as literal backticks instead of a "
            "tap-to-copy code block. Re-send with format:'markdownv2', keeping the "
            "message essentially just the fenced block (put any prose in a separate "
            "plain-text reply).\n"
        )
        sys.exit(2)

    # Rule 2: markdownv2 with unescaped reserved chars in prose outside fences.
    if fmt == "markdownv2":
        prose = re.sub(r"```.*?```", "", text, flags=re.S)  # drop fenced blocks
        reserved = set("_*[]()~`>#+-=|{}.!")
        bad = []
        for i, ch in enumerate(prose):
            if ch in reserved:
                prev = prose[i - 1] if i > 0 else ""
                if prev != "\\":
                    bad.append(ch)
        if bad:
            sample = "".join(sorted(set(bad)))
            sys.stderr.write(
                "Telegram reply uses format:'markdownv2' but the prose outside the "
                "code block has UNESCAPED MarkdownV2 special chars (" + sample + ") "
                "-> Telegram will reject it with HTTP 400. Fix one of two ways: "
                "(a) use markdownv2 ONLY for messages that are essentially just a "
                "fenced code block, and move prose to a separate PLAIN-TEXT reply; or "
                "(b) escape every special char with a backslash: "
                r"_ * [ ] ( ) ~ ` > # + - = | { } . !"
                "\n"
            )
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
