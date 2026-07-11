# Contributing to claude-telegram-docker

Thanks for helping. This project packages a Claude-Code-powered Telegram bot as a
single Docker image (**1 image = 1 bot**). Contributions of all sizes are welcome —
typo fixes to new features.

## Getting Started

```bash
# Fork on GitHub, then clone your fork
git clone https://github.com/<your-username>/claude-telegram-docker.git
cd claude-telegram-docker
git remote add upstream https://github.com/trongnguyenbinh/claude-telegram-docker.git
```

There is **no local build step required to contribute** — the image is built by CI
(GitHub Actions, `.github/workflows/docker-publish.yml`) for `linux/amd64` +
`linux/arm64`. You generally do NOT need Docker locally. If you want to build
locally to test, use `docker build .` (base) or `docker build -f Dockerfile.playwright .`.

## How to verify a change (there are no unit tests)

This repo is Docker + Bash, not application code. "Tests" = build + behavior on a
real bot. Before opening a PR, confirm:

1. **CI build is green** — both jobs: `build-and-push` (base) and `build-playwright`
   (the `:playwright` variant, which is built `FROM` the base).
2. **The bot boots + works on a real container** — run `docker exec <bot> bot-doctor`;
   all checks should pass (tmux session, permission mode `auto`, poller `pending=0`,
   UTF-8 locale, base CLAUDE.md, `.workspace/`, login).
3. **For `:playwright` changes** — verify a screenshot actually renders (as `botuser`):
   `docker exec -u botuser <bot> bash -lc 'node $(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js screenshot https://example.com /tmp/t.png; ls -la /tmp/t.png'`.
4. **After any entrypoint/Dockerfile change** — recreate a bot from the new image and
   confirm `getWebhookInfo`'s `pending_update_count` drains to 0 (poller not stalled;
   see `OPERATIONS.md`).

Evidence before assertions: don't claim "works" without one of the checks above.

## Project Structure

```
Dockerfile              ← base image (debian-slim + bun + claude + baked plugins/config)
Dockerfile.playwright   ← :playwright variant (FROM base + Node + Chromium)
entrypoint.sh           ← first-run seeding (idempotent, self-healing) + launch in tmux
scripts/                ← baked tools: tg-access, bot-doctor, tg-healthcheck,
                          tg-watchdog, default-CLAUDE.md
roles/                  ← role profiles (BOT_ROLE): per-role CLAUDE.md +
                          settings-fragment.json + optional rules/ (see roles/README.md)
.github/workflows/      ← CI (build + push both image variants)
SPEC.md · README.md · README.en.md · CHEATSHEET.md · OPERATIONS.md
```

## PR Guidelines

1. Create a feature branch: `git checkout -b feat/my-thing` (or `fix/…`, `docs/…`).
2. Make the change. Update docs when you change behavior (README / README.en /
   CHEATSHEET / OPERATIONS), and bump the version header in the READMEs if it's a
   release-worthy feature.
3. Verify it (see "How to verify" above).
4. Commit with [Conventional Commits](https://www.conventionalcommits.org/) +
   co-author trailer:
   - `feat(image): bake gh CLI`
   - `fix(playwright): match Chromium revision to the MCP`
   - `docs: document the :playwright variant`
   - end the message with `Co-Authored-By: <name> <email>`
5. Push to your fork and open a PR against `main`. Describe what you changed and how
   you verified it. CI must be green before merge.

**Bots / AI agents contributing** (this project's own bots have `gh` access): open a
PR, never push straight to `main`; follow the security rules in the baked base
CLAUDE.md (owner-only authority, no secret leakage, verify before claiming done).

## Versioning & Releases

- Semantic versioning, tags `vX.Y.Z`. Pushing a `v*` tag triggers a versioned image build.
- Each release gets GitHub release notes summarizing the change (`gh release create`).
- Both image variants ship together: `:latest` (+ `:sha`) and `:playwright`.
- Patch (`x.y.Z`) = bugfix; minor (`x.Y.0`) = new feature; major = breaking change to
  env/volumes/behavior.

## Code Style

- **Bash**: keep scripts POSIX-friendly and `shellcheck`-clean; quote variables; the
  ops scripts must work whether exec'd as root or `botuser` (they `gosu` when root).
- **Dockerfile**: a multi-line `jq`/command inside one `RUN` needs a trailing `\` on
  **every** line, or Docker ends the instruction early — prefer a single line.
- **entrypoint.sh**: every step must be **idempotent** and self-heal pre-existing
  volumes (it runs on every boot, not just first run). Never assume a fresh volume.
- **Image size**: keep the base lean. Heavy deps (browsers, node) go in a variant
  (`Dockerfile.playwright`), never the base.
- **MCP-bundled tools**: install a tool's browser/runtime via the tool's OWN bundled
  version, never a separately-pinned global (versions drift — see `OPERATIONS.md`).

## Adding a role

Role profiles (`BOT_ROLE=ba|planner|dev-fe|dev-be|tester`) live in [`roles/`](./roles/).
To add one, create `roles/<role>/` with a `CLAUDE.md` (the role's "how I work" rules,
layered on top of the base), a minimal valid `settings-fragment.json` (extra
`enabledPlugins` + `permissions.allow`, never disabling base plugins), and optionally
`rules/*.md`. No `entrypoint.sh` change is needed — it reads `$BOT_ROLE` dynamically and
`Dockerfile` already `COPY roles/`. Verify `jq . roles/<role>/settings-fragment.json`
parses and `bash -n entrypoint.sh` is clean, then update the role tables in the READMEs.
Full guide: [`roles/README.md`](./roles/README.md).

## Security

- **Never commit secrets.** `.gitignore` already excludes `.env`, `.env.*`,
  `.claude/telegram/`, `credentials.json`. Tokens live in env/volumes, never in git.
- Don't weaken the baked security defaults without discussion: owner-only access
  (`access.json` allowlist, no auto-pairing), `permissions.deny` for secrets +
  destructive commands, and the base CLAUDE.md (anti-injection, info-isolation).
- Access mutations happen via `docker exec … tg-access …` (an authenticated host
  channel), never in response to a Telegram message.

## Architecture Principles

- **1 image = 1 bot** — one token, one container, one `/data` volume (Telegram allows
  only one `getUpdates` poller per token).
- **Base lean, variants `FROM` base** — a feature added to the base is inherited by
  every variant (e.g. `:playwright`) for free.
- **Config via env + `docker exec`, not code** — permission mode, model, MCPs, access
  are runtime knobs; don't hardcode.
- **Durable state on volumes + mempalace** — the live `--channels` session context is
  disposable; anything worth keeping goes to `/data`, `.workspace/`, or mempalace.

If you're planning a significant change, open an issue first to discuss the approach.
