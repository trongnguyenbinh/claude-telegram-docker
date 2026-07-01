# Claude Telegram Bot — "bot-in-a-box"
# 1 image = 1 bot. See SPEC.md.
# Base: plain debian-slim — no node needed (claude is a native binary, the
# telegram plugin's MCP server runs on bun).
#
# Runs as a NON-ROOT user (`botuser`) so `--permission-mode bypassPermissions`
# (Auto Mode) is allowed — Claude blocks --dangerously-skip-permissions under root.
# entrypoint starts as root (to chown the mounted volumes) then drops to botuser
# via gosu before exec'ing `claude --channels`.
FROM debian:bookworm-slim

# --- system deps (gosu = privilege drop root -> botuser) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq tini bash unzip gosu tmux openssh-client \
    && rm -rf /var/lib/apt/lists/*

# --- non-root user ---
RUN useradd -m -u 1000 -s /bin/bash botuser
ENV BOT_USER=botuser BOT_HOME=/home/botuser

# Install claude + bun + the baked plugin AS botuser so they live in the user's
# home and are owned/executable by botuser at runtime.
USER botuser
WORKDIR /home/botuser
ENV HOME=/home/botuser

# --- bun (telegram plugin runs its MCP server with `bun server.ts`) ---
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/botuser/.local/bin:/home/botuser/.bun/bin:${PATH}"

# --- Claude Code CLI (native installer; the npm package is deprecated) ---
# TODO: pin a version (`… | bash -s -- <version>`) so the baked plugin stays compatible.
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN claude --version

# --- Bake plugins into a staging config dir (owned by botuser) ---
# `owner/repo` clones via SSH (no key in build) → add by HTTPS URL + force github SSH→HTTPS.
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
ENV CLAUDE_STAGE=/home/botuser/claude-stage
# Marketplaces: claude-plugins-official (telegram/frontend-design/superpowers) + caveman.
RUN mkdir -p "$CLAUDE_STAGE" \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin marketplace add https://github.com/JuliusBrussee/caveman.git \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install telegram@claude-plugins-official \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install frontend-design@claude-plugins-official \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install superpowers@claude-plugins-official \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install caveman@caveman \
 && test -d "$CLAUDE_STAGE/plugins" && test -f "$CLAUDE_STAGE/settings.json"

# --- rtk (Rust token-killer): CLI binary + Claude Code hook (rewrites bash → rtk, saves tokens) ---
# Not a plugin — a standalone binary that hooks into Claude Code. Install binary for botuser,
# then seed its hook into the staged config so the bot picks it up.
RUN curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
# Wire rtk's PreToolUse/Bash rewrite hook into the staged config (rtk init -g doesn't
# persist to CLAUDE_STAGE); seeds to the bot's /data/.claude/settings.json on first run.
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}])' "$cfg" > "$tmp" \
 && mv "$tmp" "$cfg" \
 && grep -q "rtk hook claude" "$cfg"

# Bake "onboarding complete" so fresh volumes never hit the first-run wizard
# (theme picker), which would hang a detached `claude --channels`.
RUN if [ -s "$CLAUDE_STAGE/.claude.json" ]; then \
      jq '. + {hasCompletedOnboarding:true,lastOnboardingVersion:"2.1.195",bypassPermissionsModeAccepted:true}' "$CLAUDE_STAGE/.claude.json" > "$CLAUDE_STAGE/.claude.json.tmp" \
        && mv "$CLAUDE_STAGE/.claude.json.tmp" "$CLAUDE_STAGE/.claude.json"; \
    else \
      printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.195","bypassPermissionsModeAccepted":true}\n' > "$CLAUDE_STAGE/.claude.json"; \
    fi

# --- back to root for scripts + entrypoint (entrypoint drops to botuser itself) ---
USER root
# bun on the global PATH too (harmless; botuser already has it on PATH)
RUN ln -sf /home/botuser/.bun/bin/bun /usr/local/bin/bun

COPY scripts/tg-access /usr/local/bin/tg-access
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/tg-access /usr/local/bin/entrypoint.sh

# --- runtime config: config + state live on the volume so login + access persist ---
ENV CLAUDE_CONFIG_DIR=/data/.claude \
    TELEGRAM_STATE_DIR=/data/telegram
VOLUME /data

# claude --channels is an interactive TUI → run with -it / tty:true.
# ENTRYPOINT runs as root; entrypoint.sh chowns the volumes then `exec gosu botuser`.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
