# Changelog

## v2.2.0 — worker transport (replaces `--channels`)

**Breaking.** Ships as `:v2.2.0` / `:v2.2.0-playwright`; does not move `:latest`.

- Drops `claude --channels` entirely — the CLI channel-host poller kept failing to
  start on container start/restart. Replaced by a Python Bot-API worker
  (`scripts/tg-worker.py`) as the container's main process: it long-polls
  `getUpdates` and invokes headless `claude -p` once per message.
- **Stable** (the worker owns its own poll loop), **~20x lighter at idle**
  (~13 MB vs ~280 MB), no tmux, always on the subscription (`ANTHROPIC_API_KEY`
  is popped).
- **New — reminders**: a scheduler thread scans `~/.claude/workspace/reminders/*.json`
  and fires due entries (`mode:text` → send; `mode:claude` → run one `claude -p`
  turn). One-off or daily/weekly, container timezone. CLI: `tg-reminder add|list|remove`.
- **New — questions-to-Telegram**: when it needs the owner to decide, Claude sends
  the question as a reply and ends the turn; the owner's next message is the answer,
  and the session resumes via `--resume`.
- **Safe-by-default permissions**: default `--allowedTools` excludes free Bash
  (`mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch`); widen via
  `TG_WORKER_ALLOWED_TOOLS`.
- **Layout change**: a single `~/.claude` volume (no longer the v1.x `/data` volume).
- **Removed**: `tg-watchdog`, the reply/markdownv2 guards, the telegram plugin
  (the worker owns the Bot API), and `managed-settings.json` (only `--channels` needed it).

### Migration from v1.x (clean install — no copy)

The v1.x `/data` volume is not migrated (a copy would break plugin paths). Rebuild
each bot fresh on a new `~/.claude` volume:

```bash
docker run -d --name <bot> --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<oauth> -e MODEL=sonnet \
  -v <bot>-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace \
  https://<domain>/mcp --header "Authorization: Bearer <token>"
docker restart <bot>
docker exec -u botuser <bot> tg-access group add <groupId>   # in the terminal only
```

Rollback = keep the old v1.x container/volume until v2.2 runs cleanly.
