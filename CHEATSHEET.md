# Cheat Sheet — Operating a bot

Replace `<bot>` with the container name (e.g. `claude-tg-bot-qc`). **Most commands need
`-u botuser`** (the bot runs non-root; running as root means `access.json`/creds don't take).

## Container

| Task | Command |
|---|---|
| Status | `docker ps --format "{{.Names}} {{.Status}}"` |
| Logs | `docker logs --tail 40 <bot>` |
| Restart (keep everything) | `docker restart <bot>` |
| Recreate (change env, KEEP volumes) | `docker rm -f <bot> && docker run -d --name <bot> -it --restart unless-stopped -e ... -v <bot>-data:/data -v <bot>-work:/working-directory <image>` |
| Run a new bot | as above with a new volume + token |
| Run a specialized (role) bot | add `-e BOT_ROLE=<ba\|planner\|dev-fe\|dev-be\|tester\|infra>` to `docker run` — seeds the role's CLAUDE.md + settings + rules (first run). Unset = default behavior. See `roles/README.md` |

## Login / Auth

| Task | Command / Note |
|---|---|
| Interactive login | `docker exec -it -u botuser <bot> claude auth login` (opens a URL, authorize; creds stored on the volume, can EXPIRE) |
| Create a long-lived token | `docker exec -it -u botuser <bot> claude setup-token` → prints a URL → authorize → **paste the code (`xxx#yyy`) BACK into the prompt** → it prints `sk-ant-oat01-...` |
| Use the long-lived token | recreate with `-e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...` **and** delete the old creds (below) |
| Check | `docker exec -u botuser <bot> claude auth status` ⚠️ reports `loggedIn:true` even when the token has expired |
| Force the env token | `docker exec -u botuser <bot> mv /data/.claude/.credentials.json /data/.claude/.credentials.json.bak` then restart (the creds file overrides the env token) |

> `sk-ant-oat...` = an OAuth token (what `CLAUDE_CODE_OAUTH_TOKEN` needs), NOT an API key (`sk-ant-api-...`).

## Diagnostics (bot-doctor)

| Task | Command |
|---|---|
| Full diagnosis | `docker exec <bot> bot-doctor` (checks tmux/permission/poller/locale/base CLAUDE.md/.workspace/login + prints the fix) |
| Health status | `docker ps` — STATUS column: `healthy`/`unhealthy` (HEALTHCHECK = tg-healthcheck) |
| Poller stuck (pending won't reach 0) | `docker restart <bot>` (usually one shot) |

## Running a bot as root

| Task | Command |
|---|---|
| Recreate as root | add `-e BOT_USER=root -e BOT_HOME=/root` to `docker run` (exec then needs no `-u botuser`) |

## Monitoring the bot

| Task | Command |
|---|---|
| Attach the live TUI | `docker exec -it -u botuser <bot> tmux attach -t claude` |
| Detach safely | **Ctrl+B then D** (do NOT Ctrl+C — it kills the bot) |
| Transcript | `docker exec <bot> sh -c 'tail -f /data/.claude/projects/*/*.jsonl'` |

## Permission mode

| Task | Command / Note |
|---|---|
| Change in the TUI | press **Shift+Tab** (cycles: accept edits → plan → bypass …) |
| Set via env | default `auto` (classifier-gated, recommended — headless won't hang). Override: `-e PERMISSION_MODE=acceptEdits` |
| bypassPermissions | prompts a "Yes, I accept" dialog every time → headless HANGS; attach tmux → ↓ pick Yes → Enter |

## Access management (ALWAYS `-u botuser`)

| Task | Command |
|---|---|
| Status | `docker exec -u botuser <bot> tg-access status` |
| Allowlist mode | `docker exec -u botuser <bot> tg-access policy allowlist` |
| Allow a user | `docker exec -u botuser <bot> tg-access allow <userId>` |
| Add a group | `docker exec -u botuser <bot> tg-access group add <groupId>` |
| Remove a group | `docker exec -u botuser <bot> tg-access group rm <groupId>` |

## Plugins

| Task | Command |
|---|---|
| List | `docker exec -u botuser <bot> sh -c 'cat /data/.claude/plugins/installed_plugins.json \| jq -r ".plugins\|keys[]"'` |
| Add a marketplace | `docker exec -u botuser <bot> claude plugin marketplace add <git-url>` |
| Install a plugin | `docker exec -u botuser <bot> claude plugin install <name>@<marketplace>` |
| Remove | `docker exec -u botuser <bot> claude plugin uninstall <name>@<marketplace>` |

## MCP (e.g. a shared memory server)

| Task | Command |
|---|---|
| List + status | `docker exec -u botuser <bot> claude mcp list` |
| Add an HTTP MCP (e.g. mempalace) | `docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace https://<domain>/mcp --header "Authorization: Bearer <token>"` then `docker restart <bot>` |
| Add Playwright (image `:playwright`) | `docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless` then `docker restart <bot>` — use the baked binary, NOT `npx @playwright/mcp@latest` |

## GitHub inside the bot (gh)

| Task | Command / Note |
|---|---|
| Auth gh | recreate with `-e GH_TOKEN=<PAT>` then `docker exec -u botuser <bot> gh auth setup-git` |
| Check | `docker exec -u botuser <bot> gh auth status` |
| Note | use `gh` (baked), NOT the github MCP plugin (currently broken, HTTP 400) |

## Update Claude Code

| Task | Command |
|---|---|
| Version | `docker exec -u botuser <bot> claude --version` |
| Update in the container | `docker exec -u botuser <bot> claude update && docker restart <bot>` |
| Update via the image | rebuild the image (the Dockerfile fetches the latest) → `docker pull <image>` → recreate |

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `401 Invalid ... credentials` / "Please run /login" | token expired → log in again, OR use a long-lived token + delete `.credentials.json` (the creds file overrides the env token) |
| `401 Invalid bearer token` | wrong token type — you pasted the code `xxx#yyy` instead of `sk-ant-oat01-...` |
| `Failed to load marketplace: cache-miss` | plugin path drift (old volume) → the entrypoint self-heals on boot, or re-run `claude plugin marketplace add` |
| `node: not found` | new images ship node→bun; on an old one: `docker exec -u root <bot> ln -sf /usr/local/bin/bun /usr/local/bin/node` |
| bypass dialog hangs the bot | use `acceptEdits`, or attach tmux and accept by hand |
| tg-access changes don't persist | missing `-u botuser` |
| GHCR pull `denied` (public image) | stale creds → `docker logout ghcr.io` then pull again |
| New bot missing the baked plugins | old volume was already seeded → `claude plugin install` by hand, or use a clean volume |
| Bot looks dead after recreate (session alive but not receiving messages) | poller stuck, `pending_update_count`>0 not draining → `docker restart <bot>` |
| Old bot missing permissions/base CLAUDE.md/.workspace | only seeded on FRESH volumes → merge `/data/.claude/settings.json` by hand + recreate/pull the new image, then restart |
| Lost an extra network (e.g. `db-shared`) after recreate | a plain recreate doesn't keep the network → add `--network <net>` to `docker run` |
| Playwright MCP "Failed to connect" | using `npx @playwright/mcp@latest` → must be `playwright-mcp --headless` (baked binary) + the `:playwright` image |
