# claude-telegram-docker

[🇻🇳 Tiếng Việt](./README.md) · **🇬🇧 English**

Run a Claude-Code-powered Telegram bot as a single container. **1 image = 1 bot.**
Full design: [`SPEC.md`](./SPEC.md). Quick command table: [`CHEATSHEET.md`](./CHEATSHEET.md). Operations & troubleshooting: [`OPERATIONS.md`](./OPERATIONS.md).

## Features (v1.7.1)

- **Baked base rules** (`default-CLAUDE.md` → `/data/.claude/CLAUDE.md`, user-level memory; each bot's work-dir CLAUDE.md layers on top): owner-only authority, prompt-injection detection + owner alert, information isolation (never leak owner DM content, never carry context across groups/DMs), destructive-op confirmation, a polite reply tone that **overrides** caveman/terse mode for user-facing replies, and a reply self-check (did I actually call the reply tool?). Generic, English, project-neutral — supply project-specific glue in your own per-bot overlay.
- **Second-brain `.workspace/{rules,memory,events,status}`** skeleton created in the work dir on first run; conventions live in the base rules; optionally syncs with a shared memory MCP (e.g. mempalace).
- **Baked `permissions`** in settings.json: deny reading secrets (`.env`/`secrets`/keys, cwd-anchored so the bot's own `/data` token is not blocked) + destructive circuit-breakers; allow routine read-only git + `gh`.
- **`gh` CLI + `cron` baked in**: use `gh` for GitHub (auth via `-e GH_TOKEN=<PAT>` + `gh auth setup-git`; the github MCP plugin is broken — use gh); cron daemon started for scheduled reminders.
- **Auto Mode by default** (`PERMISSION_MODE=auto`, classifier-gated) → the bot doesn't prompt yet still blocks risky actions. (`acceptEdits` still prompts on every Bash command.)
- **UTF-8** (`LANG=C.UTF-8` + `tmux -u`) so non-ASCII text (e.g. Vietnamese, CJK) renders correctly in the attached session.
- **Run as root** (no image change): `-e BOT_USER=root -e BOT_HOME=/root`.
- **Ops tooling**: `bot-doctor` (`docker exec <bot> bot-doctor` — checks tmux session / permission mode / poller pending-drain / locale / base CLAUDE.md / .workspace / login + prints the fix) and `tg-healthcheck` wired as a Docker HEALTHCHECK (marks the container `unhealthy` if the tmux `claude` session dies). Playbook + gotchas in [`OPERATIONS.md`](./OPERATIONS.md).
- **`:playwright` variant** for bots that render UI + screenshot (see below).
- **Role profiles** via `-e BOT_ROLE=<ba|planner|dev-fe|dev-be|tester|infra>`: layer a role-specific CLAUDE.md + settings + rules on top of the base for each stage of the delivery workflow, plus a generic `infra` ops role for the fleet itself. Unset = unchanged default behavior (see below).
- **v1.7.1**: removed the baked `rtk` tool and its PreToolUse hook — `rtk` was the owner's personal host-only token optimizer, mistakenly baked into the image; its x86_64/glibc-2.39 binary fails on arm64 containers, spamming non-blocking PreToolUse hook errors on every Bash call. The `SessionStart` hook (`tg-session-context`) is unaffected and stays.

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
| `PERMISSION_MODE` | optional | `auto`/`default`/`acceptEdits`/`bypassPermissions`/`manual`/`plan`. **Unset = `auto`** — classifier-gated Auto Mode: auto-approves safe actions, blocks risky/production ones → runs unattended without hanging, still safe. Override when needed, e.g. `acceptEdits` (which still prompts on every Bash command). |
| `BOT_ROLE` | optional | Specialized role: `ba`/`planner`/`dev-fe`/`dev-be`/`tester`/`infra`. Seeds the role's CLAUDE.md + settings + rules (layered on the base) on first run. **Unset / `default` = unchanged default behavior.** See [Role profiles](#role-profiles) + `roles/README.md`. |
| `WORK_DIR` | optional | dir the bot's claude runs in (file ops land here, pre-trusted). Default `/working-directory/claude-telegram-bot`; persisted on the `botwork` volume. |
| `ANTHROPIC_API_KEY` | fallback | pay-per-token instead of your subscription |
| `MODEL` / `TZ` | optional | |

## Gotchas

- `claude --channels` is an interactive TUI → the container needs a PTY (`tty: true` + `stdin_open: true`, already set in compose; use `-it` with `docker run`).
- **One token = one container.** Telegram allows a single `getUpdates` poller per token; two containers on the same token → 409 conflict.
- Changing the token requires a container restart (read once at boot).
- **Poller stall after a recreate:** verify `pending_update_count` drains to 0 (use `bot-doctor`); if the poller stalls (a msg stuck in the input box) → `docker restart <bot>` clears it.
- **The baked `permissions` block only seeds FRESH volumes** — existing bots need a manual merge into `/data/.claude/settings.json`, then restart.
- **An extra docker network (e.g. `db-shared`) is NOT preserved by a plain recreate** → add `--network <net>` on the `docker run`.
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

A bot can boot into a **role** in the AI delivery workflow (Define/BA → Planning → Build → Tester/QA) via `BOT_ROLE`. Each role seeds a role-specific "how I work" CLAUDE.md + `settings-fragment` + rules that **layer on top of** the base CLAUDE.md (security, info-isolation, `.workspace`, reply tone stay the shared base). The role rules are generic English craft standards — layer any project-specific glue (your issue tracker, channels, conventions) in a per-bot overlay.

| `BOT_ROLE` | Stage | What the bot does |
|---|---|---|
| `ba` | Define | Elicit + clarify requirements, write user stories + acceptance criteria + a lightweight spec, build a UI prototype → preview deploy; on sign-off → create a tracked work item + sync the shared knowledge base + publish the handoff. |
| `planner` | Planning | Break a parent item into area sub-tasks (`area:frontend/backend/db/infra/qa`) + estimate + link to parent → the board → publish + @mention. |
| `dev-fe` | Build (FE) | Pick an `area:frontend` sub-task → branch → code UI → PR `Closes #issue`; gate-aware (quality + security); frontend-design + preview deploy + Playwright. |
| `dev-be` | Build (BE) | Pick an `area:backend` sub-task → branch → code API/DB + migration → PR `Closes #issue`; migration/db + gate awareness. |
| `tester` | Tester/QA | From the release notes write test guidance + test cases; receive a bug report from the test site → cross-check the spec → if it looks like a real bug, publish to the channel + tag the lead. |
| `infra` | Ops (cross-cutting) | Generic DevOps/infra-ops agent for the bot fleet + shared services: deploy/recreate/update bots (env-preserving), health/logs triage, service config, inventory → shared memory. Owner-only; mandatory typed confirmation before any destructive op; never prints secrets; audits every action. |

**Unset / empty / `default` = unchanged default behavior** (existing bots are unaffected). An unknown role → the entrypoint logs a note and runs as default.

```bash
# example: launch a BA bot
docker run -d --name mybot-ba \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> -e BOT_ROLE=ba \
  -v mybot-ba-data:/data --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
```

> The role CLAUDE.md is seeded only when the work-dir has no CLAUDE.md yet (never clobbers a per-bot file). The `settings-fragment` merge is a union (safe to re-run). To add a new role, see [`roles/README.md`](./roles/README.md).

## `:playwright` variant (render UI + screenshot)

For bots that need a browser (build UI, take screenshots). This variant = base image + real Node 20 + Chromium + Playwright (heavier by ~1GB, **amd64 only**). Built from `Dockerfile.playwright`, published as the `:playwright` tag.

Give a bot Playwright:

```bash
# 1) Run / recreate the bot on the :playwright image (same volumes + env as usual)
ghcr.io/trongnguyenbinh/claude-telegram-docker:playwright

# 2) Wire the Playwright MCP using the BAKED binary (NOT npx — npx re-downloads the package on every start → connection failure)
docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless
docker restart <bot>
```

> ⚠️ Use `playwright-mcp --headless` (the baked global binary), NOT `npx @playwright/mcp@latest` (re-downloads on every boot → MCP "Failed to connect" + can stall the poller).

## License

[MIT](./LICENSE) © Edward Nguyen
