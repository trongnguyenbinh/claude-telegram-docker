# claude-telegram-docker

[🇻🇳 Tiếng Việt](./README.md) · **🇬🇧 English**

Run a Claude-Code-powered Telegram bot as a single container. **1 image = 1 bot.**
Full design: [`SPEC.md`](./SPEC.md).

## Quick start (from the published image — no build, no clone)

```bash
docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<from @BotFather> \
  -e OWNER_ID=<your Telegram user_id> \
  -v botdata:/data \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest

# one-time Claude auth — generate a token (uses your Claude subscription):
docker exec -it mybot claude setup-token
#   → opens a URL, authorize, paste the FULL code; it PRINTS a long-lived token.
# Put that token in the container env and recreate:
#   add  CLAUDE_CODE_OAUTH_TOKEN=<token>  to your -e flags / .env, then:
docker rm -f mybot && docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<the-token-from-setup-token> \
  -v botdata:/data --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
#   (env token = headless auth, survives volume wipes. `claude auth login` tends
#    to 400 in a container — no real browser / PKCE state mismatch.)
docker exec mybot claude auth status   # loggedIn:true
```

That's it. Check status / manage access:

```bash
docker exec mybot claude auth status
docker exec mybot tg-access status
docker exec mybot tg-access group add <group-id>
```

The image is published to GHCR by GitHub Actions on every push to `main` and on
every `v*` tag (`.github/workflows/docker-publish.yml`, linux/amd64 + arm64).

## Build locally instead (for development)

```bash
cp .env.example .env      # fill TELEGRAM_BOT_TOKEN + OWNER_ID
docker compose up -d --build
# one-time auth — PRINTS a token (does NOT persist it on its own):
docker exec -it claude-tg-bot claude setup-token
#   → open the URL, authorize, paste the FULL code; it prints a long-lived token.
# Put that token in .env, then RECREATE (not `restart` — restart won't reload env):
#   add  CLAUDE_CODE_OAUTH_TOKEN=<the-printed-token>  to .env, then:
docker compose up -d
docker exec claude-tg-bot claude auth status   # loggedIn:true
```

> Gotcha: `setup-token` only *prints* a headless token (`Use this token by setting:
> export CLAUDE_CODE_OAUTH_TOKEN=...`). It does **not** write credentials to the
> volume, so `docker compose restart` alone leaves `loggedIn:false`. The token must
> go into `.env` (`CLAUDE_CODE_OAUTH_TOKEN`) and the container must be **recreated**
> (`docker compose up -d`) so the env is re-read.

## How it works

- **Base** `debian:bookworm-slim` + `bun` (the telegram plugin runs its MCP server with bun) + the Claude Code CLI (native installer) + the telegram plugin baked in.
- **`entrypoint.sh`** (first run): seeds the baked plugin onto the volume, writes the bot token, and seeds `access.json` as **`allowlist` with `allowFrom=[OWNER_ID]`** (owner-only, no pairing). Then `exec claude --channels plugin:telegram@claude-plugins-official`.
- **State on a volume** (`/data`): Claude config + credentials (`/data/.claude`) and telegram state (`/data/telegram`: token, `access.json`). Survives restarts; login is one-time.
- **Admin via `docker exec tg-access …`** (the host is the authenticated channel). Never change access from a Telegram message.

## Environment variables

| Var | Required | Notes |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | from @BotFather |
| `OWNER_ID` | ✅ | your Telegram user_id (single owner) |
| `CLAUDE_CODE_OAUTH_TOKEN` | recommended | headless auth — generate once with `claude setup-token`, paste here. Survives volume wipes. |
| `PERMISSION_MODE` | optional | `default`/`acceptEdits`/`bypassPermissions`/`plan`. Unset = claude default. Set `bypassPermissions` for an autonomous bot that runs tools without prompting (opt in deliberately). |
| `WORK_DIR` | optional | dir the bot's claude runs in (file ops land here, pre-trusted). Default `/working-directory/claude-telegram-bot`; persisted on the `botwork` volume. |
| `ANTHROPIC_API_KEY` | fallback | pay-per-token instead of your subscription |
| `MODEL` / `TZ` | optional | |

## Gotchas

- `claude --channels` is an interactive TUI → the container needs a PTY (`tty: true` + `stdin_open: true`, already set in compose; use `-it` with `docker run`).
- **One token = one container.** Telegram allows a single `getUpdates` poller per token; two containers on the same token → 409 conflict.
- Changing the token requires a container restart (read once at boot).

## tg-access

```
tg-access status
tg-access allow <userId> | remove <userId>
tg-access policy <pairing|allowlist|disabled>
tg-access group add <groupId> [--allow id1,id2] [--no-mention]
tg-access group rm <groupId>
tg-access pair <code>
```

## License

[MIT](./LICENSE) © Edward Nguyen
