#!/usr/bin/env bash
# entrypoint (v2.2 — worker transport). Seed a fresh ~/.claude volume from the
# baked image defaults (CLEAN INSTALL — no copy-migration from a v1 /data volume),
# chown it to botuser, then DROP to botuser and exec the Python Bot-API worker
# (tg-worker.py). Starts as root ONLY to chown the volume + read env; the worker
# and every `claude -p` it spawns run as non-root botuser.
#
# Transport = tg-worker.py (getUpdates long-poll). There is NO `claude --channels`,
# NO tmux, NO telegram plugin, NO cron in v2.2. See SPEC.md §v2.2.
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN required (docker run -e ...)}"
: "${OWNER_ID:?OWNER_ID required (docker run -e ...)}"

BOT_USER="${BOT_USER:-botuser}"
BOT_HOME="${BOT_HOME:-/home/botuser}"
# v2.2 single-volume layout: everything under ~/.claude (the only mounted volume).
CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$BOT_HOME/.claude}"
TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$CLAUDE_CONFIG_DIR/telegram}"
WORK_DIR="${WORK_DIR:-$CLAUDE_CONFIG_DIR/workspace}"
CLAUDE_STAGE="${CLAUDE_STAGE:-$BOT_HOME/claude-stage}"
export CLAUDE_CONFIG_DIR TELEGRAM_STATE_DIR WORK_DIR

mkdir -p "$CLAUDE_CONFIG_DIR" "$TELEGRAM_STATE_DIR" "$TELEGRAM_STATE_DIR/sessions" \
         "$TELEGRAM_STATE_DIR/history" "$WORK_DIR" "$WORK_DIR/reminders"

# 1) Seed baked Claude config (settings.json + plugins/ tree) into the volume on
#    first boot only (fresh volume = no plugins dir yet). cp -a preserves ownership.
#    This is a clean install of the image defaults, NOT a migration of an old volume.
if [ ! -d "$CLAUDE_CONFIG_DIR/plugins" ] && [ -d "$CLAUDE_STAGE/plugins" ]; then
  echo "[entrypoint] seeding baked Claude config into $CLAUDE_CONFIG_DIR"
  cp -a "$CLAUDE_STAGE/." "$CLAUDE_CONFIG_DIR/"
fi

# 1b) Normalize plugin install paths -> the runtime config dir (self-heals the
#     staging-vs-runtime path drift → avoids "Failed to load marketplace: cache-miss").
for _pf in known_marketplaces.json installed_plugins.json; do
  _pfile="$CLAUDE_CONFIG_DIR/plugins/$_pf"
  [ -f "$_pfile" ] && sed -i \
    -e "s#/opt/claude-stage#$CLAUDE_CONFIG_DIR#g" \
    -e "s#${CLAUDE_STAGE}#$CLAUDE_CONFIG_DIR#g" \
    "$_pfile" || true
done

# 1c) Seed the baked default CLAUDE.md (security + worker behavioral rules) as
#     user-level memory. Every `claude -p` turn loads it. A bot's own work-dir
#     CLAUDE.md layers on top. Copy if absent (fresh volumes AND existing on pull).
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
#     rules on top of the baked base. Unset / empty / "default" / unknown -> no-op.
ROLE="${BOT_ROLE:-}"
ROLES_ROOT="/usr/local/share/claude-telegram/roles"
if [ -n "$ROLE" ] && [ "$ROLE" != "default" ]; then
  ROLE_SRC="$ROLES_ROOT/$ROLE"
  if [ -d "$ROLE_SRC" ]; then
    if [ -f "$ROLE_SRC/CLAUDE.md" ] && [ ! -f "$WORK_DIR/CLAUDE.md" ]; then
      cp "$ROLE_SRC/CLAUDE.md" "$WORK_DIR/CLAUDE.md"
      echo "[entrypoint] role '$ROLE': seeded CLAUDE.md -> $WORK_DIR/CLAUDE.md"
    fi
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

# 2) Seed the bot token file (gitignored secret) — first run only. The worker reads
#    TELEGRAM_BOT_TOKEN from here (per the spec), plus any provider keys you add.
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

# 3b) Skip Claude's first-run onboarding wizard + pre-trust WORK_DIR so headless
#     `claude -p` never blocks on a theme/trust dialog. Idempotent.
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

# 4) Hand the volume to botuser (both fresh + pre-existing).
chown -R "$BOT_USER":"$BOT_USER" "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
chown "$BOT_USER":"$BOT_USER" "$BOT_HOME/.claude.json" 2>/dev/null || true

# 5) Auth note. The worker forces the Claude SUBSCRIPTION (it pops ANTHROPIC_API_KEY);
#    provide CLAUDE_CODE_OAUTH_TOKEN via env, or log in once with:
#      docker exec -it -u botuser <name> claude auth login
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  if ! gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" claude auth status >/dev/null 2>&1; then
    echo "[entrypoint] NOTE: not logged in -> run:  docker exec -it -u botuser <name> claude auth login  (or pass -e CLAUDE_CODE_OAUTH_TOKEN)"
  fi
fi

# 5b) Voice MCP auto-wire. If VOICE_API_URL + VOICE_API_KEY are set, register the
#     BAKED stdio voice proxy for botuser (idempotent). The bot then gets the
#     `voice` MCP tool (transcribe / speak / list_voices / voice_info) with no
#     manual pip/copy. NOTE: the worker already does inbound transcription and the
#     [[voice]] outbound reply itself via the Voice API — this MCP is only needed
#     when you want CLAUDE to call the voice tools directly (then also add
#     mcp__voice to TG_WORKER_ALLOWED_TOOLS).
if [ -n "${VOICE_API_URL:-}" ] && [ -n "${VOICE_API_KEY:-}" ]; then
  if gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
       claude mcp get voice >/dev/null 2>&1; then
    echo "[entrypoint] voice MCP already registered — skipping"
  elif gosu "$BOT_USER" env HOME="$BOT_HOME" CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
         claude mcp add voice --scope user \
           --env VOICE_API_URL="$VOICE_API_URL" \
           --env VOICE_API_KEY="$VOICE_API_KEY" \
           --env PYTHONPATH=/opt/voice-mcp-proxy \
           -- python3 -m voice_mcp_proxy >/dev/null 2>&1; then
    echo "[entrypoint] registered voice MCP for $BOT_USER (VOICE_API_URL set)"
  else
    echo "[entrypoint] WARN: could not register voice MCP (continuing without it)"
  fi
fi

# 6) Force the Claude subscription for every `claude -p` turn (never a metered key).
unset ANTHROPIC_API_KEY

echo "[entrypoint] starting tg-worker as $BOT_USER (config=$CLAUDE_CONFIG_DIR, state=$TELEGRAM_STATE_DIR, work=$WORK_DIR, model=${MODEL:-default}, perm=${TG_WORKER_PERMISSION_MODE:-${PERMISSION_MODE:-auto}})"

# Drop to botuser and exec the worker as the container's main process. gosu preserves
# the environment (MODEL / PERMISSION_MODE / TG_WORKER_* / CLAUDE_CODE_OAUTH_TOKEN pass
# through); HOME + the layout dirs are set explicitly.
exec gosu "$BOT_USER" env \
  HOME="$BOT_HOME" \
  CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" \
  TELEGRAM_STATE_DIR="$TELEGRAM_STATE_DIR" \
  WORK_DIR="$WORK_DIR" \
  python3 /usr/local/bin/tg-worker.py
