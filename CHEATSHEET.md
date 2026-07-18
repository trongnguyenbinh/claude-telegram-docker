# Cheat Sheet — Operating a bot (v2.2 worker)

Replace `<bot>` with the container name (e.g. `bot-claude-support`). **Most commands need
`-u botuser`** (the bot runs non-root; running as root means `access.json`/creds don't take).
v2.2 transport = the Python worker `tg-worker.py` (no tmux, no `--channels`). Single volume:
`~/.claude` = `/home/botuser/.claude`.

## Container

| Task | Command |
|---|---|
| Status | `docker ps --format "{{.Names}} {{.Status}}"` (STATUS = healthy/unhealthy) |
| Logs | `docker logs --tail 40 <bot>` |
| Worker log | `docker exec -u botuser <bot> sh -c 'tail -f /home/botuser/.claude/telegram/worker.log'` |
| Restart (keep everything) | `docker restart <bot>` |
| Recreate (change env, KEEP volume) | `docker rm -f <bot> && docker run -d --name <bot> --restart unless-stopped -e ... -v <bot>-claude:/home/botuser/.claude <image>` |
| Run a new bot | as above with a new volume + token |
| Specialized (role) bot | add `-e BOT_ROLE=<ba\|planner\|dev-fe\|dev-be\|tester\|infra>`. Unset = default. See `roles/README.md` |

> No `-it`/PTY needed to run the worker (headless daemon). `-it` is only for interactive `claude auth login`.

## Login / Auth (subscription only — `ANTHROPIC_API_KEY` is ignored)

| Task | Command / Note |
|---|---|
| Long-lived token | `docker exec -it -u botuser <bot> claude setup-token` → open URL → authorize → **paste the code back** → it prints `sk-ant-oat01-...` |
| Use the token | recreate with `-e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...` |
| Interactive login | `docker exec -it -u botuser <bot> claude auth login` (creds persist on the `~/.claude` volume) |
| Check | `docker exec -u botuser <bot> claude auth status` |
| Force the env token | `docker exec -u botuser <bot> mv /home/botuser/.claude/.credentials.json /home/botuser/.claude/.credentials.json.bak` then restart |

> `sk-ant-oat...` = OAuth token (what `CLAUDE_CODE_OAUTH_TOKEN` needs), NOT an API key (`sk-ant-api-...`).

## Diagnostics

| Task | Command |
|---|---|
| Full diagnosis | `docker exec <bot> bot-doctor` (worker process / heartbeat / permission+tools / poller / login / reminders + prints the fix) |
| Health status | `docker ps` — STATUS: `healthy`/`unhealthy` (HEALTHCHECK = worker alive + heartbeat fresh) |
| Worker wedged (heartbeat stale) | `docker restart <bot>` |

## Monitoring the bot (no tmux in v2.2)

| Task | Command |
|---|---|
| Worker activity | `docker exec -u botuser <bot> sh -c 'tail -f /home/botuser/.claude/telegram/worker.log'` |
| Transcript (per `claude -p` turn) | `docker exec -u botuser <bot> sh -c 'tail -f /home/botuser/.claude/projects/*/*.jsonl'` |

## Worker permission mode + tools

| Task | Command / Note |
|---|---|
| Permission mode | `-e TG_WORKER_PERMISSION_MODE=acceptEdits` (or `PERMISSION_MODE`). Aliases: `auto`→`acceptEdits`, `manual`→`default`. Valid: `default\|acceptEdits\|bypassPermissions\|plan` |
| Allowed tools (default) | `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch` (NO free Bash) |
| Widen tools (trusted bot) | `-e TG_WORKER_ALLOWED_TOOLS="mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch,Bash,Edit,Write"` |

## Reminders (`tg-reminder`)

| Task | Command |
|---|---|
| One-off | `docker exec -u botuser <bot> tg-reminder add --chat <id> --text "Họp" --at 2026-07-20T08:00` |
| Daily | `docker exec -u botuser <bot> tg-reminder add --chat <id> --text "Uống nước" --daily 15:00` |
| Weekly (claude turn) | `docker exec -u botuser <bot> tg-reminder add --chat <id> --prompt "Tóm tắt tin AI" --weekly mon 09:00` |
| List | `docker exec -u botuser <bot> tg-reminder list` |
| Remove | `docker exec -u botuser <bot> tg-reminder remove <id>` |

> `--text` sends literal text; `--prompt` runs a `claude -p` turn and sends its output. Fires in the container TZ (Asia/Ho_Chi_Minh).

## Running a bot as root

| Task | Command |
|---|---|
| Recreate as root | add `-e BOT_USER=root -e BOT_HOME=/root` (exec then needs no `-u botuser`) |

## Access management (ALWAYS `-u botuser`)

| Task | Command |
|---|---|
| Status | `docker exec -u botuser <bot> tg-access status` |
| Allowlist mode | `docker exec -u botuser <bot> tg-access policy allowlist` |
| Allow a user | `docker exec -u botuser <bot> tg-access allow <userId>` |
| Add a group | `docker exec -u botuser <bot> tg-access group add <groupId>` |
| Remove a group | `docker exec -u botuser <bot> tg-access group rm <groupId>` |

## MCP (e.g. shared memory)

| Task | Command |
|---|---|
| List + status | `docker exec -u botuser <bot> claude mcp list` |
| Add mempalace (HTTP) | `docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace https://<domain>/mcp --header "Authorization: Bearer <token>"` then `docker restart <bot>` |
| Add Playwright (`:v2.2.0-playwright`) | `docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless` then `docker restart <bot>` + widen `TG_WORKER_ALLOWED_TOOLS` to include `mcp__playwright` |

## GitHub inside the bot (gh)

| Task | Command / Note |
|---|---|
| Auth gh | recreate with `-e GH_TOKEN=<PAT>` then `docker exec -u botuser <bot> gh auth setup-git` |
| Note | use `gh` (baked), NOT the github MCP plugin (HTTP 400 bug) |

## Update Claude Code

| Task | Command |
|---|---|
| Version | `docker exec -u botuser <bot> claude --version` |
| Update via the image | pull a newer image tag → recreate on it |

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| Bot silent, container Up | worker wedged / auth expired → `docker exec <bot> bot-doctor`; `docker logs <bot>`; `docker restart <bot>` |
| Container `unhealthy` | worker process dead OR heartbeat stale (>180s) → `docker restart <bot>` |
| `401 Invalid ... credentials` | token expired → new `claude setup-token` + recreate, or delete `.credentials.json` (it overrides the env token) |
| `401 Invalid bearer token` | wrong token type — pasted `xxx#yyy` instead of `sk-ant-oat01-...` |
| Bot ignores an allowed tool | tool not in `TG_WORKER_ALLOWED_TOOLS` → widen it (headless `-p` auto-denies tools outside the allowlist) |
| `Failed to load marketplace: cache-miss` | plugin path drift → entrypoint self-heals on boot, or re-run `claude plugin marketplace add` |
| tg-access changes don't persist | missing `-u botuser` |
| Reminders never fire | check TZ + `tg-reminder list` (next_fire) + worker.log; a daily/weekly whose time already passed today fires the NEXT period, not late |
| Lost an extra network after recreate | add `--network <net>` to `docker run` |
| Playwright MCP "Failed to connect" | must be `playwright-mcp --headless` (baked binary) + the `:v2.2.0-playwright` image; and add `mcp__playwright` to `TG_WORKER_ALLOWED_TOOLS` |
