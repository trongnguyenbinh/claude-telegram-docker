# Changelog

## v2.3.0 — media handling (images, voice, documents) + baked voice MCP

Ships as `:v2.3.0` / `:v2.3.0-playwright`; does **not** move `:latest` (same gating
as v2.2 — a `v*` tag push publishes the version tag only). Builds on the v2.2 worker.

- **New — inbound media** (previously the worker silently skipped any non-text message):
  - **Images** — downloaded to `~/.claude/workspace/inbox/`; the prompt points Claude at
    the path and it views the image with the built-in **Read** tool (works with any bot;
    no extra tools needed).
  - **Documents** — downloaded to `inbox/`; Claude reads them with **Read**.
  - **Voice / audio** — transcribed to text via the Voice API (`POST /transcribe`) inside
    the worker; Claude receives the transcript. If no Voice API is configured, the bot
    replies once that voice isn't enabled and skips (never crashes the loop).
- **New — voice replies (`[[voice]]`)**: when the Voice API is configured, a reply that
  begins with `[[voice]]` is synthesized (`POST /speak`) and sent as a Telegram **voice
  bubble** (`sendVoice`); on any voice error it falls back to sending the text. Mirrors
  the `[[react:X]]` convention.
- **New — baked voice MCP**: the stdio `voice_mcp_proxy` (tools transcribe/speak/
  list_voices/voice_info) is vendored into the image and auto-registered for the bot by
  the entrypoint **when `VOICE_API_URL` + `VOICE_API_KEY` are set** — no manual
  `claude mcp add`. (To let Claude call those tools directly, add `mcp__voice` to
  `TG_WORKER_ALLOWED_TOOLS`; inbound transcription + `[[voice]]` output work without it.)
- **New — MarkdownV2 reply rendering**: the worker now sends replies as MarkdownV2, so
  Claude's ` ```code``` ` / `` `inline` `` become tap-to-copy and `**bold**`/`_italic_`
  render. A stdlib `to_markdownv2()` sanitizer tokenizes code vs non-code and escapes all
  MarkdownV2 specials in non-code regions; on a parse error it retries the message as
  **plain text** so a reply always gets through. This replaces the old v1 `tg-markdownv2-guard.py`
  hook (which hooked the now-removed telegram-plugin reply tool).
- **New env vars**: `VOICE_API_URL` (e.g. `https://voice.veasy.vn`) and `VOICE_API_KEY`
  (`vsk_...` per-bot key). Both must be set to enable voice STT/TTS; unset = voice off.
- **Image size**: base grows ≈ **+65 MB** (`python3-pip` ~45 MB + `mcp`/`httpx` deps ~22 MB +
  the tiny vendored proxy). The playwright variant inherits the base unchanged.

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

## v2.0.0 – v2.0.2 — `~/.claude` layout experiment (superseded by v2.2)

Moved all state to a single default `~/.claude` volume (dropping the `/data` custom
paths), botuser-only, with a three-layer poller self-heal (startup self-check that
restarts the session if `bot.pid` is absent, a `tg-watchdog` that restarts a dead
poller, and a healthcheck that reports unhealthy when the poller is down). v2.0.1/2
softened the self-check loop and moved the telegram state off the `channels/`
namespace to `~/.claude/telegram`. **These releases still ran `claude --channels`,
so they never fully beat the underlying poller flakiness** — superseded by the v2.2
worker transport. Migration was defined as a manual clean-install (a copy-migration
breaks the plugin cache paths). Built as version tags only; `:latest` stayed on v1.x.

## v1.7.3

- New Telegram hooks: a **markdownv2-format guard** and a **forgotten-reply guard**.
- Added a Contributors section (contrib.rocks avatar grid).

## v1.7.2

- Fix (PR #3, from @khanhn87): enable Telegram channel settings via a baked
  `managed-settings.json` (`channelsEnabled` + allowlist) so `--channels` works on
  admin-controlled Claude Teams.

## v1.7.1

- Removed the baked `rtk` tool and its PreToolUse hook.

## v1.7.0

- Added a generic **infra/ops** role profile.

## v1.6.0

- Generic English base image + role-instruction content.
- **Selectable `BOT_ROLE` profiles**: `ba` / `planner` / `dev-fe` / `dev-be` / `tester`.
- Default `effortLevel=high` in the staged settings (fresh volumes only).
- SessionStart hook auto-loads the `.workspace` context (no blank bot after recreate).
- Added `CONTRIBUTING.md`.
- Fix: install Chromium via `@playwright/mcp`'s own pinned `playwright-core`.
- `tg-watchdog` — cron auto-heal for a stalled `--channels` poller (removed in v2.2).
- `.env.example` recommends `PERMISSION_MODE=auto`.
