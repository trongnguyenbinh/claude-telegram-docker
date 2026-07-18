# claude-telegram-docker v2 — Default-Layout Redesign

> Status: **design for review** (brainstormed with Edward 2026-07-18, awaiting spec approval → writing-plans).
> Target image: **v2.0.0** (breaking layout change from the v1.x `/data` + `/working-directory` split).

## 1. Goal

Simplify the bot image to use Claude Code's **default profile layout** — everything under `~/.claude` (`/home/botuser/.claude`) — instead of the current custom `CLAUDE_CONFIG_DIR=/data/.claude` + `TELEGRAM_STATE_DIR=/data/telegram` + `WORK_DIR=/working-directory` split. One mounted volume holds all durable state. Fold in a **reliable Telegram channel-poller self-heal** so a bot can never again look healthy while being silently mute.

## 2. Why (problems with v1.x)

- **Custom-path complexity.** `CLAUDE_CONFIG_DIR` / `TELEGRAM_STATE_DIR` overrides are the "non-obvious part" of the setup: the `/telegram:*` skills hardcode the default paths and must be manually redirected; the Dockerfile needs `sed` path-rewrites to fix plugin `cache-miss` from stale absolute paths; two volumes + three custom env vars per bot. More moving parts = more edge cases.
- **Flaky channel poller (the incident that triggered this).** After a `docker run` recreate, the telegram plugin's channel-poller process (`bun … telegram … start`, which writes `…/telegram/bot.pid`) sometimes does not start. Symptom: no `bot.pid`, `getWebhookInfo.pending_update_count` stuck > 0, bot never replies — **even though `claude mcp list` reports the telegram MCP "✔ Connected"** (that's a throwaway probe, not the running poller). 1 of 4 bots (bot-toa-an) hit this on 2026-07-18; a `docker restart` fixed it. The existing `tg-watchdog` cron only heals a *different* case ("inbound message stuck in the input box → press Enter") and is blind to a **dead poller process**.

## 3. Locked decisions (brainstorm 2026-07-18)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Migrate existing bots' data | **NOT baked into the image.** The image is a **clean install only** — the entrypoint just seeds fresh defaults into an empty `~/.claude`, no legacy-layout detection. Migrating each existing bot's data from the old `/data` volumes into the new `~/.claude` layout is done **manually by the assistant during cutover** (documented ops procedure, §5). Keeps the image simple; migration complexity lives in an ops runbook run once per bot, not in every build. |
| 2 | What to mount | **One volume: `~/.claude`.** Everything durable lives inside it. Cannot mount the whole home (`/home/botuser`) — the `claude`/`bun` binaries live there in the image layer and a volume would shadow them. |
| 3 | Run user | **All `botuser` (non-root).** Drop the `BOT_USER=root` option entirely (root breaks `bypassPermissions`/auto mode; `bot-edward-tds` gets normalized to botuser). |
| 4 | Poller reliability | **Self-heal, internal, no external component:** startup self-check + improved `tg-watchdog` that also detects a **dead poller** and restarts the session. |
| 5 | khanh's PR #3 fix | **Keep.** `/etc/claude-code/managed-settings.json` (channelsEnabled + telegram allowlist) is required for `--channels` on admin-controlled Claude Teams. It lives at a system path, untouched by the `~/.claude` change — must not be deleted from the Dockerfile. |

## 4. New layout — everything under `~/.claude` (one volume)

```
/home/botuser/.claude/            ← single mounted volume  (bot-<name>-claude)
├── settings.json                 config + hooks + permissions (baked defaults seeded first-run)
├── .claude.json                  onboarding/bypass flags
├── .credentials.json             (only if interactive login; env token is primary — see §7)
├── plugins/                      baked marketplace + telegram/frontend/superpowers/caveman (seeded first-run)
├── channels/telegram/            telegram state — .env (bot token), access.json, approved/, bot.pid, inbox/
│                                 (was $TELEGRAM_STATE_DIR=/data/telegram)
├── projects/                     Claude Code session/conversation history — RESERVED, do not put repos here
└── workspace/                    bot working area (was $WORK_DIR)
    ├── .workspace/               operational memory (rules/, memory/, events/, status/) + MEMORY.md
    ├── CLAUDE.md                 per-bot work CLAUDE.md
    └── <cloned repos>/           dev bots clone here (persist in the same volume)
```

