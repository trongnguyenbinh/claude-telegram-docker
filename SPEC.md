# SPEC — Claude Telegram Bot, packaged as Docker ("bot-in-a-box")

> Status: **spec for review** (not yet coded). Goal: package an entire Claude-Telegram bot into a single Docker image runnable via `docker run` / `docker compose up`, pass the token through an environment variable, and administer it via `docker exec`.
> Updated: 2026-06-26. **Added §v2.2 (2026-07-19).**

---

## §v2.2 — Worker transport (replaces `--channels`)

> As of v2.2, the transport layer below (§2/§6/§7, about `claude --channels` + the telegram plugin)
> is **replaced** by the worker model. The access/security/state sections are still conceptually correct
> but change paths. Full design + finalized decisions: `docs/superpowers/specs/2026-07-19-v2.2-worker-image-design.md`.

**Why the change:** the `claude --channels` poller (Claude Code 2.1.214 + telegram plugin) is
unstable — it often fails to start on container start/restart (no `bot.pid`,
`pending_update_count` stuck) even though `mcp list` reports "Connected". Verified the bug is in Claude Code's
CLI channel host, not the image. Watchdog/retry doesn't cure it.

**v2.2 architecture:**
- Main process = **Python worker** (`scripts/tg-worker.py`, pure stdlib): long-poll
  `getUpdates` (timeout 50) → gate on `access.json` (DM `allowFrom`; group `requireMention`/
  `allowFrom`) → react 👀 → invoke headless `claude -p` (`--output-format json`, `--model`,
  mapped `--permission-mode`, `--allowedTools`, `--append-system-prompt` react-hint,
  `--resume` per `chat_id`) → parse `[[react:X]]` → `sendMessage` (chunk ≤3800, quote-reply
  in groups). No tmux, no telegram plugin, no cron.
- **Subscription auth**: the worker does `env.pop(ANTHROPIC_API_KEY)` → it always uses
  the `CLAUDE_CODE_OAUTH_TOKEN`/creds on the volume, not per-token billing.
- **Single-volume `~/.claude` layout** (`/home/botuser/.claude`): config + `plugins/` + creds;
  `telegram/` (`.env`, `access.json`, `sessions/`, `offset`, `worker.log`, `worker.heartbeat`);
  `workspace/` (cwd, `reminders/`, `.workspace/`). ONLY mount `~/.claude` (mounting all of
  `/home/botuser` would shadow the claude/bun binaries in the image layer).
- **Permissions**: `--allowedTools` defaults to `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch`
  (NO free-form Bash — injection-safe for a bot in groups); widen via `TG_WORKER_ALLOWED_TOOLS`.
  `PERMISSION_MODE`/`TG_WORKER_PERMISSION_MODE` map to valid `--permission-mode` values
  (`default|acceptEdits|bypassPermissions|plan`; `auto`→`acceptEdits`, `manual`→`default`).
- **Reminders**: a scheduler thread in the worker scans
  `~/.claude/workspace/reminders/*.json` every ~45s; `mode:text` → `sendMessage`, `mode:claude`
  → run one `claude -p` turn then send its output; one-off (`when` ISO) or recurring `daily`/`weekly`
  (in the container TZ). CLI `tg-reminder add|list|remove` + a rule in CLAUDE.md.
- **Ask-back over Telegram (behavioral)**: when owner input is needed → send the question as a reply then end
  the turn; the owner's next message is the answer, the session continues via `--resume`. No
  AskUserQuestion, no waiting on a terminal. Enforced by a CLAUDE.md rule.
- **Entrypoint (root → botuser)**: seed `~/.claude` from staged defaults on first run (clean install,
  NO copy-migrate of a v1 volume), `unset ANTHROPIC_API_KEY`, `exec gosu botuser python3 tg-worker.py`.
