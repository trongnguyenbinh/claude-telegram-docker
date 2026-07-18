# claude-telegram-docker v2 (default ~/.claude layout) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the bot image so all durable state lives under the default `~/.claude` (one volume), the image is a clean install (no baked migration), every bot runs as `botuser`, and the Telegram channel poller self-heals when it dies.

**Architecture:** A Debian-slim image bakes claude + bun + plugins into a staging dir; the entrypoint seeds those defaults into an empty `~/.claude`, sets the session CWD to `~/.claude/workspace`, launches `claude --channels` as botuser in tmux, and a cron watchdog + startup check keep the poller alive. Migration of existing v1 bots is a manual ops copy (spec §5), NOT in the image.

**Tech Stack:** Docker, bash (entrypoint + scripts), jq, tmux, cron, GitHub Actions (multi-arch publish).

## Global Constraints

- Base image, binaries, and plugin baking stay as-is; this is a **layout + reliability** change, not a rewrite.
- **Never** run claude as root — `botuser` (uid 1000) only. Drop the `BOT_USER=root` path.
- **Never** default `PERMISSION_MODE` to anything but `auto` for channel bots (acceptEdits hangs the reply tool → poller stall).
- **Keep** `/etc/claude-code/managed-settings.json` (`channelsEnabled:true` + telegram allowlist) — khanh PR #3, required for `--channels` on admin-controlled Claude Teams.
- Env token `CLAUDE_CODE_OAUTH_TOKEN` is primary auth; a stale `~/.claude/.credentials.json` overrides it → entrypoint removes it when the env token is set.
- Default paths, no custom env: `CLAUDE_CONFIG_DIR=$HOME/.claude`, telegram state `$HOME/.claude/channels/telegram`, work `$HOME/.claude/workspace`.
- Telegram bot token (`TELEGRAM_BOT_TOKEN`) and `OWNER_ID` remain required run-time env.
- "Healthy" = `channels/telegram/bot.pid` present + `/proc/<pid>` alive + `getWebhookInfo.pending_update_count == 0` + an observed inbound→reply. Never claim done on PONG alone.

---

### Task 1: Dockerfile — switch to default `~/.claude` layout

**Files:**
- Modify: `Dockerfile` (the trailing runtime-config block near lines 104-145)

**Interfaces:**
- Produces: image with `VOLUME /home/botuser/.claude`, NO `CLAUDE_CONFIG_DIR`/`TELEGRAM_STATE_DIR` env, staging at `$CLAUDE_STAGE`, managed-settings intact.

- [ ] **Step 1: Remove the custom config/state env + repoint the VOLUME.**

Find the runtime-config block (currently):
```dockerfile
# --- runtime config: config + state live on the volume so login + access persist ---
ENV CLAUDE_CONFIG_DIR=/data/.claude \
    TELEGRAM_STATE_DIR=/data/telegram
VOLUME /data
```
Replace with:
```dockerfile
# --- runtime config: everything durable lives under the default ~/.claude (one volume).
# No CLAUDE_CONFIG_DIR / TELEGRAM_STATE_DIR overrides — Claude Code + the telegram
# plugin use their defaults, which resolve under /home/botuser/.claude. ---
VOLUME /home/botuser/.claude
```

- [ ] **Step 2: Confirm the managed-settings block is untouched.**

