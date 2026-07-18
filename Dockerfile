# Claude Telegram Bot — "bot-in-a-box" (v2.2, WORKER transport).
# 1 image = 1 bot. See SPEC.md §v2.2.
#
# v2.2 drops `claude --channels` (its CLI channel-host poller was unreliable) and
# ships a Python Bot-API worker (scripts/tg-worker.py) as the container's main
# process: it owns Telegram getUpdates polling and invokes headless `claude -p`
# per message. No tmux, no telegram plugin, no cron — the worker also runs the
# reminder scheduler in a sibling thread.
#
# Single-volume layout: all state lives under ~/.claude (the only mounted volume):
#   ~/.claude/                 settings.json, CLAUDE.md, plugins/, auth
#   ~/.claude/telegram/        .env (token), access.json, sessions/, worker.log
#   ~/.claude/workspace/       session cwd, repo clones, reminders/
#
# Runs as NON-ROOT botuser. entrypoint starts as root ONLY to chown the volume,
# then drops to botuser via gosu before exec'ing the worker.
FROM debian:bookworm-slim

# --- system deps ---
#   gosu = privilege drop root -> botuser; python3 = the worker runtime (stdlib
#   only); tzdata = local timezone for the reminder scheduler; jq/git/gh/curl for
#   the entrypoint + bot ops. No tmux/cron in v2.2.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates jq tini bash unzip gosu openssh-client python3 tzdata procps \
    && rm -rf /var/lib/apt/lists/*

# --- gh CLI (GitHub: clone/pull/push, gh run list / GH Actions) via GitHub's apt repo ---
RUN mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# --- Timezone: the reminder scheduler fires on container local wall-clock time.
#     Fixed to Asia/Ho_Chi_Minh (override with -e TZ=... + a matching /etc/localtime). ---
ENV TZ=Asia/Ho_Chi_Minh
RUN ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone

# --- UTF-8 locale so Vietnamese (and other non-ASCII) renders correctly. ---
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8

# --- non-root user ---
RUN useradd -m -u 1000 -s /bin/bash botuser
ENV BOT_USER=botuser BOT_HOME=/home/botuser

# Install claude + bun + baked plugins AS botuser so they live in the user's home
# (outside the ~/.claude volume, so the volume mount never shadows the binaries).
USER botuser
WORKDIR /home/botuser
ENV HOME=/home/botuser

# --- bun (some plugin hooks / tooling run on bun; also the node->bun shim below) ---
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/botuser/.local/bin:/home/botuser/.bun/bin:${PATH}"

# --- Claude Code CLI (native installer; the npm package is deprecated) ---
# TODO: pin a version (`… | bash -s -- <version>`) so the baked plugins stay compatible.
RUN curl -fsSL https://claude.ai/install.sh | bash
RUN claude --version

# --- Bake plugins into a staging config dir (owned by botuser) ---
# NOTE: the telegram plugin is intentionally NOT installed in v2.2 — the worker
# owns the Bot API directly. We keep general-purpose plugins (superpowers,
# frontend-design, caveman). A shared-memory MCP (mempalace) is added per-bot at
# runtime (it needs a per-bot bearer token, so it can't be baked) — see docs.
RUN git config --global url."https://github.com/".insteadOf "git@github.com:" \
 && git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
ENV CLAUDE_STAGE=/home/botuser/claude-stage
RUN mkdir -p "$CLAUDE_STAGE" \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin marketplace add https://github.com/JuliusBrussee/caveman.git \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install frontend-design@claude-plugins-official \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install superpowers@claude-plugins-official \
 && CLAUDE_CONFIG_DIR="$CLAUDE_STAGE" claude plugin install caveman@caveman \
 && test -d "$CLAUDE_STAGE/plugins" && test -f "$CLAUDE_STAGE/settings.json"

# --- Default reasoning effort: high — bots think deeper by default. Seeds FRESH
# volumes only (existing bots keep their /~/.claude settings). ---
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.effortLevel = "high"' "$cfg" > "$tmp" && mv "$tmp" "$cfg" \
 && jq -e '.effortLevel == "high"' "$cfg" >/dev/null

# --- SessionStart hook: auto-load the bot's .workspace context at the start of
# EVERY `claude -p` turn (stdout is injected as context) so each ephemeral turn
# knows its durable memory + what it was doing. ---
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"startup","hooks":[{"type":"command","command":"tg-session-context"}]},{"matcher":"compact","hooks":[{"type":"command","command":"tg-session-context"}]}])' "$cfg" > "$tmp" \
 && mv "$tmp" "$cfg" \
 && grep -q "tg-session-context" "$cfg"

# --- Bake default security permissions into the staged settings.json ---
# deny reading secrets in the work dir / cloned repos (cwd-anchored, so the bot's
# own ~/.claude/telegram/.env token is NOT blocked) + destructive circuit-breakers.
# allow routine read-only git + gh so bots don't prompt on them.
RUN cfg="$CLAUDE_STAGE/settings.json"; tmp="$(mktemp)"; \
    jq '.permissions.deny = ((.permissions.deny // []) + ["Read(.env)","Read(.env.*)","Read(**/.env)","Read(**/.env.*)","Read(**/secrets/**)","Read(**/id_rsa)","Read(**/id_ed25519)","Read(**/*.pem)","Bash(rm -rf /)","Bash(rm -rf /*)","Bash(rm -rf ~)","Bash(mkfs *)","Bash(dd if=* of=/dev/*)"]) | .permissions.allow = ((.permissions.allow // []) + ["Bash(git status)","Bash(git diff *)","Bash(git log *)","Bash(git branch *)","Bash(gh *)"])' "$cfg" > "$tmp" && mv "$tmp" "$cfg" \
 && jq -e '.permissions.deny | index("Read(**/.env)")' "$cfg" >/dev/null

