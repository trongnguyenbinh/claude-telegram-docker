# claude-telegram-docker

Run a Claude-Code-powered Telegram bot as a single container. **1 image = 1 bot.**

A headless Python worker owns the Telegram Bot API (long-polls `getUpdates`) and
invokes `claude -p` per message, on your Claude subscription — no PTY, no tmux.

- Design & internals — [`SPEC.md`](./SPEC.md)
- Command reference — [`CHEATSHEET.md`](./CHEATSHEET.md)
- Operations & troubleshooting — [`OPERATIONS.md`](./OPERATIONS.md)
- Role profiles — [`roles/README.md`](./roles/README.md)
- Per-version changes & migration — [`CHANGELOG.md`](./CHANGELOG.md)

## Quick start

```bash
docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<from @BotFather> \
  -e OWNER_ID=<your Telegram user_id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<generate: claude setup-token> \
  -v mybot-claude:/home/botuser/.claude \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
```

```bash
docker exec -u botuser mybot bot-doctor      # verify
```

Auth uses your **subscription** via `CLAUDE_CODE_OAUTH_TOKEN` (`ANTHROPIC_API_KEY`
is intentionally ignored). Run `claude` / `tg-access` with `-u botuser`.

## Configuration

| Var | Required | Notes |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | from @BotFather |
| `OWNER_ID` | ✅ | your Telegram user_id (single owner) |
| `CLAUDE_CODE_OAUTH_TOKEN` | ✅ | subscription auth — `claude setup-token` |
| `MODEL` | – | e.g. `sonnet` |
| `TG_WORKER_ALLOWED_TOOLS` | – | tool allowlist; default excludes free Bash |
| `BOT_ROLE` | – | `ba` / `planner` / `dev-fe` / `dev-be` / `tester` / `infra` |
| `VOICE_API_URL` | – | Voice API base URL (e.g. `https://voice.veasy.vn`) — enables voice |
| `VOICE_API_KEY` | – | per-bot Voice API key (`vsk_…`); set with `VOICE_API_URL` |
| `TZ` | – | default `Asia/Ho_Chi_Minh` |

Full variable list + volume layout in [`SPEC.md`](./SPEC.md).

## Media (images, voice, documents)

The bot handles attachments out of the box:

- **Images** → Claude views them with its built-in `Read` tool.
- **Documents** (PDF/code/text) → Claude reads them with `Read`.
- **Voice / audio** → transcribed to text **when `VOICE_API_URL` + `VOICE_API_KEY` are set**
  (via an external [voice-service](https://github.com/trongnguyenbinh/voice-service) Voice API).

With voice configured, the bot can also **reply as a voice bubble**: Claude starts its reply
with `[[voice]]` and the worker synthesizes + sends it (great for pronunciation/tutor bots).
Setting the two voice vars also auto-registers a baked `voice` MCP tool for the bot.

## Access control

Access is managed from the host (the authenticated channel), never from a Telegram message:

```bash
docker exec -u botuser mybot tg-access status
docker exec -u botuser mybot tg-access group add <group-id>
```

## Build locally

```bash
cp .env.example .env      # TELEGRAM_BOT_TOKEN + OWNER_ID + CLAUDE_CODE_OAUTH_TOKEN
docker compose up -d --build
```

## License

[MIT](./LICENSE) © Edward Nguyen

## Contributors

[![Contributors](https://contrib.rocks/image?repo=trongnguyenbinh/claude-telegram-docker)](https://github.com/trongnguyenbinh/claude-telegram-docker/graphs/contributors)
