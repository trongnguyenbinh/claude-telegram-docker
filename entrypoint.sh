#!/usr/bin/env bash
# Seed state, chown the mounted volumes, then DROP to a non-root user (botuser)
# and hand off to `claude --channels`. Starts as root ONLY to chown the volumes;
# claude itself runs as botuser so `--permission-mode bypassPermissions` (Auto
# Mode) is allowed (Claude blocks --dangerously-skip-permissions under root).
# See SPEC.md §6/§7/§8.
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required (docker run -e ...)}"
: "${OWNER_ID:?OWNER_ID required (docker run -e ...)}"

# v2: single-volume default layout. Everything durable lives under ~/.claude.
BOT_USER="botuser"                 # non-root only (auto/bypass requires it); root option dropped
BOT_HOME="/home/botuser"
CLAUDE_CONFIG_DIR="$BOT_HOME/.claude"
TELEGRAM_STATE_DIR="$CLAUDE_CONFIG_DIR/channels/telegram"   # == telegram plugin default
WORK_DIR="$CLAUDE_CONFIG_DIR/workspace"                     # session CWD; .workspace + repo clones
CLAUDE_STAGE="${CLAUDE_STAGE:-$BOT_HOME/claude-stage}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/approved" "$WORK_DIR"

# v2: env token is the single source of auth. A leftover .credentials.json (from a
# past interactive login) OVERRIDES the env token and silently 401s when it expires.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  rm -f "$CLAUDE_CONFIG_DIR/.credentials.json"
fi

# 1) Seed baked Claude config (settings.json + plugins/ tree) from image staging
#    -> volume config, first run only. cp -a preserves botuser ownership.
if [ ! -d "$CLAUDE_CONFIG_DIR/plugins" ] && [ -d "$CLAUDE_STAGE/plugins" ]; then
  echo "[entrypoint] seeding baked Claude config into $CLAUDE_CONFIG_DIR"
  cp -a "$CLAUDE_STAGE/." "$CLAUDE_CONFIG_DIR/"
fi

# 1b) Normalize plugin install paths -> the runtime config dir. The baked config
#     records marketplace/plugin locations at the STAGING dir ($CLAUDE_STAGE, or
#     /opt/claude-stage on legacy volumes from the old root image); the files
#     actually live under $CLAUDE_CONFIG_DIR/plugins, so a stale absolute path →
#     "Failed to load marketplace: cache-miss". Rewrite every boot (idempotent;
#     self-heals volumes carried across image changes).
for _pf in known_marketplaces.json installed_plugins.json; do
  _pfile="$CLAUDE_CONFIG_DIR/plugins/$_pf"
  [ -f "$_pfile" ] && sed -i \
    -e "s#/opt/claude-stage#$CLAUDE_CONFIG_DIR#g" \
    -e "s#${CLAUDE_STAGE}#$CLAUDE_CONFIG_DIR#g" \
    "$_pfile" || true
done

