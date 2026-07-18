# Deploy one more bot (hands-on runbook — v2.2 worker)

> v2.2 = worker transport (`tg-worker.py`), single-volume `~/.claude` layout. 1 image = 1 bot: each bot has its own Telegram identity, its own volume, its own container. Bots can share a single `CLAUDE_CODE_OAUTH_TOKEN` (each bot = one `claude -p` session running in parallel on the same account). The worker is a headless daemon — NO `-it`/PTY needed.

## 0. Prep
- **New Telegram bot token** from @BotFather (`/newbot`). Don't reuse a handle from another bot.
- Pick a `NAME` (e.g. `bot-claude-support`) → used for the container + volume.
- `OWNER_ID` = the owner's Telegram user_id.
- `MODEL` (optional) — e.g. `sonnet`. `CLAUDE_CODE_OAUTH_TOKEN` (subscription) — reuse from an existing bot (section 2).
- Prepare a `CLAUDE.md` (rules + context) for the bot if you want (optional).

## 1. Run the container (entrypoint auto-seeds access.json + workspace)
```bash
docker run -dt --name ${NAME} --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN="$TG" -e OWNER_ID="$OWNER_ID" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH" -e MODEL=sonnet \
  -v ${NAME}-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
```
> The entrypoint auto-seeds `access.json` (owner-only allowlist, `mentionPatterns` from getMe) with an empty `groups:{}`, plus `~/.claude/workspace/{reminders,.workspace}`. `ANTHROPIC_API_KEY` is ignored by the worker (forces subscription).
> Trusted personal bot that wants wider permissions: add `-e TG_WORKER_ALLOWED_TOOLS="mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch,Bash,Edit,Write"`.

## 2. Reuse the OAuth token from a running bot (without printing it)
```bash
OAUTH=$(docker inspect <old-bot> --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p')
```

## 3. Seed the project CLAUDE.md (optional)
```bash
# the bot's work-dir CLAUDE.md = ~/.claude/workspace/CLAUDE.md (layered on the base). MUST chown 1000:1000.
docker cp CLAUDE.md ${NAME}:/home/botuser/.claude/workspace/CLAUDE.md
docker exec -u root ${NAME} chown 1000:1000 /home/botuser/.claude/workspace/CLAUDE.md
```
> The base CLAUDE.md (security + worker rules) is already seeded by the entrypoint into `~/.claude/CLAUDE.md`.

## 4. Wire up mempalace (if you want a shared brain)
```bash
TOKEN=$(docker exec -u botuser <old-bot> sh -c 'cat /home/botuser/.claude/.claude.json' \
  | jq -r '[.. | objects | (.mcpServers?.mempalace?.headers?.Authorization // empty)] | map(select(length>0)) | .[0]' | sed 's/^Bearer //')
docker exec -u botuser ${NAME} sh -c \
  "HOME=/home/botuser CLAUDE_CONFIG_DIR=/home/botuser/.claude claude mcp add --scope user --transport http mempalace https://mempalace.veasy.vn/mcp --header 'Authorization: Bearer $TOKEN'"
docker restart ${NAME}
docker exec -u botuser ${NAME} sh -c 'HOME=/home/botuser CLAUDE_CONFIG_DIR=/home/botuser/.claude claude mcp list'
```
> mempalace is already in the default `TG_WORKER_ALLOWED_TOOLS`.

## 5. Enable a group (owner runs this in a terminal)
```bash
docker exec -u botuser ${NAME} tg-access group add <groupId>
```
> access.json is re-read per message → effective IMMEDIATELY, no restart needed. The bot must be added to the group.

## 6. Verify
```bash
docker exec ${NAME} bot-doctor
docker exec -u botuser ${NAME} sh -c 'tail -20 /home/botuser/.claude/telegram/worker.log'
```

## ⚠️ GOTCHAS (read carefully)
- **EVERY `docker exec` that touches state must include `-u botuser`** (tg-access, claude mcp, tg-reminder). Running as root → files in `~/.claude` get owned by root.
- **`tg-access` (any access mutation) only runs on the host/terminal**, NOT wired to a Telegram message (anti-prompt-injection). access.json auto-seeds an empty `groups:{}` → you must always add groups manually.
- Watch the bot live (no more tmux): `docker logs -f ${NAME}` or `tail -f ~/.claude/telegram/worker.log`.
- Only mount `~/.claude` — don't mount all of `/home/botuser` (it shadows the claude/bun binaries in the image).
- Secret token: reuse via `docker inspect` / the old bot's config, do NOT print it into chat. If a BotFather token leaks → `/revoke`.