- **CWD of the `claude --channels` session** = `~/.claude/workspace` (so file ops + repo clones land there, inside the mounted volume).
- No more `CLAUDE_CONFIG_DIR` / `TELEGRAM_STATE_DIR` / `WORK_DIR` env overrides — Claude Code and the telegram plugin use their defaults, which now all resolve under `~/.claude`.
- Heavy/ephemeral scratch that shouldn't persist can still go to `/tmp`. A dev bot that wants an extra dedicated repo volume can add one — optional, not default.

## 5. Migration — CLEAN REBUILD + mempalace (NOT copy-volume)

> **Revised 2026-07-18 after the haeco pilot.** The first approach (copy the old `/data` volume into a fresh `~/.claude`) FAILED: the copied `plugins/installed_plugins.json` + `known_marketplaces.json` carry absolute cache paths to the old runtime `/data/.claude/plugins/...`, which don't exist in v2 (`~/.claude/plugins/...`), so the telegram plugin hits `cache-miss`, its channel poller never starts, and the bot is silently mute. The entrypoint's existing `sed` only rewrites `/opt/claude-stage`/`$CLAUDE_STAGE`, not `/data/.claude`. **Proven fix: don't migrate baked artifacts at all — do a CLEAN INSTALL** (Edward's call). A clean-install v2 bot has a correct plugin cache and a working poller (validated on haeco: `bot.pid` present, `getUpdates`→409 = actively long-polling, replied to a real DM).

Per bot, in order:
1. **Preserve memory to mempalace.** The bot's durable brain is the shared mempalace, not the local volume. Before deleting anything, make sure the bot has synced its `.workspace` memory up (bot does this itself; for a bot with no `.workspace` — e.g. haeco — there's nothing to sync).
2. **Capture the mempalace MCP config** from the old config so the clean bot reconnects to the shared brain: `docker inspect`/read `~/.claude/.claude.json` `.mcpServers.mempalace` (type `http`, `url` e.g. `https://mempalace.veasy.vn/mcp`, `headers.Authorization: Bearer <token>`) from the old volume — keep the token, never print it.
3. **Start v2 CLEAN:** stop+rename the old container to `-v1bak`, create a BRAND-NEW empty `bot-<name>-claude` volume, `docker run` v2 with only `-v bot-<name>-claude:/home/botuser/.claude` and the run-time env (`CLAUDE_CODE_OAUTH_TOKEN` — no re-login needed if still valid, `TELEGRAM_BOT_TOKEN`, `OWNER_ID`, `MODEL`, `PERMISSION_MODE=auto`). The entrypoint seeds fresh baked v2 plugins (correct paths) + seeds `access.json` (owner-only) + the token file.
4. **Re-add the mempalace MCP** into the new `~/.claude/.claude.json` `.mcpServers.mempalace` (jq-merge the captured entry), restart, confirm `claude mcp list` shows mempalace + telegram Connected.
5. **Verify healthy end-to-end** (§6 checklist incl. a real inbound→reply) before deleting `-v1bak` and the old volumes (keep them as cold backup for a while).

Fresh bots (brand new, no prior bot): identical to step 3 without the mempalace steps unless the bot should share the brain.

**Fresh bots (no migration):** start v2 with an empty `bot-<name>-claude` volume + `CLAUDE_CODE_OAUTH_TOKEN` env → entrypoint seeds baked defaults into `~/.claude`, then `docker exec claude setup-token` / access config as normal.

