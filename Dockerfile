# Claude Telegram Bot — "bot-in-a-box"
# 1 image = 1 bot. See SPEC.md.
# Base: plain debian-slim — no node needed (claude is a native binary, the
# telegram plugin's MCP server runs on bun).
FROM debian:bookworm-slim

# --- system deps ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq tini bash unzip \
    && rm -rf /var/lib/apt/lists/*

# --- bun (telegram plugin runs its MCP server with `bun server.ts`) ---
RUN curl -fsSL https://bun.sh/install | bash \
    && ln -s /root/.bun/bin/bun /usr/local/bin/bun
ENV PATH="/root/.bun/bin:${PATH}"

# --- Claude Code CLI (native installer; the npm package is deprecated) ---
# Installs the native binary to $HOME/.local/bin. Put it on PATH and verify.
# TODO: pin a version (the script supports `… | bash -s -- <version>`) so the
# baked plugin below stays compatible across rebuilds.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"
RUN claude --version

# --- Bake the Telegram plugin into a staging config dir ---
# VERIFIED on POC (2026-06-26): `claude plugin marketplace add <src>` + `plugin install`.
# The `owner/repo` form clones via SSH (no key in build → fails), so we add by HTTPS
# URL and force any github SSH remote to HTTPS. Staged config (settings.json with
# enabledPlugins + the cloned plugins/ tree) is seeded onto the volume by entrypoint.
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
ENV CLAUDE_STAGE=/opt/claude-stage
RUN mkdir -p "$CLAUDE_STAGE" \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install telegram@claude-plugins-official \
 && test -d "$CLAUDE_STAGE/plugins" && test -f "$CLAUDE_STAGE/settings.json"

# Bake "onboarding complete" into the staged config so fresh volumes never hit the
# first-run wizard (theme picker), which would hang a detached `claude --channels`.
# entrypoint also re-applies this at boot (self-heals pre-existing volumes).
RUN if [ -s "$CLAUDE_STAGE/.claude.json" ]; then \
      jq '. + {hasCompletedOnboarding:true,lastOnboardingVersion:"2.1.195",bypassPermissionsModeAccepted:true}' "$CLAUDE_STAGE/.claude.json" > "$CLAUDE_STAGE/.claude.json.tmp" \
        && mv "$CLAUDE_STAGE/.claude.json.tmp" "$CLAUDE_STAGE/.claude.json"; \
    else \
      printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.195","bypassPermissionsModeAccepted":true}\n' > "$CLAUDE_STAGE/.claude.json"; \
    fi

# --- bot scripts ---
COPY scripts/tg-access /usr/local/bin/tg-access
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/tg-access /usr/local/bin/entrypoint.sh

# --- runtime config: config + state live on the volume so login + access persist ---
ENV CLAUDE_CONFIG_DIR=/data/.claude \
    TELEGRAM_STATE_DIR=/data/telegram
VOLUME /data

# claude --channels is an interactive TUI → container must be run with -it / tty:true.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
