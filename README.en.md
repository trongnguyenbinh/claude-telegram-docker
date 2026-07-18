# claude-telegram-docker

[🇻🇳 Tiếng Việt](./README.md) · **🇬🇧 English**

Run a Claude-Code-powered Telegram bot as a single container. **1 image = 1 bot.**
Full design: [`SPEC.md`](./SPEC.md). Quick command table: [`CHEATSHEET.md`](./CHEATSHEET.md). Operations & troubleshooting: [`OPERATIONS.md`](./OPERATIONS.md).

## v2.2 — "worker" transport (replaces `--channels`)

As of v2.2 the image **drops `claude --channels` entirely** (the CLI channel-host poller kept failing to start on container start/restart). In its place is **a Python Bot-API worker** (`scripts/tg-worker.py`) as the container's main process: it long-polls `getUpdates` itself and, per message, invokes headless `claude -p` once. Upsides:

- **Stable**: the worker owns its own poll loop — no dependency on the CLI channel-host, no stuck input box.
- **~20x lighter at idle** (~13MB vs ~280MB); no tmux, no cron daemon.
- **Always on the subscription** (the worker pops `ANTHROPIC_API_KEY` → no per-token cost).
- **Unlocks new features**: reminders (cron) + questions-to-Telegram.

**Breaking**: the layout changes to **a single `~/.claude` volume**; not backward-compatible with the v1.x `/data` volume. Shipped under a distinct tag **`:v2.2.0`** (it does NOT move `:latest`). Migration = a clean fresh install (see [Migration](#migration-from-v1x-to-v22-clean-install)). Rollback = the old v1.x image.

## Features

- **Bot-API worker** (`tg-worker.py`, pure stdlib): getUpdates long-poll → access.json gate (DM + groups) → react 👀 → `claude -p` (json) → sendMessage (chunk ≤3800, quote-reply in groups) → parse `[[react:X]]`; keeps a session per `chat_id` (`--resume`). No crashing loop; logs at `~/.claude/telegram/worker.log`.
- **Reminders**: a scheduler thread inside the worker scans `~/.claude/workspace/reminders/*.json` every ~45s and fires them when due (`mode:text` → send directly; `mode:claude` → run one `claude -p` turn and send the result). One-off or recurring daily/weekly, in the container timezone (Asia/Ho_Chi_Minh). CLI: `tg-reminder add|list|remove`.
- **Questions-to-Telegram**: when it needs the owner to decide, Claude SENDS the question as a reply and ENDS the turn; the owner's next message is the answer, and the session resumes via `--resume` (no AskUserQuestion, no terminal wait). Enforced by a rule in CLAUDE.md.
- **Safe-by-default permissions**: default `--allowedTools` = `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch` — **no free Bash** (safe for a group-exposed bot, hardened against prompt injection). Trusted personal bots widen it via `TG_WORKER_ALLOWED_TOOLS`. `PERMISSION_MODE`/`TG_WORKER_PERMISSION_MODE` map to a valid `--permission-mode` (`auto`→`acceptEdits`).
- **Baked base rules** (`default-CLAUDE.md` → `~/.claude/CLAUDE.md`): owner-only authority, prompt-injection detection + owner alert, information isolation across groups/DMs, destructive-op confirmation, a polite reply tone (overrides caveman), + worker rules (the final answer = the message sent to the owner) + questions-to-Telegram + reminder management.
- **Second-brain `.workspace/{rules,memory,events,status}`** created in the work dir; a SessionStart hook reloads it on every `claude -p` turn; optionally syncs with mempalace.
- **Baked `permissions`** in settings.json (deny reading secrets + destructive circuit-breakers; allow read-only git + `gh`).
- **`gh` CLI baked in** for GitHub operations. **TZ=Asia/Ho_Chi_Minh** + **UTF-8** (`LANG=C.UTF-8`).
- **Run as root** if needed: `-e BOT_USER=root -e BOT_HOME=/root`.
- **Ops tooling**: `bot-doctor` (checks the worker process / heartbeat freshness / permission + tools env / poller drain / login / reminders) + `tg-healthcheck` wired as HEALTHCHECK (worker alive + heartbeat fresh).
- **`:v2.2.0-playwright` variant** for bots that render UI + screenshot (built FROM base v2.2.0).
- **Role profiles** via `-e BOT_ROLE=<ba|planner|dev-fe|dev-be|tester|infra>` — layer a role-specific CLAUDE.md + settings + rules; unset = default.

## Quick start (published `:v2.2.0` image)

```bash
docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<from @BotFather> \
  -e OWNER_ID=<your Telegram user_id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<generate with: claude setup-token> \
  -v mybot-claude:/home/botuser/.claude \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
```

The worker is a headless daemon — **no `-it`/PTY needed** (unlike the old `--channels`). Auth uses the **subscription**: provide `CLAUDE_CODE_OAUTH_TOKEN` (recommended, generate once with `claude setup-token`), or log in interactively once (creds persist on the `~/.claude` volume):

```bash
docker exec -it -u botuser mybot claude auth login
docker exec -u botuser mybot claude auth status   # loggedIn:true
```

> ⚠️ `ANTHROPIC_API_KEY` is **intentionally ignored** by the worker (forces the subscription). Don't rely on it for auth.

Check / manage access:

```bash
docker exec -u botuser mybot bot-doctor
docker exec -u botuser mybot tg-access status
docker exec -u botuser mybot tg-access group add <group-id>
```
> ⚠️ Run `tg-access` (and `claude ...`) with **`-u botuser`** (the bot runs non-root; running as root lets root own files under `~/.claude`).

## See what the bot is doing

No more tmux. Follow the worker log + transcript:

```bash
docker logs --tail 40 mybot
docker exec -u botuser mybot sh -c 'tail -f /home/botuser/.claude/telegram/worker.log'
# per-turn claude -p transcript (JSONL):
docker exec -u botuser mybot sh -c 'tail -f /home/botuser/.claude/projects/*/*.jsonl'
```

## Build locally (development)

```bash
cp .env.example .env      # fill TELEGRAM_BOT_TOKEN + OWNER_ID + CLAUDE_CODE_OAUTH_TOKEN
docker compose up -d --build
docker exec -u botuser claude-tg-bot bot-doctor
```

## How it works

- **Base** `debian:bookworm-slim` + `bun` + the Claude Code CLI (native installer) + `python3` (the worker runtime). The telegram plugin is **not** installed.
- **`entrypoint.sh`** (runs as root): seeds the baked config into the `~/.claude` volume **on first run (clean install, NO copy-migration)**, seeds the token + `access.json` (`allowlist`, `allowFrom=[OWNER_ID]`), `unset ANTHROPIC_API_KEY`, then `exec gosu botuser python3 tg-worker.py`.
- **State on a single `~/.claude` volume**: `settings.json`/`CLAUDE.md`/`plugins/`/creds; `telegram/` (token, `access.json`, `sessions/`, `worker.log`); `workspace/` (cwd, `reminders/`, `.workspace/`).
- **Admin via `docker exec tg-access …`** (the host is the authenticated channel). Never change access from a Telegram message.

## Environment variables

| Var | Required | Notes |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | from @BotFather |
| `OWNER_ID` | ✅ | your Telegram user_id (single owner) |
| `CLAUDE_CODE_OAUTH_TOKEN` | recommended | headless auth (subscription) — generate with `claude setup-token`. Survives volume wipes. |
| `TG_WORKER_ALLOWED_TOOLS` | optional | comma-list for `--allowedTools`. Default `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch` (NO Bash). Widen for trusted personal bots. |
| `TG_WORKER_PERMISSION_MODE` | optional | the worker's `--permission-mode` (`default`/`acceptEdits`/`bypassPermissions`/`plan`). Unset → falls back to `PERMISSION_MODE`. |
| `PERMISSION_MODE` | optional | Alias: `auto`→`acceptEdits`, `manual`→`default`, empty→`acceptEdits`. |
| `MODEL` | optional | e.g. `sonnet` |
| `TZ` | optional | default `Asia/Ho_Chi_Minh` — the reminder scheduler fires in this timezone |
| `BOT_ROLE` | optional | `ba`/`planner`/`dev-fe`/`dev-be`/`tester`/`infra`; unset = default |
| `WORK_DIR` / `CLAUDE_CONFIG_DIR` / `TELEGRAM_STATE_DIR` | optional | default to the `~/.claude` layout |

## Reminders

The owner says "remind me at 8am tomorrow about the meeting" / "every Monday at 9am remind me to report" → Claude uses `tg-reminder` to create a reminder; the worker's scheduler fires it when due (container time).

```bash
tg-reminder add --chat <chat_id> --text "Drink water" --daily 15:00
tg-reminder add --chat <chat_id> --prompt "Summarize today's AI news" --weekly mon 09:00
tg-reminder add --chat <chat_id> --text "Team meeting" --at 2026-07-20T08:00
tg-reminder list
tg-reminder remove <id>
```
`--text` = send the literal string; `--prompt` = run one `claude -p` turn and send its output (dynamic content). Exactly one of `--text`/`--prompt`, exactly one schedule (`--at`/`--daily`/`--weekly`).

## Migration from v1.x to v2.2 (clean install)

v2.2 does NOT migrate the old `/data` volume (a copy would break the plugin paths). Rebuild each bot fresh:

```bash
# 1) create a new ~/.claude volume, run the container on :v2.2.0 (keep token + owner)
docker run -d --name <bot> --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<oauth> -e MODEL=sonnet \
  -v <bot>-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
# 2) re-add the mempalace MCP (per-bot token)
docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace \
  https://<domain>/mcp --header "Authorization: Bearer <token>"
docker restart <bot>
# 3) enable groups (the owner runs this in the terminal)
docker exec -u botuser <bot> tg-access group add <groupId>
```
Rollback = keep the old v1.x container/volume as-is (don't delete it until v2.2 runs cleanly).

## Gotchas

- **One token = one container.** Telegram allows a single `getUpdates` poller per token → two containers on the same token = 409 conflict.
- Changing the token requires a container restart (the worker reads the token once at boot).
- **Only mount `~/.claude`**, don't mount all of `/home/botuser` (it would shadow the `claude`/`bun` binaries in the image layer).
- **Group-exposed bots**: keep `TG_WORKER_ALLOWED_TOOLS` at the default (no Bash) for injection safety.
- Details + playbook: [`OPERATIONS.md`](./OPERATIONS.md).

## tg-access

```
tg-access status
tg-access allow <userId> | remove <userId>
tg-access policy <pairing|allowlist|disabled>
tg-access group add <groupId> [--allow id1,id2] [--no-mention]
tg-access group rm <groupId>
tg-access pair <code>
```

## Role profiles

Unset = default. Details: [`roles/README.md`](./roles/README.md).

| `BOT_ROLE` | Stage | What the bot does |
|---|---|---|
| `ba` | Define | Clarify requirements, user stories + acceptance criteria + a lightweight spec, UI prototype → preview; on sign-off → create a work item + sync KB + handoff. |
| `planner` | Planning | Break a parent item into area sub-tasks + estimate + link → the board → publish. |
| `dev-fe` | Build (FE) | Pick `area:frontend` → branch → code UI → PR `Closes #issue`. |
| `dev-be` | Build (BE) | Pick `area:backend` → branch → code API/DB + migration → PR. |
| `tester` | Tester/QA | From the release notes write test cases; receive a bug → cross-check the spec → publish + tag the lead. |
| `infra` | Ops | DevOps agent for the fleet: deploy/recreate/update bots, health/logs triage. Owner-only; confirm before destructive ops; never prints secrets. |

## `:v2.2.0-playwright` variant (render UI + screenshot)

Base v2.2.0 + real Node 20 + Chromium + Playwright (heavier by ~1GB, **amd64 only**). Give a bot Playwright:

```bash
# run/recreate the bot on the :v2.2.0-playwright image (same volume + env)
docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless
docker restart <bot>
# widen allowedTools so the bot can use the browser:
#   -e TG_WORKER_ALLOWED_TOOLS="mcp__mempalace,mcp__playwright,Read,Grep,Glob,WebFetch,WebSearch"
```
> ⚠️ Use `playwright-mcp --headless` (the baked binary), NOT `npx @playwright/mcp@latest`.

## License

[MIT](./LICENSE) © Edward Nguyen

## Contributors

Thanks to everyone who has contributed to this project 💙

[![Contributors](https://contrib.rocks/image?repo=trongnguyenbinh/claude-telegram-docker)](https://github.com/trongnguyenbinh/claude-telegram-docker/graphs/contributors)