**Image responsibility = clean install only:** if `~/.claude` is empty → seed baked defaults; if populated → use as-is. No `/legacy/*` awareness, no `.migrated-v2` marker.

## 6. Poller self-heal (the reliability fix)

Two internal layers, no external orchestrator:

**(a) Startup self-check** — in entrypoint, after launching `claude --channels`: wait ~30s, then verify `~/.claude/channels/telegram/bot.pid` exists and `/proc/<pid>` is alive. If not, restart the tmux `claude` session once and re-check. Log the outcome.

**(b) `tg-watchdog` v2 (cron, every 1 min)** — extend the existing script to cover BOTH failure modes:
- *Poller alive but message stuck in input box* (current behavior): pending > 0 for 2 min while session idle → `tmux send-keys Enter`.
- *Poller DEAD* (new — the bot-toa-an case): `bot.pid` missing OR `/proc/<pid>` gone OR no `bun … telegram … start` process → **restart the `claude --channels` session** (kill the tmux `claude` window → container's `restart: unless-stopped` respawns it, OR respawn the session in place). This is the branch the v1 watchdog lacked.
- Update all paths from `$TELEGRAM_STATE_DIR=/data/telegram` → `~/.claude/channels/telegram`.

**(c) Docker HEALTHCHECK** — augment `tg-healthcheck` to also report unhealthy when the poller is dead/stuck, so `docker ps` surfaces a mute bot (defense-in-depth; the watchdog is the actual healer).

**Definition of "healthy" going forward (never declare done on PONG alone):** `bot.pid` present + `/proc/<pid>` alive **and** `pending_update_count == 0` **and** an observed inbound→reply round-trip.

## 7. Permission mode & token (carry-over rules, not new)

- Default `PERMISSION_MODE=auto` (classifier-gated). **Never `acceptEdits`** for channel bots — the reply/react tools aren't "edits", so acceptEdits hangs the session on approval and stalls the poller (root cause of the 2026-07-18 "no bot responds").
- Long-lived token via env `CLAUDE_CODE_OAUTH_TOKEN`. Entrypoint deletes any `~/.claude/.credentials.json` when the env token is set, so the env token is the single source of auth (a stale creds file silently overrides the env token).

## 8. Rollout

1. Build & publish image `v2.0.0` (multi-arch), keep `v1.x`/`:latest` pointing at v1 until v2 is proven.
2. **Pilot on ONE low-risk bot** (proposed: `bot-haeco`) — run the manual copy (§5) into a new `bot-haeco-claude` volume, start v2 with only that volume, verify: `~/.claude` populated correctly, poller `bot.pid` alive, `pending==0`, real inbound→reply works, `.workspace`/access preserved.
3. Kill-test: `docker rm`+`run` the pilot a few times to confirm the poller self-heal reliably brings it up (reproduce the flaky case, watch the watchdog fix it).
4. Roll the rest of the 122 fleet one by one, then 157 fleet, same recipe.
5. After each bot is stable on v2, drop its `/legacy/*` mounts (keep the old volumes as cold backup for a while).
6. Once the fleet is on v2, retag `:latest` → v2 and update README/CLAUDE.md/CHEATSHEET (the custom-path notes go away).

## 9. Non-goals / out of scope

- Not rotating Telegram bot tokens or Claude tokens (already done 2026-07-18).
- Not changing which bots exist or their access policies.
- Not adding new bot features — this is an infra/layout + reliability change only.
- prod-specific bots (if any) follow the same recipe later, not in the pilot.

## 10. Risks

- **Migration data loss** → mitigated: legacy volumes mounted read-only, copied not moved; kept as backup; per-bot verify before dropping.
- **Self-heal restart loop** (a genuinely broken bot restarting forever) → watchdog logs + a max-restart backoff; HEALTHCHECK surfaces it for a human.
- **Breaking khanh's channels-on-Teams fix** → explicitly preserved (§3.5), verified in the pilot's inbound→reply test.