Verify these lines still exist (khanh PR #3 — do NOT remove):
```dockerfile
RUN mkdir -p /etc/claude-code \
 && printf '%s\n' '{"channelsEnabled":true,"allowedChannelPlugins":[{"marketplace":"claude-plugins-official","plugin":"telegram"}]}' > /etc/claude-code/managed-settings.json \
 && jq -e '.channelsEnabled == true and (.allowedChannelPlugins | index({"marketplace":"claude-plugins-official","plugin":"telegram"}))' /etc/claude-code/managed-settings.json >/dev/null
```
Run: `grep -c managed-settings.json Dockerfile` → Expected: `2`

- [ ] **Step 3: Verify no stray `/data` references remain in the Dockerfile.**

Run: `grep -n '/data' Dockerfile` → Expected: no output (empty).

- [ ] **Step 4: Commit.**
```bash
git add Dockerfile
git commit -m "feat(image): default ~/.claude layout — drop /data custom paths (v2)"
```

---

### Task 2: entrypoint.sh — default paths, clean-install seed, botuser-only

**Files:**
- Modify: `entrypoint.sh` (header vars lines 12-21; chown block lines 150-155; the launch block lines 186-201)

**Interfaces:**
- Consumes: `CLAUDE_STAGE` (baked defaults), run-time env `TELEGRAM_BOT_TOKEN`, `OWNER_ID`, `CLAUDE_CODE_OAUTH_TOKEN`, `PERMISSION_MODE`, `MODEL`.
- Produces: a running `claude --channels` session as botuser, CWD `$HOME/.claude/workspace`, state under `$HOME/.claude`.

- [ ] **Step 1: Rewrite the path header (lines 12-21).**

Replace:
```bash
BOT_USER="${BOT_USER:-botuser}"
BOT_HOME="${BOT_HOME:-/home/botuser}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/data/.claude}"
TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-/data/telegram}"
CLAUDE_STAGE="${CLAUDE_STAGE:-$BOT_HOME/claude-stage}"
# Working directory the bot's claude session runs in (file ops land here).
WORK_DIR="${WORK_DIR:-/working-directory/claude-telegram-bot}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/approved" "$WORK_DIR"
```
With (botuser hardcoded, all paths under ~/.claude):
```bash
# v2: single-volume default layout. Everything durable lives under ~/.claude.
BOT_USER="botuser"                 # non-root only (auto/bypass requires it); root option dropped
BOT_HOME="/home/botuser"
CLAUDE_CONFIG_DIR="$BOT_HOME/.claude"
TELEGRAM_STATE_DIR="$CLAUDE_CONFIG_DIR/channels/telegram"   # == telegram plugin default
WORK_DIR="$CLAUDE_CONFIG_DIR/workspace"                     # session CWD; .workspace + repo clones
CLAUDE_STAGE="${CLAUDE_STAGE:-$BOT_HOME/claude-stage}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/approved" "$WORK_DIR"
```

- [ ] **Step 2: Delete a stale creds file when an env token is present (insert right after the `mkdir -p` line above).**
```bash
# v2: env token is the single source of auth. A leftover .credentials.json (from a
# past interactive login) OVERRIDES the env token and silently 401s when it expires.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"
fi
```

- [ ] **Step 3: Fix the chown block (lines ~150-155) — only ~/.claude now.**

Replace:
```bash
chown -R "$BOT_USER":"$BOT_USER" /data 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" /working-directory 2>/dev/null || true
chown -R "$BOT_USER":"$BOT_USER" "$WORK_DIR" 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" "$BOT_HOME/.claude.json" 2>/dev/null || true
```
With:
```bash
chown -R "$BOT_USER":"$BOT_USER" "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" "$BOT_HOME/.claude.json" 2>/dev/null || true
```

- [ ] **Step 4: Force auto as the permission-mode default (line 175).**

Replace `PERMISSION_MODE="${PERMISSION_MODE:-auto}"` with:
```bash
# auto only for channel bots — acceptEdits hangs the reply tool and stalls the poller.
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
case "$PERMISSION_MODE" in acceptEdits) echo "[entrypoint] WARN PERMISSION_MODE=acceptEdits stalls channel bots -> forcing auto"; PERMISSION_MODE=auto;; esac
```

- [ ] **Step 5: Build the image and boot a throwaway fresh container (no token) to confirm the layout seeds.**
```bash
docker build -t ctd:v2test .
docker run -d --name v2seed -e TELEGRAM_BOT_TOKEN=x -e OWNER_ID=1 ctd:v2test
sleep 8
docker exec v2seed sh -c 'ls -d /home/botuser/.claude/plugins /home/botuser/.claude/channels/telegram /home/botuser/.claude/workspace && echo LAYOUT_OK'
docker rm -f v2seed
```
Expected: prints the three dirs + `LAYOUT_OK`. (Bot won't fully run without a real token — we only assert the layout seeded.)

- [ ] **Step 6: Commit.**
```bash
git add entrypoint.sh
git commit -m "feat(entrypoint): default ~/.claude layout, botuser-only, auto-mode guard, drop stale creds (v2)"
```

---

### Task 3: entrypoint.sh — startup poller self-check

**Files:**
- Modify: `entrypoint.sh` (the launch block, replacing the final `exec … tmux new-session` with a background launch + verify)

**Interfaces:**
- Consumes: `$CLAUDE_CMD`, `$WORK_DIR`, `$TELEGRAM_STATE_DIR/bot.pid`.
- Produces: a claude session whose poller is verified up within ~40s, restarted once if not.

- [ ] **Step 1: Replace the final exec (lines ~200-201).**

Replace:
```bash
exec gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" WORK_DIR="$WORK_DIR" \
  tmux -u new-session -s claude "$CLAUDE_CMD"
```
With:
```bash
launch_session() {
  gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" WORK_DIR="$WORK_DIR" \
    tmux -u new-session -d -s claude "$CLAUDE_CMD"
}
poller_up() {
  local pid; pid="$(cat "$TELEGRAM_STATE_DIR/bot.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && [ -d "/proc/$pid" ]
}
launch_session
# Startup self-check: give claude --channels ~40s to bring the poller up; if bot.pid
# never appears (the flaky non-start), restart the session once.
for _ in $(seq 1 8); do sleep 5; poller_up && break; done
if ! poller_up; then
  echo "[entrypoint] poller did not come up in ~40s -> restarting session once"
  gosu "$BOT_USER" env HOME="$BOT_HOME" tmux kill-session -t claude 2>/dev/null || true
  sleep 2; launch_session
fi
echo "[entrypoint] claude --channels session live; tailing to keep PID 1 alive"
# Keep PID 1 alive + tie container lifecycle to the tmux session (exit -> container exits -> restart policy).
exec gosu "$BOT_USER" env HOME="$BOT_HOME" tmux -u attach -t claude
```

- [ ] **Step 2: Rebuild + run with a REAL bot (needs a token) — deferred to the pilot (Task 6).** Mark this step done once Task 6's pilot confirms `bot.pid` appears within the startup window.

- [ ] **Step 3: Commit.**
```bash
git add entrypoint.sh
git commit -m "feat(entrypoint): startup poller self-check — restart session if bot.pid absent (v2)"
```

---

### Task 4: tg-watchdog — heal a DEAD poller, not just a stuck input box

**Files:**
- Modify: `scripts/tg-watchdog`
- Modify: `entrypoint.sh` (the `/etc/default/tg-watchdog` writer, line ~180) + `Dockerfile` cron line if it hardcodes a path

**Interfaces:**
- Consumes: `$TELEGRAM_STATE_DIR` (now `~/.claude/channels/telegram`), `bot.pid`, bot token from `$STATE_DIR/.env`.
- Produces: a watchdog that restarts the session when the poller process is dead.

- [ ] **Step 1: Point the watchdog's state dir at the new default.** In `entrypoint.sh`, the writer:
```bash
printf 'BOT_USER=%s\nTELEGRAM_STATE_DIR=%s\n' "$BOT_USER" "$TELEGRAM_STATE_DIR" > /etc/default/tg-watchdog 2>/dev/null || true
```
is already dynamic — confirm it now emits `TELEGRAM_STATE_DIR=/home/botuser/.claude/channels/telegram`. In `scripts/tg-watchdog`, change the fallback default:
```bash
STATE_DIR="${TELEGRAM_STATE_DIR:-/home/botuser/.claude/channels/telegram}"
```

- [ ] **Step 2: Add the dead-poller branch.** In `scripts/tg-watchdog`, right after `TOK=…; [ -z "$TOK" ] && exit 0`, insert:
```bash
# v2: a DEAD poller (bun channels server never started / crashed) shows no live
# bot.pid. Sending Enter can't help — the poller isn't running. Restart the session.
PID="$(cat "$STATE_DIR/bot.pid" 2>/dev/null || true)"
if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
  if g tmux has-session -t claude 2>/dev/null; then
    echo "$(date -u +%FT%TZ) tg-watchdog: poller DEAD (bot.pid='$PID') -> restarting claude session" >> "$LOG"
    g tmux kill-session -t claude 2>/dev/null || true
  fi
  rm -f "$FLAG"
  exit 0
fi
```
(When the session is killed, the entrypoint's `tmux attach` exits → PID 1 exits → `restart: unless-stopped` respawns the container, which re-runs the startup self-check. The existing pending-stuck "send Enter" logic below stays for the other failure mode.)

- [ ] **Step 3: Static-check the script.**
Run: `bash -n scripts/tg-watchdog && echo SYNTAX_OK` → Expected: `SYNTAX_OK`

- [ ] **Step 4: Commit.**
```bash
git add scripts/tg-watchdog entrypoint.sh
git commit -m "feat(tg-watchdog): restart session on DEAD poller + new ~/.claude state path (v2)"
```

---

### Task 5: tg-healthcheck — report unhealthy when the poller is down

**Files:**
- Modify: `scripts/tg-healthcheck`

**Interfaces:**
- Consumes: tmux `claude` session liveness, `$STATE_DIR/bot.pid`.
- Produces: non-zero exit (unhealthy) when the poller is dead, so `docker ps` surfaces a mute bot.

- [ ] **Step 1: Read the current check.** Run: `cat scripts/tg-healthcheck`. It currently asserts the tmux `claude` session is alive.

- [ ] **Step 2: Add a poller-liveness assertion** (append before the final success exit), using the same `STATE_DIR` resolution as the watchdog:
```bash
STATE_DIR="${TELEGRAM_STATE_DIR:-/home/botuser/.claude/channels/telegram}"
PID="$(cat "$STATE_DIR/bot.pid" 2>/dev/null || true)"
if [ -z "$PID" ] || [ ! -d "/proc/$PID" ]; then
  echo "unhealthy: telegram poller not running (bot.pid='$PID')"
  exit 1
fi
```

- [ ] **Step 3: Static-check.** Run: `bash -n scripts/tg-healthcheck && echo SYNTAX_OK` → Expected: `SYNTAX_OK`

- [ ] **Step 4: Commit.**
```bash
git add scripts/tg-healthcheck
git commit -m "feat(tg-healthcheck): mark unhealthy when poller down (v2)"
```

---

### Task 6: Build v2 + PILOT on bot-haeco (manual migration + end-to-end verify)

**Files:** none (ops task on VPS 122). SSH: `~/.ssh/id_ed25519_cocandy_root` → `root@116.118.47.122`.

**Interfaces:**
- Consumes: the v2 image, the existing `bot-haeco-data` + `bot-haeco-work` volumes.
- Produces: bot-haeco running on v2 with a fresh `bot-haeco-claude` volume, verified healthy.

- [ ] **Step 1: Publish the v2 image.** Tag `v2.0.0` (do NOT move `:latest` yet — keep it on v1 for the rest of the fleet). Push via the existing `docker-publish.yml` (git tag `v2.0.0`) or a manual multi-arch build. Pull it on 122: `docker pull ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.0.0`.

- [ ] **Step 2: Manual migration copy (spec §5)** into a new `bot-haeco-claude` volume:
```bash
docker run --rm \
  -v bot-haeco-data:/legacy/data:ro \
  -v bot-haeco-work:/legacy/work:ro \
  -v bot-haeco-claude:/newclaude \
  alpine sh -c '
    mkdir -p /newclaude/channels /newclaude/workspace
    cp -a /legacy/data/.claude/.   /newclaude/
    cp -a /legacy/data/telegram    /newclaude/channels/telegram
    cp -a /legacy/work/.workspace  /newclaude/workspace/.workspace 2>/dev/null || true
    [ -f /legacy/work/CLAUDE.md ] && cp -a /legacy/work/CLAUDE.md /newclaude/workspace/CLAUDE.md
    chown -R 1000:1000 /newclaude
    echo MIGRATED'
```
Expected: prints `MIGRATED`.

- [ ] **Step 3: Start bot-haeco on v2** (only the new volume; preserve its env token + auto mode). Dump the current env, keep `CLAUDE_CODE_OAUTH_TOKEN`/`PERMISSION_MODE=auto`/`MODEL`, drop the old volume mounts:
```bash
docker inspect bot-haeco --format '{{json .Config.Env}}' | python3 -c "import json,sys; [print(l) for l in json.load(sys.stdin) if l.split('=')[0] in ('CLAUDE_CODE_OAUTH_TOKEN','TELEGRAM_BOT_TOKEN','OWNER_ID','MODEL','PERMISSION_MODE')]" > /root/.haeco.env
# ensure auto mode:
grep -q '^PERMISSION_MODE=' /root/.haeco.env || echo 'PERMISSION_MODE=auto' >> /root/.haeco.env
docker stop bot-haeco && docker rename bot-haeco bot-haeco-v1bak
docker run -d --name bot-haeco --restart unless-stopped --tty \
  --env-file /root/.haeco.env \
  -v bot-haeco-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.0.0
rm -f /root/.haeco.env
```

- [ ] **Step 4: Verify healthy end-to-end** (the real definition of done):
```bash
sleep 45
docker ps --filter name=bot-haeco --format '{{.Status}}'                       # healthy
docker exec bot-haeco sh -c 'cat /home/botuser/.claude/channels/telegram/bot.pid'  # a pid
docker exec bot-haeco sh -c 'PID=$(cat /home/botuser/.claude/channels/telegram/bot.pid); [ -d /proc/$PID ] && echo POLLER_ALIVE'
TOK=$(docker exec bot-haeco sh -c 'cat /home/botuser/.claude/channels/telegram/.env' | sed -n 's/^TELEGRAM_BOT_TOKEN=//p')
curl -s "https://api.telegram.org/bot$TOK/getWebhookInfo" | python3 -c "import json,sys; print('pending', json.load(sys.stdin)['result']['pending_update_count'])"
```
Expected: `healthy`, a pid, `POLLER_ALIVE`, `pending 0`. THEN ask Edward to send a real DM to @haeco_agent_bot and confirm the reply arrives (inbound→reply round-trip). Do not proceed until confirmed.

- [ ] **Step 5: Kill-test the self-heal.** `docker restart bot-haeco` twice; after each, re-run Step 4's `POLLER_ALIVE` + `pending` check within ~60s. Confirm the poller reliably comes up (startup self-check / watchdog). If it stays dead, STOP and debug before rolling the fleet.

- [ ] **Step 6: Once confirmed, remove the v1 backup container (keep the old volumes as cold backup).**
```bash
docker rm bot-haeco-v1bak
```

---

### Task 7: Roll the rest of the fleet + docs

**Files:**
- Modify: `README.md`, `README.en.md`, `CLAUDE.md`, `CHEATSHEET.md`, `SPEC.md` (remove the `/data` + `CLAUDE_CONFIG_DIR`/`TELEGRAM_STATE_DIR` custom-path notes; document the `~/.claude` single-volume layout + the manual migration runbook).

- [ ] **Step 1: Roll each remaining bot** (122: toa-an, claude-support[playwright variant → build/publish a `v2.0.0-playwright` too], edward-tds; then 157: dev/qc/trainer; bot-infra) one at a time with the Task 6 recipe (manual copy → start v2 → verify healthy end-to-end → drop v1 backup). Do them serially, confirm each before the next.

- [ ] **Step 2: Update the docs** to the v2 layout: single `~/.claude` volume, `botuser` only, auto mode, the manual migration procedure, and the self-heal behavior. Remove the "State path override (the non-obvious part)" caveats — they no longer apply.

- [ ] **Step 3: Retag `:latest` → v2** once the whole fleet is verified on v2. Publish `:latest` = v2.0.0 digest.

- [ ] **Step 4: Commit docs.**
```bash
git add README.md README.en.md CLAUDE.md CHEATSHEET.md SPEC.md
git commit -m "docs: v2 default ~/.claude layout + manual migration runbook"
```

---

## Self-Review

- **Spec coverage:** §3 decisions → Task1 (layout+managed-settings), Task2 (botuser/auto/creds), Task5-6 (self-heal), Task6 (manual migration), Task7 (rollout/docs). §4 layout → Task2. §5 manual migration → Task6 Step2. §6 self-heal → Task3+4+5. §7 permission/token → Task2 Step2+4. §8 rollout → Task6+7. All covered.
- **Placeholder scan:** no TBD/TODO; every code step shows the actual edit. Task3 Step2 defers runtime verification to the pilot (Task6) — explicitly, not a placeholder.
- **Type/path consistency:** `TELEGRAM_STATE_DIR=$HOME/.claude/channels/telegram` used identically in entrypoint (Task2), watchdog (Task4), healthcheck (Task5), and verify commands (Task6). `bot.pid` path consistent throughout.
