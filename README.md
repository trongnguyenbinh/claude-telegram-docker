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
| `TZ` | – | default `Asia/Ho_Chi_Minh` |

Full variable list + volume layout in [`SPEC.md`](./SPEC.md).

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
