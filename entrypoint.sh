#!/usr/bin/env bash
# Seed state, chown the mounted volumes, then DROP to a non-root user (botuser)
# and hand off to `claude --channels`. Starts as root ONLY to chown the volumes;
# claude itself runs as botuser so `--permission-mode bypassPermissions` (Auto
# Mode) is allowed (Claude blocks --dangerously-skip-permissions under root).
# See SPEC.md §6/§7/§8.
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required (docker run -e ...)}"
: "${OWNER_ID:?OWNER_ID required (docker run -e ...)}"

BOT_USER="${BOT_USER:-botuser}"
BOT_HOME="${BOT_HOME:-/home/botuser}"
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/data/.claude}"
TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-/data/telegram}"
CLAUDE_STAGE="${CLAUDE_STAGE:-$BOT_HOME/claude-stage}"
# Working directory the bot's claude session runs in (file ops land here).
WORK_DIR="${WORK_DIR:-/working-directory/claude-telegram-bot}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/approved" "$WORK_DIR"

# 1) Seed baked Claude config (settings.json + plugins/ tree) from image staging
#    -> volume config, first run only. cp -a preserves botuser ownership.
if [ ! -d "$CLAUDE_CONFIG_DIR/plugins" ] && [ -d "$CLAUDE_STAGE/plugins" ]; then
  echo "[entrypoint] seeding baked Claude config into $CLAUDE_CONFIG_DIR"
  cp -a "$CLAUDE_STAGE/." "$CLAUDE_CONFIG_DIR/"
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
chown -R "$BOT_USER":"$BOT_USER" /data 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" /working-directory 2>/dev/null || true
chown -R "$BOT_USER":"$BOT_USER" "$WORK_DIR" 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" "$BOT_HOME/.claude.json" 2>/dev/null || true

# 5) Auth: log in once with the NORMAL interactive login — creds persist on the
#    volume ($CLAUDE_CONFIG_DIR) and survive restarts. Run it AS botuser so the
#    credentials are owned by botuser (the user the bot runs as):
#      docker exec -it -u botuser <name> claude auth login
#    ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN env vars still work as a fallback.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if ! gosu "$BOT_USER" env HOME="$BOT_HOME" claude auth status >/dev/null 2>&1; then
    echo "[entrypoint] NOTE: chưa đăng nhập → chạy:  docker exec -it -u botuser <name> claude auth login"
  fi
fi

# 6) Permission policy. Configurable via PERMISSION_MODE env
#    (default|acceptEdits|bypassPermissions|plan). bypassPermissions (Auto Mode)
#    works now because claude runs NON-ROOT (below) + the accept flag is baked (3b).
PERMISSION_MODE="${PERMISSION_MODE:-}"

cd "$WORK_DIR"
echo "[entrypoint] starting claude --channels (telegram)… as $BOT_USER (cwd=$WORK_DIR, permission-mode=${PERMISSION_MODE:-default})"
exec gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" WORK_DIR="$WORK_DIR" \
  claude --channels plugin:telegram@claude-plugins-official \
  ${PERMISSION_MODE:+--permission-mode "$PERMISSION_MODE"} \
  ${MODEL:+--model "$MODEL"}
