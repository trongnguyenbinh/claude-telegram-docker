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

# --- system deps (gosu = privilege drop root -> botuser; cron = scheduled reminders) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq tini bash unzip gosu tmux openssh-client cron \
    && rm -rf /var/lib/apt/lists/*

# --- gh CLI (GitHub: clone/pull/push, gh run list / GH Actions) via GitHub's apt repo ---
RUN mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# --- UTF-8 locale so the tmux session renders Vietnamese (and other non-ASCII)
#     correctly when the owner attaches. debian-slim defaults to the C locale,
#     which mangles multi-byte UTF-8. C.UTF-8 is built in (no locales pkg needed). ---
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8

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

# --- Default reasoning effort: high — bots think deeper by default. Only seeds
# FRESH volumes (existing bots keep whatever effortLevel their /data settings has;
# change a running bot via its /data/.claude/settings.json + restart).
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.effortLevel = "high"' "$cfg" > "$tmp" && mv "$tmp" "$cfg" \
 && jq -e '.effortLevel == "high"' "$cfg" >/dev/null

# --- SessionStart hook: auto-load the bot's .workspace context every session start
# (and after compaction) so a fresh session post-recreate knows what it was doing +
# who it reports to, instead of starting "blank". stdout is injected as context.
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"startup","hooks":[{"type":"command","command":"tg-session-context"}]},{"matcher":"compact","hooks":[{"type":"command","command":"tg-session-context"}]}])' "$cfg" > "$tmp" \
 && mv "$tmp" "$cfg" \
 && grep -q "tg-session-context" "$cfg"

# --- Bake default security permissions into the staged settings.json ---
# deny reading secrets in the work dir / cloned repos (cwd-anchored, so the bot's
# own /data/telegram/.env token is NOT blocked) + a few destructive circuit-breakers.
# allow routine read-only git + gh so bots don't prompt on them.
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.permissions.deny = ((.permissions.deny // []) + ["Read(.env)","Read(.env.*)","Read(**/.env)","Read(**/.env.*)","Read(**/secrets/**)","Read(**/id_rsa)","Read(**/id_ed25519)","Read(**/*.pem)","Bash(rm -rf /)","Bash(rm -rf /*)","Bash(rm -rf ~)","Bash(mkfs *)","Bash(dd if=* of=/dev/*)"]) | .permissions.allow = ((.permissions.allow // []) + ["Bash(git status)","Bash(git diff *)","Bash(git log *)","Bash(git branch *)","Bash(gh *)"])' "$cfg" > "$tmp" && mv "$tmp" "$cfg" \
 && jq -e '.permissions.deny | index("Read(**/.env)")' "$cfg" >/dev/null

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
# bun on the global PATH too (harmless; botuser already has it on PATH).
# node -> bun: the caveman plugin's hooks run `node <script>`; base has no node,
# so alias node to bun (bun runs node-style hook scripts) → caveman hooks work.
RUN ln -sf /home/botuser/.bun/bin/bun /usr/local/bin/bun \
 && ln -sf /home/botuser/.bun/bin/bun /usr/local/bin/node

# Claude Code v2.1+ gates `--channels` behind managed settings for some auth/org
# modes. The container is the managed runtime, so bake the Telegram channel policy
# at the Linux system-managed settings path before the non-root session starts.
RUN mkdir -p /etc/claude-code \
 && printf '%s\n' '{"channelsEnabled":true,"allowedChannelPlugins":[{"marketplace":"claude-plugins-official","plugin":"telegram"}]}' > /etc/claude-code/managed-settings.json \
 && jq -e '.channelsEnabled == true and (.allowedChannelPlugins | index({"marketplace":"claude-plugins-official","plugin":"telegram"}))' /etc/claude-code/managed-settings.json >/dev/null

COPY scripts/tg-access /usr/local/bin/tg-access
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Default base CLAUDE.md (security + .workspace architecture) — entrypoint seeds it
# to $CLAUDE_CONFIG_DIR/CLAUDE.md (user-level memory) so every bot loads it; a bot's
# own work-dir CLAUDE.md layers on top.
COPY scripts/default-CLAUDE.md /usr/local/share/claude-telegram/CLAUDE.md
# Role profiles (BOT_ROLE=ba|planner|dev-fe|dev-be|tester). Text files only; the
# entrypoint seeds the matching role's CLAUDE.md/settings-fragment/rules on first run
# when BOT_ROLE is set. Unset/empty/default = base behavior unchanged. See roles/README.md.
COPY roles/ /usr/local/share/claude-telegram/roles/
# Ops tooling: bot-doctor (on-demand diagnosis) + tg-healthcheck (Docker HEALTHCHECK liveness).
COPY scripts/bot-doctor /usr/local/bin/bot-doctor
COPY scripts/tg-healthcheck /usr/local/bin/tg-healthcheck
COPY scripts/tg-watchdog /usr/local/bin/tg-watchdog
COPY scripts/tg-session-context /usr/local/bin/tg-session-context
RUN chmod +x /usr/local/bin/tg-access /usr/local/bin/entrypoint.sh /usr/local/bin/bot-doctor /usr/local/bin/tg-healthcheck /usr/local/bin/tg-watchdog /usr/local/bin/tg-session-context \
 && printf '* * * * * root /usr/local/bin/tg-watchdog >> /tmp/tg-watchdog.log 2>&1\n' > /etc/cron.d/tg-watchdog \
 && chmod 0644 /etc/cron.d/tg-watchdog

# Liveness check: mark the container unhealthy if the tmux 'claude' session dies.
# (Poller stalls leave the session alive — use `docker exec <c> bot-doctor` for those.)
HEALTHCHECK --interval=60s --timeout=10s --start-period=90s --retries=3 \
  CMD /usr/local/bin/tg-healthcheck

# --- runtime config: config + state live on the volume so login + access persist ---
ENV CLAUDE_CONFIG_DIR=/data/.claude \
    TELEGRAM_STATE_DIR=/data/telegram
VOLUME /data

# claude --channels is an interactive TUI → run with -it / tty:true.
# ENTRYPOINT runs as root; entrypoint.sh chowns the volumes then `exec gosu botuser`.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
