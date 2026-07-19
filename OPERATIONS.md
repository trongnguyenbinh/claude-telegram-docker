# OPERATIONS — running & troubleshooting bots (v2.2 worker)

Operational notes + real-world "gotchas". v2.2 transport = the Python Bot-API worker
`tg-worker.py` (the container's main process; no tmux, no `claude --channels`). Tooling
baked into the image: `bot-doctor` (diagnostics) and `tg-healthcheck` (Docker HEALTHCHECK).

## Quick diagnosis

```bash
docker exec <container> bot-doctor        # worker/heartbeat/permission/poller/login/reminders + fixes
docker ps                                 # STATUS: healthy / unhealthy (HEALTHCHECK)
docker logs --tail 60 <container>         # worker stdout
docker exec -u botuser <container> sh -c 'tail -f /home/botuser/.claude/telegram/worker.log'
```

## Layout (single volume)

Everything lives on ONE volume mounted at `/home/botuser/.claude` (`~/.claude`):

```
~/.claude/                 settings.json, CLAUDE.md, plugins/, credentials
~/.claude/telegram/        .env (token), access.json, sessions/<chat_id>, offset, worker.log, worker.heartbeat
~/.claude/workspace/       session cwd, repo clones, reminders/*.json, .workspace/{rules,memory,events,status}
```

Only `~/.claude` is mounted — never mount the whole `/home/botuser` (it would shadow the
`claude`/`bun` binaries baked into the image layer).

## Safe recreate / update (keeping state)

Durable state lives on the `~/.claude` volume + the shared memory server (remote, if
configured) → a recreate does NOT lose it. You only lose the RAM context of an in-flight
`claude -p` turn; per-chat sessions + transcripts persist on the volume.

Env-preserving recreate (copy every env var, keep the volume):

```bash
C=<container>; IMG=ghcr.io/<owner>/claude-telegram-docker:v2.2.0
docker logout ghcr.io; docker pull "$IMG"
ENVARGS=(); while IFS= read -r e; do case "$e" in PATH=*|HOME=*|HOSTNAME=*|TERM=*|LANG=*|LC_ALL=*|LANGUAGE=*|TZ=*) continue;; esac; [ -n "$e" ] && ENVARGS+=( -e "$e" ); done < <(docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}')
VOLARGS=(); while IFS= read -r m; do [ -n "$m" ] && VOLARGS+=( -v "$m" ); done < <(docker inspect "$C" --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{println}}{{end}}')
docker rm -f "$C"; docker run -d --name "$C" --restart unless-stopped "${ENVARGS[@]}" "${VOLARGS[@]}" "$IMG"
```

After recreate: `bot-doctor` should report the worker alive + heartbeat fresh + pending draining.

## Migration v1.x → v2.2 (clean install, per bot)

v2.2 is a **breaking** layout change (`~/.claude` single volume, worker transport). It does
NOT migrate an old `/data` volume (a copy would break plugin install paths). Migrate each bot
by clean install onto a fresh volume; keep the old container until the new one is verified.

1. Note the old bot's env (token, OWNER_ID, MODEL, OAuth token) via `docker inspect`.
2. Run the new bot on `:v2.2.0` with a fresh `~/.claude` volume:
   ```bash
   docker run -d --name <bot> --restart unless-stopped \
     -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> -e CLAUDE_CODE_OAUTH_TOKEN=<oauth> -e MODEL=sonnet \
     -v <bot>-claude:/home/botuser/.claude \
     ghcr.io/<owner>/claude-telegram-docker:v2.2.0
   ```
3. Re-add the mempalace MCP (per-bot bearer token) + `docker restart`.
4. Re-add groups: `docker exec -u botuser <bot> tg-access group add <groupId>`.
5. Verify with `bot-doctor`, send a test DM, then retire the old v1 container.

**Rollback:** the old v1.x image/container (don't delete it until v2.2 is confirmed working).
Because a `v*` tag push does NOT move `:latest`, recreating a still-v1 bot on `:latest` won't
accidentally jump it onto v2.2.

## Gotchas seen in practice

- **Bot silent, container Up** — worker wedged or auth expired. `bot-doctor` shows which:
  worker process dead → `docker restart`; heartbeat stale (>180s) → `docker restart`; login
  failed → re-auth. The old `--channels` "poller stuck in the input box" failure mode is GONE
  (the worker owns polling; there is no TUI input box), which is the whole point of v2.2.
- **`tg-watchdog` is removed** — it existed only to un-stick the `--channels` poller. The
  worker self-recovers via getUpdates backoff, and the HEALTHCHECK (worker alive + fresh
  heartbeat) catches a wedged worker; pair it with an `autoheal`-style container to auto-restart.
- **Bot ignores a tool it "should" have** — headless `claude -p` auto-DENIES any tool not in
  `--allowedTools` (it can't prompt). Widen `TG_WORKER_ALLOWED_TOOLS` (default has NO Bash on
  purpose — safe for group-exposed bots against prompt injection).
- **Reminders** — fire in the container timezone (`TZ`, default Asia/Ho_Chi_Minh). A daily/
  weekly reminder whose time already passed today fires the NEXT period (not late). Check
  `tg-reminder list` (shows `next_fire`) + `worker.log`. Reminder defs live at
  `~/.claude/workspace/reminders/*.json`.
- **Auth is subscription-only** — the worker pops `ANTHROPIC_API_KEY`; provide
  `CLAUDE_CODE_OAUTH_TOKEN` or `claude auth login`. A stale on-volume `.credentials.json`
  overrides the env token → move it aside if switching to an env token.
- **Running as root** — `-e BOT_USER=root -e BOT_HOME=/root` (the entrypoint does `gosu $BOT_USER`).
- **Specialized bots (`BOT_ROLE`)** — seeds the role's CLAUDE.md into `$WORK_DIR/CLAUDE.md` +
  jq-merges `settings-fragment.json` + seeds `rules/` on first run. CLAUDE.md is only seeded
  when the work dir has none. Unset/`default`/unknown = default behavior. See `roles/README.md`.
- **Media (v2.3)** — inbound photos/documents are saved to `~/.claude/workspace/inbox/` and Claude
  views/reads them with the built-in `Read` tool (no extra config). **Voice/audio** needs
  `VOICE_API_URL` + `VOICE_API_KEY`; without them a voice message gets a "voice not enabled" reply.
  With voice set, the entrypoint auto-registers the baked `voice` MCP (`docker logs` shows
  `registered voice MCP`); inbound transcription + `[[voice]]` replies work even without `mcp__voice`
  in `TG_WORKER_ALLOWED_TOOLS` (the worker calls the Voice API itself). A voice reply that comes back
  as text means `/speak` failed (worker fell back) — check `worker.log` + the Voice API health.
- **Replies render as MarkdownV2 (v2.3)** — ` ```code``` ` blocks become tap-to-copy; if a reply
  arrives as plain text with literal markdown, the MarkdownV2 parse 400'd and the worker fell back
  (safe). `worker.log` logs `md2 send err (fallback plain)` in that case.
- **Non-ASCII text** — image sets `LANG=C.UTF-8`. Old bots: recreate from the new image.
- **GitHub inside the bot** — use `gh` (baked), auth via `-e GH_TOKEN=<PAT>` + `gh auth setup-git`.
- **`docker exec` on a botuser bot** must use `-u botuser` (files under `~/.claude` are botuser's).
- **The baked `permissions` block** in staged settings.json only applies to FRESH volumes.
- **An extra docker network** (e.g. `db-shared`) is NOT preserved by a plain recreate → add
  `--network <net>` to `docker run`.

## HEALTHCHECK

`tg-healthcheck` (Docker HEALTHCHECK) checks: the `tg-worker.py` process is alive AND its
heartbeat file (`~/.claude/telegram/worker.heartbeat`) is fresh. The worker rewrites the
heartbeat every getUpdates cycle (≤50s) and every scheduler tick (~45s), so `unhealthy` means
the worker crashed or wedged. Pair it with an `autoheal`-style watchdog to auto-restart an
`unhealthy` container.
