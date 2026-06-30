#!/usr/bin/env bash
# Seed state onto the volume (first run) then hand off to claude --channels.
# See SPEC.md §6/§7/§8.
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required (docker run -e ...)}"
: "${OWNER_ID:?OWNER_ID required (docker run -e ...)}"

CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-/data/.claude}"
TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-/data/telegram}"
CLAUDE_STAGE="${CLAUDE_STAGE:-/opt/claude-stage}"
# Working directory the bot's claude session runs in (file ops land here).
WORK_DIR="${WORK_DIR:-/working-directory/claude-telegram-bot}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/approved" "$WORK_DIR"

# 1) Seed baked Claude config (settings.json with enabledPlugins + plugins/ tree)
#    from image staging -> volume config, first run only. Copies the WHOLE stage
#    tree (settings.json, .claude.json, plugins/) so the plugin loads at boot.
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

# 3b) Skip Claude Code's first-run onboarding wizard (theme picker etc.) AND
#     pre-trust the working directory. `claude --channels` runs detached (no TTY)
#     so nobody can answer the "Let's get started" wizard or the "trust this
#     folder?" dialog → either would hang it. Mark onboarding complete + trust
#     WORK_DIR so the channel server boots straight through. Idempotent (runs
#     every boot, self-heals pre-existing volumes). Written to both candidate
#     config locations since the path depends on the claude version.
mark_onboarded() {
  local cfg="$1" tmp
  mkdir -p "$(dirname "$cfg")"
  if [ -s "$cfg" ]; then
    tmp="$(mktemp)"
    if jq --arg wd "$WORK_DIR" '. + {hasCompletedOnboarding: true, lastOnboardingVersion: "2.1.195", bypassPermissionsModeAccepted: true} | .projects[$wd] = ((.projects[$wd] // {}) + {hasTrustDialogAccepted: true})' "$cfg" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$cfg"
    else
      rm -f "$tmp"   # malformed JSON → leave as-is rather than clobber
    fi
  else
    jq -n --arg wd "$WORK_DIR" '{hasCompletedOnboarding:true,lastOnboardingVersion:"2.1.195",bypassPermissionsModeAccepted:true,projects:{($wd):{hasTrustDialogAccepted:true}}}' > "$cfg"
  fi
}
mark_onboarded "$CLAUDE_CONFIG_DIR/.claude.json"
mark_onboarded "${HOME:-/root}/.claude.json"

# 4) Auth: log in once with `docker exec -it <bot> claude setup-token`
#    (recommended in-container — headless-friendly long-lived token). The OAuth
#    `claude auth login` flow tends to 400 in a container (no real browser / PKCE
#    state mismatch), so prefer setup-token. Creds persist under $CLAUDE_CONFIG_DIR
#    (on the volume) → survive restarts. ANTHROPIC_API_KEY, if set, is a fallback.
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if ! claude auth status >/dev/null 2>&1; then
    echo "[entrypoint] NOTE: not authenticated → set CLAUDE_CODE_OAUTH_TOKEN in .env"
    echo "[entrypoint]       (generate once: docker exec -it <name> claude setup-token)"
  fi
fi

# 5) Permission policy (no interactive prompts in a headless bot). Configurable
#    via PERMISSION_MODE env (default|acceptEdits|bypassPermissions|plan).
#    bypassPermissions needs the accept flag, already baked at 3b.
PERMISSION_MODE="${PERMISSION_MODE:-}"

cd "$WORK_DIR"
echo "[entrypoint] starting claude --channels (telegram)… (cwd=$WORK_DIR, permission-mode=${PERMISSION_MODE:-default})"
exec claude --channels plugin:telegram@claude-plugins-official \
  ${PERMISSION_MODE:+--permission-mode "$PERMISSION_MODE"} \
  ${MODEL:+--model "$MODEL"}
