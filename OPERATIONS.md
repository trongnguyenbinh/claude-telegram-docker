# OPERATIONS — running & troubleshooting bots

Operational notes + real-world "gotchas". Tooling baked into the image:
`bot-doctor` (diagnostics) and `tg-healthcheck` (Docker HEALTHCHECK liveness).

## Quick diagnosis

```bash
docker exec <container> bot-doctor        # runs all checks + suggests fixes
docker ps                                 # STATUS column: healthy / unhealthy (HEALTHCHECK)
docker exec -u botuser <container> tmux attach -t claude   # view the session (detach: Ctrl+B then D)
```

## Safe recreate / update (keeping state)

Durable state lives on the volumes (`/data`, `/working-directory`) + the shared memory
server (remote, if configured) → a recreate does NOT lose it. You only lose the "short-term
memory" of the running session (RAM context); the transcript is still stored at
`/data/.claude/projects/*.jsonl` on the volume.

Procedure:

1. **Checkpoint the shared memory first** (if you want to be sure): run one turn so the bot
   pushes durable state to its shared memory server.
2. **Env-preserving recreate**: copy every env var from the old container, override only what
   you need (usually `PERMISSION_MODE=auto`), keep the volumes:
   ```bash
   C=<container>; IMG=ghcr.io/<owner>/claude-telegram-docker:latest
   docker logout ghcr.io; docker pull "$IMG"
   ENVARGS=(); while IFS= read -r e; do case "$e" in PATH=*|HOME=*|HOSTNAME=*|TERM=*|LANG=*|LC_ALL=*|LANGUAGE=*|PERMISSION_MODE=*) continue;; esac; [ -n "$e" ] && ENVARGS+=( -e "$e" ); done < <(docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}')
   ENVARGS+=( -e PERMISSION_MODE=auto )
   VOLARGS=(); while IFS= read -r m; do [ -n "$m" ] && VOLARGS+=( -v "$m" ); done < <(docker inspect "$C" --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{println}}{{end}}')
   docker rm -f "$C"; docker run -dt --name "$C" --restart unless-stopped "${ENVARGS[@]}" "${VOLARGS[@]}" "$IMG"
   ```
3. **Verify the pending drain**: after recreate, run `bot-doctor` or poll `getWebhookInfo` a
   few times — `pending_update_count` must reach 0.

## Gotchas seen in practice

- **Poller stuck after a recreate** — container Up, session alive, auto mode on, BUT
  `pending_update_count` > 0 and not draining (one message stuck in the input box blocks
  further polling) → the bot looks dead.
  **Fix:** `docker restart <container>` (usually one shot). `bot-doctor` detects this case.
  **Self-heals (v1.3.1+):** `tg-watchdog` runs via cron every minute — if pending is stuck
  for 2 ticks in a row while the session is idle, it `tmux send-keys Enter` to submit the
  stuck message → the poller flows again, usually without a manual restart. Log:
  `/tmp/tg-watchdog.log` inside the container.
- **Constant accept prompts** — the bot is on `PERMISSION_MODE=acceptEdits` (auto-approves
  file edits only, STILL prompts on every Bash/network command). To stop the prompts →
  `PERMISSION_MODE=auto`. Toggling shift+tab in the session does NOT persist across a restart;
  set it in env → recreate.
- **Running as root** — no special feature needed: `-e BOT_USER=root -e BOT_HOME=/root`
  (the entrypoint does `gosu $BOT_USER`).
- **Specialized bots (`BOT_ROLE`)** — set `-e BOT_ROLE=<ba|planner|dev-fe|dev-be|tester|infra>` at
  `docker run`/recreate. On first run the entrypoint seeds the role's CLAUDE.md into the
  work-dir CLAUDE.md (`$WORK_DIR/CLAUDE.md`) + jq-merges `settings-fragment.json` (union of
  enabledPlugins + permissions.allow) + seeds `rules/` into `.workspace/rules/`. **CLAUDE.md
  is only seeded when the work dir has no CLAUDE.md** — changing `BOT_ROLE` on an
  already-running bot (one that already has a work-dir CLAUDE.md) will NOT swap the CLAUDE.md;
  to really change it, delete/rename `$WORK_DIR/CLAUDE.md` and restart, or use a clean volume.
  The settings-merge is a union, so re-running is harmless. Unset / `default` / a non-existent
  role = default behavior (one note line logged), existing bots are NOT affected. Details:
  `roles/README.md`.
- **Non-ASCII text broken in tmux** — missing UTF-8 locale (debian-slim defaults to C). The
  image sets `LANG=C.UTF-8` + `tmux -u`. Old bots: recreate from the new image.
- **GitHub inside the bot** — use `gh` (baked), auth via `-e GH_TOKEN=<PAT>` +
  `gh auth setup-git`. Do NOT use the github MCP plugin (HTTP 400 bug).
- **Docker exec on a botuser bot** must use `-u botuser` (the tmux socket is per-user); a bot
  running as root uses the default exec (root).
- **The permissions block** in the staged settings.json only applies to FRESH volumes; old
  bots must merge it into `/data/.claude/settings.json` by hand, then restart.

## HEALTHCHECK

`tg-healthcheck` (Docker HEALTHCHECK) only checks LIVENESS (the session is still alive) → it
catches a crash/exit, NOT a poller stall (the session is still alive). Pair it with an
`autoheal`-style watchdog to auto-restart an `unhealthy` container. For poller stalls: use
`bot-doctor`.