# 1c) Seed the baked default CLAUDE.md (security posture + .workspace architecture)
#     as user-level memory so every bot loads it. A bot's own work-dir CLAUDE.md
#     layers on top. Copy if absent (covers fresh volumes AND existing bots on pull).
if [ -f /usr/local/share/claude-telegram/CLAUDE.md ] && [ ! -f "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]; then
  cp /usr/local/share/claude-telegram/CLAUDE.md "$CLAUDE_CONFIG_DIR/CLAUDE.md"
  echo "[entrypoint] seeded default CLAUDE.md into $CLAUDE_CONFIG_DIR"
fi

# 1d) Create the .workspace second-brain skeleton in the work dir (first run only).
if [ ! -d "$WORK_DIR/.workspace" ]; then
  mkdir -p "$WORK_DIR/.workspace"/{rules,memory,events,status}
  printf '# MEMORY.md — index of the bot durable memory\n\nEach line points to one file in memory/. Read it at the start of every session to get back in sync.\n' > "$WORK_DIR/.workspace/memory/MEMORY.md"
  echo "[entrypoint] created .workspace/{rules,memory,events,status} skeleton"
fi

# 1e) Role profile (BOT_ROLE): layer a specialized work-dir CLAUDE.md + settings +
#     rules on top of the baked base. Unset / empty / "default" or an unknown role →
#     DO NOTHING (default behavior unchanged). Idempotent: only seeds the work-dir
#     CLAUDE.md when the bot has none (never clobber a per-bot file); the settings
#     merge is a union (safe to re-run every boot).
ROLE="${BOT_ROLE:-}"
ROLES_ROOT="/usr/local/share/claude-telegram/roles"
if [ -n "$ROLE" ] && [ "$ROLE" != "default" ]; then
  ROLE_SRC="$ROLES_ROOT/$ROLE"
  if [ -d "$ROLE_SRC" ]; then
    # a) seed the role CLAUDE.md as the bot's work-dir CLAUDE.md, only if absent.
    if [ -f "$ROLE_SRC/CLAUDE.md" ] && [ ! -f "$WORK_DIR/CLAUDE.md" ]; then
      cp "$ROLE_SRC/CLAUDE.md" "$WORK_DIR/CLAUDE.md"
      echo "[entrypoint] role '$ROLE': seeded CLAUDE.md -> $WORK_DIR/CLAUDE.md"
    fi
    # b) jq-merge settings-fragment.json into the bot's settings.json
    #    (union enabledPlugins + permissions.allow; never clobber existing / disable base plugins).
    _frag="$ROLE_SRC/settings-fragment.json"
    _cfg="$CLAUDE_CONFIG_DIR/settings.json"
    if [ -f "$_frag" ] && [ -f "$_cfg" ]; then
      _tmp="$(mktemp)"
      if jq -s '
        .[0] as $b | .[1] as $f | $b
        | .enabledPlugins = ((.enabledPlugins // {}) + ($f.enabledPlugins // {}))
        | .permissions = (.permissions // {})
        | .permissions.allow = (((.permissions.allow // []) + ($f.permissions.allow // [])) | unique)
      ' "$_cfg" "$_frag" > "$_tmp" 2>/dev/null; then
        mv "$_tmp" "$_cfg"
        echo "[entrypoint] role '$ROLE': merged settings-fragment.json into settings.json"
      else
        rm -f "$_tmp"
        echo "[entrypoint] role '$ROLE': WARN settings-fragment merge failed (kept existing settings.json)"
      fi
    fi
    # c) seed role behavior rules into .workspace/rules/ (skip files already there).
    if [ -d "$ROLE_SRC/rules" ]; then
      mkdir -p "$WORK_DIR/.workspace/rules"
      for _r in "$ROLE_SRC/rules/"*.md; do
        [ -f "$_r" ] || continue
        _dest="$WORK_DIR/.workspace/rules/$(basename "$_r")"
        [ -f "$_dest" ] || cp "$_r" "$_dest"
      done
      echo "[entrypoint] role '$ROLE': seeded rules -> $WORK_DIR/.workspace/rules/"
    fi
    echo "[entrypoint] role profile applied: $ROLE"
  else
    echo "[entrypoint] NOTE: BOT_ROLE='$ROLE' requested but no roles/$ROLE in image -> ignoring (default behavior)"
  fi
fi

# 2) Seed the telegram plugin token file (gitignored secret) — first run only.
if [ ! -f "$TELEGRAM_STATE_DIR/.env" ]; then
  umask 077
  printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TELEGRAM_BOT_TOKEN" > "$TELEGRAM_STATE_DIR/.env"
fi

# 3) Seed access.json: owner-only allowlist (no pairing) — first run only.
if [ ! -f "$TELEGRAM_STATE_DIR/access.json" ]; then
  BOT_USERNAME="$(curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null | jq -r '.result.username // empty' || true)"
  MENTION="@${BOT_USERNAME}"
  jq -n --arg owner "$OWNER_ID" --arg mention "$MENTION" '{
    dmPolicy: "allowlist",
    allowFrom: [$owner],
    groups: {},
    pending: {},
    mentionPatterns: (if $mention == "@" then [] else [$mention] end)
  }' > "$TELEGRAM_STATE_DIR/access.json"
  echo "[entrypoint] seeded access.json (allowlist, owner=$OWNER_ID, mention=$MENTION)"
fi

# 3b) Skip Claude's first-run onboarding wizard + pre-trust WORK_DIR so the detached
#     `claude --channels` (no TTY) boots straight through. Idempotent (self-heals
#     pre-existing volumes). Written to both the volume config and botuser's home
#     (path depends on the claude version).
mark_onboarded() {
  local cfg="$1" tmp
  mkdir -p "$(dirname "$cfg")"
  if [ -s "$cfg" ]; then
    tmp="$(mktemp)"
    if jq --arg wd "$WORK_DIR" '. + {hasCompletedOnboarding: true, lastOnboardingVersion: "2.1.195", bypassPermissionsModeAccepted: true} | .projects[$wd] = ((.projects[$wd] // {}) + {hasTrustDialogAccepted: true})' "$cfg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$cfg"
    else
      rm -f "$tmp"
    fi
  else
    jq -n --arg wd "$WORK_DIR" '{hasCompletedOnboarding:true,lastOnboardingVersion:"2.1.195",bypassPermissionsModeAccepted:true,projects:{($wd):{hasTrustDialogAccepted:true}}}' > "$cfg"
  fi
}
mark_onboarded "$CLAUDE_CONFIG_DIR/.claude.json"
mark_onboarded "$BOT_HOME/.claude.json"

# 4) Hand ownership of the volumes + config to botuser so the non-root claude
#    session can read/write them (needed for both fresh and pre-existing volumes).
chown -R "$BOT_USER":"$BOT_USER" "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" "$BOT_HOME/.claude.json" 2>/dev/null || true

# 5) Auth: log in once with the NORMAL interactive login — creds persist on the
#    volume ($CLAUDE_CONFIG_DIR) and survive restarts. Run it AS botuser so the
#    credentials are owned by botuser (the user the bot runs as):
#      docker exec -it -u botuser <name> claude auth login
#    ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN env vars still work as a fallback.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if ! gosu "$BOT_USER" env HOME="$BOT_HOME" claude auth status >/dev/null 2>&1; then
    echo "[entrypoint] NOTE: not logged in → run:  docker exec -it -u botuser <name> claude auth login"
  fi
fi

# 6) Permission policy. Configurable via PERMISSION_MODE env
#    (auto|default|acceptEdits|bypassPermissions|manual|plan). Defaults to `auto`:
#    Claude Code's classifier-gated Auto Mode — it auto-approves routine actions so
#    the bot runs unattended without hanging on prompts, while still BLOCKING risky/
#    production actions. (This is safer than bypassPermissions, which approves
#    everything with no checks.) Override with e.g. PERMISSION_MODE=acceptEdits.
#    Works because claude runs NON-ROOT (below) + the accept flag is baked (3b).
PERMISSION_MODE="${PERMISSION_MODE:-auto}"
# auto only for channel bots — acceptEdits hangs the reply tool (not an "edit") and
# stalls the poller (the 2026-07-18 "no bot responds" root cause). Force it.
case "$PERMISSION_MODE" in acceptEdits) echo "[entrypoint] WARN PERMISSION_MODE=acceptEdits stalls channel bots -> forcing auto"; PERMISSION_MODE=auto;; esac

# 6b) Start the cron daemon (as root, before the privilege drop). It runs both
#     bot-scheduled reminders AND the tg-watchdog poller self-heal. Write the
#     watchdog's runtime env so the cron job knows BOT_USER + the state dir.
printf 'BOT_USER=%s\nTELEGRAM_STATE_DIR=%s\n' "$BOT_USER" "$TELEGRAM_STATE_DIR" > /etc/default/tg-watchdog 2>/dev/null || true
if command -v cron >/dev/null 2>&1; then
  cron 2>/dev/null || service cron start 2>/dev/null || true
  echo "[entrypoint] cron daemon started (reminders + poller watchdog)"
fi

cd "$WORK_DIR"

# Build the claude command as a single string for `tmux new-session`.
CLAUDE_CMD="claude --channels plugin:telegram@claude-plugins-official"
[ -n "$PERMISSION_MODE" ] && CLAUDE_CMD="$CLAUDE_CMD --permission-mode $PERMISSION_MODE"
[ -n "${MODEL:-}" ] && CLAUDE_CMD="$CLAUDE_CMD --model $MODEL"

echo "[entrypoint] starting claude --channels in tmux session 'claude' as $BOT_USER (cwd=$WORK_DIR, permission-mode=${PERMISSION_MODE})"
echo "[entrypoint] xem session:  docker exec -it -u $BOT_USER <container> tmux attach -t claude   (thoát an toàn: Ctrl+B rồi D)"

# Run claude INSIDE a tmux session named 'claude' so it can be monitored live via
# `tmux attach` (detach safely with Ctrl+B D — never kills the bot). tmux is PID 1's
# foreground process (needs tty:true / -it). When claude exits the session ends →
# tmux exits → container exits → restart policy restarts it.
launch_session() {
  gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" WORK_DIR="$WORK_DIR" \
    tmux -u new-session -d -s claude "$CLAUDE_CMD"
}
poller_up() {
  local pid; pid="$(cat "$TELEGRAM_STATE_DIR/bot.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && [ -d "/proc/$pid" ]
}
launch_session
# v2 startup self-check: give claude --channels ~40s to bring the poller up; if
# bot.pid never appears (the flaky non-start), restart the session once.
for _ in $(seq 1 8); do sleep 5; poller_up && break; done
if ! poller_up; then
  echo "[entrypoint] poller did not come up in ~40s -> restarting session once"
  gosu "$BOT_USER" env HOME="$BOT_HOME" tmux kill-session -t claude 2>/dev/null || true
  sleep 2; launch_session
fi
echo "[entrypoint] claude --channels session live; attaching to keep PID 1 alive"
# Keep PID 1 alive + tie container lifecycle to the tmux session (exit -> container
# exits -> restart policy respawns -> this self-check runs again).
exec gosu "$BOT_USER" env HOME="$BOT_HOME" tmux -u attach -t claude