- **Healthcheck**: worker alive (pgrep) + fresh heartbeat. Drop the tmux check; drop `tg-watchdog`.
- **Drop `/etc/claude-code/managed-settings.json`** (it only gated `--channels`, now unused).
- **Image/CI**: ship a separate tag `:v2.2.0` (breaking) + `:v2.2.0-playwright` built FROM the tagged
  base; **do NOT touch `:latest`** (so recreating a v1 bot on `:latest` doesn't jump to v2.2 by accident).
- **Migration**: clean install of each bot (fresh `~/.claude` volume + token + access + mempalace).
  Rollback = the old v1.x image.

---

## 1. Goal

A single image that, once started, immediately gives you a Telegram bot operated by Claude Code (receive DM/group → Claude processes → replies), **with no step-by-step manual install**. Each container = 1 independent bot (its own token) → cloning multiple bots = running multiple containers.

Non-goals (out of scope for v1): admin web UI, multi-bot orchestrator, auto-update, horizontal scaling across nodes.

---

## 2. Overall architecture

```
docker run / compose
   │  env: TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY, OWNER_ID, [TZ, MODEL, AUTO_PAIR]
   ▼
┌─────────────────────────── container ───────────────────────────┐
│ entrypoint.sh                                                     │
│   1. validate env (token, api key, owner required)              │
│   2. seed state into the volume if missing:                     │
│        - $STATE/.env          (TELEGRAM_BOT_TOKEN)               │
│        - $STATE/access.json   (policy=allowlist, allowFrom=[OWNER])│
│   3. exec claude --channels plugin:telegram@claude-plugins-official│
│         (foreground, needs a PTY)                                │
│                                                                  │
│  ~/.claude/plugins  ← telegram plugin BAKED into the image      │
│  $STATE (volume)    ← .env, access.json, approved/, bot.pid      │
└──────────────────────────────────────────────────────────────────┘
        ▲ docker exec bot tg-access group add <id>   (administration)
```

---

## 3. Image components (Dockerfile)

- **Base:** `node:22-bookworm-slim` (has node + npm).
- **bun:** installed via `curl -fsSL https://bun.sh/install | bash` (or the official bun image if leaner — decide at POC).
- **Claude Code CLI:** `npm i -g @anthropic-ai/claude-code`.
- **Telegram plugin: BAKE at build time** (see §7 — this is the part that needs careful verification).
- **tg-access CLI:** copy `scripts/tg-access` into `/usr/local/bin` (chmod +x).
- **entrypoint.sh:** copy + chmod +x, set as `ENTRYPOINT`.
- User: run as a non-root user (e.g. `node`) for safety; `$STATE` + `~/.claude` owned by that user.
- Install `git`, `curl`, `ca-certificates`, `tini` (init reaper) alongside.

---

## 4. Environment variables (input at runtime)

| Variable | Required | Meaning |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | Bot token from @BotFather |
| `OWNER_ID` | ✅ | Telegram user_id of the bot owner (1 owner — decision §13) → preseed the allowlist |
| `CLAUDE_CONFIG_DIR` | (default `/data/.claude`) | Claude config + credentials → point at the volume to persist login (§5, §7) |
| `TELEGRAM_STATE_DIR` | (default `/data/telegram`) | Telegram plugin state (token/access), pointed at the volume |
| `ANTHROPIC_API_KEY` | ⬜ fallback | Only used if paste-code login isn't feasible (§5) |
| `MODEL` | ⬜ | Default model (e.g. `claude-sonnet-4-6`) if you want to force one |
| `TZ` | ⬜ | Timezone (logs/time) |
| `MENTION_PATTERNS` | ⬜ | @mention pattern if different from the bot name |

> `AUTO_PAIR` was DROPPED from v1 (decision §13: preseed-owner only). It can be added back later if automatic pairing is needed.

Secrets (token, api key) are **never** written into the image; they are passed only at runtime via env / compose / docker secret.

---

## 5. Claude auth — DECISION: paste-code login (Edward 2026-06-26)

**Primary = log into a Claude account via `docker exec`** (using Edward's subscription, no separate API key needed). The CORRECT command (verified at POC — NOT `/login`, which is a slash command in the interactive UI):

```
docker exec -it <bot> claude auth login
#   (or a long-lived token: docker exec -it <bot> claude setup-token)
#   check: docker exec <bot> claude auth status
```
→ prints an **OAuth URL** → open the web authorize page → get the **code** → **paste it back into that same session**. Credentials are saved to the **volume** via `CLAUDE_CONFIG_DIR=/data/.claude` → **no re-login on restart**.

- ⚠️ **`-it` is required** (an interactive session with a real TTY). Verified: the `claude auth login`/`setup-token` commands exist; but the OAuth flow (paste code vs browser redirect) inside the container needs Edward to run `-it` with his account to finalize — it can't be tested headless.
- **Fallback = `ANTHROPIC_API_KEY`** (env var): if interactive login isn't feasible. Simple, no interaction needed, but billed per key.

→ v1 prioritizes **paste-code login**; the API key is the fallback. Note: credentials live on the volume → anyone with access to the volume has the logged-in session, so protect the volume accordingly.

---

## 6. Process model & PTY

- `claude --channels ...` is an **interactive TUI session**, not a daemon. It needs a **pseudo-TTY**:
  - compose: `tty: true` + `stdin_open: true`
  - docker run: `-it` (or `-d -it`)
- Run **foreground** as PID 1 (via `tini` to reap zombies + receive signals).
- `restart: unless-stopped` (compose) → the bot restarts itself if it drops.
- **1 token = 1 container.** Telegram allows only one poller per token; two containers on the same token → 409 Conflict, stealing each other's updates. The image doesn't protect against this → document it clearly in the README.
- Changing the token requires restarting the container (the token is read once at boot).

---

## 7. Bake the telegram plugin (verify at POC)

The plugin normally installs via `/plugin` (interactive) → not suitable for a headless build. Two approaches, **verify which one works at the POC step** (not 100% certain — will test for real):

- **(A)** Run a plugin-install command **non-interactively at build time** (if the Claude CLI supports a flag like `claude plugin add` / headless marketplace add) → the result lands in `~/.claude/plugins` + marketplace config → commit into the image layer.
- **(B)** Bake **manually**: add the `claude-plugins-official` marketplace + copy/seed the `~/.claude/plugins/<telegram>` tree + write the "installed plugins" config file that Claude reads at boot.

Constraint: the baked plugin must match the Claude CLI version installed in the image (pin the version so it doesn't break). The plugin sets `TELEGRAM_STATE_DIR` so state lives on the volume (same mechanism as the current repo).

**Interaction with the volume (since §5 fixes `CLAUDE_CONFIG_DIR=/data/.claude` on the volume):** the baked plugin lives in the image layer (e.g. staged at `/opt/claude-plugins`), but the config dir is on the volume. → **entrypoint seeds on first run**: if `$CLAUDE_CONFIG_DIR/plugins` is empty, copy the plugin + marketplace config from the staging area into the volume. That way both the **plugin + login credentials** persist on the volume; subsequent runs don't re-seed and don't re-login.

> ⚠️ This is the project's highest technical risk — the POC should do §7 (bake + seed) together with §5 (paste-code login) FIRST to lock them down, then assemble the rest.

---

## 8. Access & security model (core)

**Safe default = preseed owner, NO pairing.**

- entrypoint seeds `access.json`: `dmPolicy = allowlist`, `allowFrom = [OWNER_ID]`.
- → Owner works immediately, strangers are ignored, **no pairing step needed**.
- This replaces the "auto-whitelist after pairing" idea.

**Why NOT auto-whitelist-after-pairing by default:** the pairing step, with a human approving, is exactly the anti-injection/spam layer. Auto-approve = anyone who DMs gets in → the bot is wide open.

- If you still want automatic pairing: the flag **`AUTO_PAIR=true`** (opt-in), with a **clear log warning**, and it should be limited (e.g. only auto-approve the FIRST user then lock itself to `policy=allowlist`). Default OFF.

**Add/edit access is NOT via chat** (anti-prompt-injection) — only via `docker exec` (the authenticated host channel):

```
docker exec <bot> tg-access status
docker exec <bot> tg-access allow <userId>
docker exec <bot> tg-access remove <userId>
docker exec <bot> tg-access group add <groupId> [--allow id1,id2] [--no-mention]
docker exec <bot> tg-access group rm <groupId>
docker exec <bot> tg-access policy <pairing|allowlist|disabled>
docker exec <bot> tg-access pair <code>     # when AUTO_PAIR=false, approve manually
```

`tg-access` = a script that edits `$STATE/access.json` per the plugin schema (the server re-reads it per message → effective immediately, no restart).

---

## 9. State & persistence

- `TELEGRAM_STATE_DIR=/data` → **mount a volume** (`-v botdata:/data` or a bind mount).
- Contents: `.env` (token), `access.json` (policy + allowlist + groups), `approved/<id>` (marker), `bot.pid`.
- The volume gives you: access persists across restarts + `docker exec tg-access` can edit it + easy backup.
- `~/.claude` (plugin + config) lives in the image (read-mostly); only dynamic state goes to the volume.

---

## 10. Project directory structure

```
claude-telegram-docker/
├── SPEC.md                  ← (this file)
├── README.md                ← build & run, example commands
├── Dockerfile
├── docker-compose.yml       ← example of 1 bot (env + volume + tty + restart)
├── docker-compose.multi.yml ← example of multiple bots (each service = 1 token/volume)
├── entrypoint.sh            ← validate env → seed state → exec claude --channels
├── scripts/
│   └── tg-access            ← access admin CLI (docker exec)
├── .env.example             ← env template (do not commit the real .env)
└── .dockerignore
```

---

## 11. Build & run (planned)

```bash
# build
docker build -t claude-telegram-docker .

# run 1 bot (token + owner; auth login in a later step)
docker run -d --name mybot -it --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=*** -e OWNER_ID=<your-telegram-user-id> \
  -v mybot-data:/data \
  claude-telegram-docker

# log into Claude (once) — setup-token PRINTS a token, does NOT save creds itself:
docker exec -it mybot claude setup-token
#   → open the printed URL, authorize, paste the FULL code; it prints a long-lived token (1 year).
# Put the token in env then RECREATE (restart does NOT reload env → still loggedIn:false):
#   add  CLAUDE_CODE_OAUTH_TOKEN=<the-token-just-printed>  to .env, then:
docker compose up -d
docker exec mybot claude auth status   # loggedIn:true means done

# add a group
docker exec mybot tg-access group add <group-id>

# view access
docker exec mybot tg-access status
```

> Fallback if paste-code doesn't work: add `-e ANTHROPIC_API_KEY=***` at `docker run`, skip the `claude /login` step.

compose: `docker compose up -d` with a file that has env/volume/tty ready.

---

## 12. Security (checklist)

- Secrets only at runtime (env / docker secret), **never baked into the image**, never commit `.env`.
- `OWNER_ID` preseed + `allowlist` → owner-only bot from boot.
- Access mutations only via `docker exec` (host), **never via a Telegram message**.
- 1 API key per bot if you want to separate billing + reduce the blast radius when leaked.
- Container runs non-root + read-only rootfs (if feasible) + only `/data` writable.
- `AUTO_PAIR` default OFF; enabling it means understanding the risk.
- PIN plugin/CLI versions for reproducible builds.

---

## 13. Decisions (Edward finalized 2026-06-26)

1. **Auth:** ✅ **Paste-code login via `docker exec` (primary)**, using the Claude subscription; `ANTHROPIC_API_KEY` = fallback. Creds persist on the volume. (§5)
2. **Base image:** ✅ **`node:22-slim` + install bun** (bun is required because the telegram plugin runs its server on bun).
3. **Pairing:** ✅ **Preseed-owner only**, NO `AUTO_PAIR` in v1.
4. **Distribution:** ✅ **Build & test locally first**, then push to **GHCR** once stable (CI deferred).
5. **Image name:** ✅ **`claude-telegram-docker`**.
6. **Owner:** ✅ **1 owner** (single `OWNER_ID`, not a list).

---

## 14. Risks & order of work (POC)

1. **§7 bake plugin** (highest risk) → prove it at POC first.
2. **§6 PTY + auth** → claude --channels stays alive in the container, receives test messages.
3. **§8 entrypoint seed + tg-access** → owner-only works immediately, exec can add more ids.
4. Assemble Dockerfile + compose + README.
5. (Optional) push to GHCR + CI build.

> When verifying any Claude CLI / plugin behavior that isn't certain → test it for real at the POC, don't put guesses into the docs.
