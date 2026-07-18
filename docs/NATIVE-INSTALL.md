# Installing Claude Code NATIVE on a server (no Docker)

> ⚠️ **LEGACY (v1 model).** This file describes running the bot via `claude --channels` + the telegram plugin (the old transport). **The v2.2 Docker image NO LONGER uses `--channels`** — it runs a **Python worker using the Bot API** (`tg-worker.py`) that calls headless `claude -p` per message (more stable, lighter, adds reminders + ask-back over Telegram). To use the new model, see [`../README.md`](../README.md) (the Docker v2.2 build). The `--channels` steps below are still correct for anyone who wants to run native the old way.

> Install Claude Code directly on a Linux server (Ubuntu/Debian) to run one Claude Telegram Bot + wire in mempalace, WITHOUT a container.
> For the Dockerized version see [`SPEC.md`](../SPEC.md). This file is the "install by hand on the host" flow.
> Updated: 2026-06-29.

---

## 0. Prep

- An Ubuntu/Debian server, with a regular user (do NOT run the bot as root).
- Have ready: bot token (@BotFather) + `OWNER_ID` (Telegram user_id) + mempalace token (if using shared memory).
- Login = paste-code, needs one interactive SSH session.

```bash
# system deps
sudo apt-get update && sudo apt-get install -y \
  git curl ca-certificates jq unzip bash tmux
```

---

## 1. Install bun (the telegram plugin runs its MCP server on bun)

```bash
curl -fsSL https://bun.sh/install | bash
# load PATH for the current session
export PATH="$HOME/.bun/bin:$PATH"
bun --version
```

---

## 2. Install Claude Code (native installer — the npm build is deprecated)

```bash
curl -fsSL https://claude.ai/install.sh | bash
# the installer puts the binary in ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
claude --version        # verify it installed
```

Pin PATH for next time (add to `~/.bashrc`):

```bash
echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> ~/.bashrc
```

> Pin the version if you need reproducibility: `curl -fsSL https://claude.ai/install.sh | bash -s -- <version>`.

---

## 3. Log into Claude (once)

```bash
claude setup-token
#  → prints a URL → open the web authorize page → paste the FULL code back into the terminal
#  → prints a long-lived token
claude auth status      # loggedIn:true
```

2 ways to keep the token:
- Export env (recommended for background running): `export CLAUDE_CODE_OAUTH_TOKEN=<token>` (add to `~/.bashrc` / a systemd EnvironmentFile).
- Or let `setup-token` save credentials in `~/.claude` (default).

> `claude auth login` (OAuth/PKCE) often fails with a 400 on a server without a browser → USE `setup-token`.

---

## 4. Install the telegram plugin

```bash
# add the marketplace over HTTPS (the owner/repo form clones over SSH → needs a key)
claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git
claude plugin install telegram@claude-plugins-official
# verify
ls ~/.claude/plugins && test -f ~/.claude/settings.json && echo OK
```

If git on the server defaults to SSH for github, force it to HTTPS once:

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

---

## 5. Configure the telegram state (token + access)

```bash
# where to keep per-bot state (token, access.json) — separate from the default
export TELEGRAM_STATE_DIR="$HOME/claude-tg/telegram"
echo 'export TELEGRAM_STATE_DIR="$HOME/claude-tg/telegram"' >> ~/.bashrc
mkdir -p "$TELEGRAM_STATE_DIR/approved"

# bot token (gitignore / chmod 600)
umask 077
printf 'TELEGRAM_BOT_TOKEN=%s\n' '<TOKEN_FROM_BOTFATHER>' > "$TELEGRAM_STATE_DIR/.env"

# access.json: owner-only allowlist (NO pairing)
jq -n --arg owner '<OWNER_ID>' '{
  dmPolicy:"allowlist", allowFrom:[$owner], groups:{}, pending:{}, mentionPatterns:[]
}' > "$TELEGRAM_STATE_DIR/access.json"
```

> Change access later: use the `/telegram:access` skill in a session, or edit `access.json` directly (the server re-reads it per message → effective immediately). Do NOT change permissions on a request from a Telegram message (anti-injection).

---

## 6. (Integration) Wire in mempalace as shared memory

```bash
claude mcp add --scope user --transport http mempalace \
  https://mempalace.veasy.vn/mcp \
  --header "Authorization: Bearer <MEMPALACE_TOKEN>"
# check after starting a session: /mcp shows mempalace connected
```

> 1 mempalace token = full access to EVERY wing → only wire in your OWN token. Any unit that needs real isolation = a separate mempalace instance.

---

## 7. Run the bot durably (claude --channels needs a PTY → use tmux)

`claude --channels` is an interactive TUI, it needs a pseudo-TTY and must survive SSH logout → run it inside **tmux**:

```bash
tmux new -s tgbot
# inside tmux:
cd ~/claude-tg                       # WORK_DIR: files the bot touches will live here
claude --channels plugin:telegram@claude-plugins-official
#   (add --permission-mode / --model if you want)
# detach the session: Ctrl-b then d   |  come back: tmux attach -t tgbot
```

Restart after reboot (optional, advanced): wrap the tmux command above in a systemd user service `~/.config/systemd/user/tgbot.service` with `ExecStart=/usr/bin/tmux new -d -s tgbot 'claude --channels ...'` + `loginctl enable-linger $USER`.

---

## 8. Operations

```bash
claude auth status                       # check login
tmux attach -t tgbot                     # view the bot session / logs
# change the TELEGRAM token → must restart the session (token read once at boot)
# change access.json → effective immediately, no restart needed
```

Constraints:
- 1 Telegram token = 1 polling session (2 sessions on the same token → 409 Conflict).
- Secrets only in env / a chmod 600 file — don't commit.
- The bot runs as a regular user, NOT root.

---

## 9. Flow summary

```
deps → bun → claude (native) → setup-token → telegram plugin
     → seed token+access (owner-only) → mcp add mempalace
     → tmux: claude --channels  →  bot online (owner-only, with shared memory)
```