# Bake "onboarding complete" so fresh volumes never hit the first-run wizard.
RUN if [ -s "$CLAUDE_STAGE/.claude.json" ]; then \
      jq '. + {hasCompletedOnboarding:true,lastOnboardingVersion:"2.1.195",bypassPermissionsModeAccepted:true}' "$CLAUDE_STAGE/.claude.json" > "$CLAUDE_STAGE/.claude.json.tmp" \
        && mv "$CLAUDE_STAGE/.claude.json.tmp" "$CLAUDE_STAGE/.claude.json"; \
    else \
      printf '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.1.195","bypassPermissionsModeAccepted":true}\n' > "$CLAUDE_STAGE/.claude.json"; \
    fi

# --- back to root for scripts + entrypoint (entrypoint drops to botuser itself) ---
USER root
# node -> bun shim: the caveman plugin's hooks run `node <script>`; base has no node.
RUN ln -sf /home/botuser/.bun/bin/bun /usr/local/bin/bun \
 && ln -sf /home/botuser/.bun/bin/bun /usr/local/bin/node

# NOTE (v2.2): the /etc/claude-code/managed-settings.json block (channelsEnabled +
# telegram plugin allowlist) was DROPPED. It only gated `claude --channels`, which
# v2.2 no longer uses — headless `claude -p` does not need channels enabled.

COPY scripts/tg-access /usr/local/bin/tg-access
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# Default base CLAUDE.md (security + worker behavioral rules) — entrypoint seeds it
# to $CLAUDE_CONFIG_DIR/CLAUDE.md (user-level memory) so every `claude -p` turn loads it.
COPY scripts/default-CLAUDE.md /usr/local/share/claude-telegram/CLAUDE.md
# Role profiles (BOT_ROLE=ba|planner|dev-fe|dev-be|tester|infra). See roles/README.md.
COPY roles/ /usr/local/share/claude-telegram/roles/
# The worker (main process) + reminder CLI + ops tooling + SessionStart hook.
COPY scripts/tg-worker.py /usr/local/bin/tg-worker.py
COPY scripts/tg-reminder /usr/local/bin/tg-reminder
COPY scripts/bot-doctor /usr/local/bin/bot-doctor
COPY scripts/tg-healthcheck /usr/local/bin/tg-healthcheck
COPY scripts/tg-session-context /usr/local/bin/tg-session-context
RUN chmod +x /usr/local/bin/tg-access /usr/local/bin/entrypoint.sh /usr/local/bin/tg-worker.py \
      /usr/local/bin/tg-reminder /usr/local/bin/bot-doctor /usr/local/bin/tg-healthcheck /usr/local/bin/tg-session-context

# Liveness: mark unhealthy if the worker process dies OR its heartbeat goes stale.
HEALTHCHECK --interval=60s --timeout=10s --start-period=60s --retries=3 \
  CMD /usr/local/bin/tg-healthcheck

# --- runtime config: everything on a single ~/.claude volume ---
ENV CLAUDE_CONFIG_DIR=/home/botuser/.claude \
    TELEGRAM_STATE_DIR=/home/botuser/.claude/telegram \
    WORK_DIR=/home/botuser/.claude/workspace
VOLUME /home/botuser/.claude

# The worker is a headless daemon (no TTY needed). ENTRYPOINT runs as root; the
# entrypoint chowns the volume then `exec gosu botuser python3 tg-worker.py`.
ENTRYPOINT ["/usr/bin/tini","--","/usr/local/bin/entrypoint.sh"]
