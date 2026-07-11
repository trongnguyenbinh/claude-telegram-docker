# Role profiles — specialized bots

Each `claude-telegram-docker` bot can boot into a **specialized role** via the `BOT_ROLE`
environment variable. The roles come from an AI-agent delivery workflow (Define/BA → Planning
→ Build → Tester/QA), where **1 role = 1 bot**.

## Available roles

| `BOT_ROLE` | Stage | What the bot does |
|---|---|---|
| `ba` | 1 · Define | Business Analyst: elicit + clarify requirements, write user stories + acceptance criteria + a lightweight spec, build a UI prototype → deploy a preview for stakeholder feedback; on sign-off → create a tracked work item + commit the spec + sync the shared knowledge base + publish the handoff. |
| `planner` | 2 · Planning | Break an accepted parent item into area sub-tasks (`area:frontend/backend/db/infra/qa`) + description + estimate + link to parent → the board → publish + @mention the right owners. |
| `dev-fe` | 3 · Build (FE) | Pick up an `area:frontend` sub-task → branch → code UI → PR `Closes #issue`; gate-aware (quality + security); frontend-design + preview deploy + Playwright. |
| `dev-be` | 3 · Build (BE) | Pick up an `area:backend` sub-task → branch → code API/DB + migration → PR `Closes #issue`; migration/db + gate awareness. |
| `tester` | Tester/QA | From the release notes write test guidance + test cases; receive a bug report from the test site → cross-check the spec + shared knowledge base → if it looks like a real bug, publish to the channel + tag the lead. |

Not setting `BOT_ROLE` (or leaving it empty / `default`) = **the default behavior, unchanged.**

## Usage

```bash
docker run -d --name mybot-ba \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e BOT_ROLE=ba \
  -v mybot-ba-data:/data \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
```

## How it works (first-run seeding, idempotent)

In `entrypoint.sh`, if `BOT_ROLE` is set, non-empty, and not `default`, and the directory
`roles/$BOT_ROLE/` exists in the image (`/usr/local/share/claude-telegram/roles/`):

1. The role's **`CLAUDE.md`** is seeded as the bot's **work-dir CLAUDE.md**
   (`$WORK_DIR/CLAUDE.md`) — **only if that file does not exist yet** (it never clobbers a
   bot's own CLAUDE.md). It **layers on top of** the baked base CLAUDE.md (security +
   isolation + `.workspace` + reply tone remain the shared foundation).
2. The **`settings-fragment.json`** is jq-merged into the bot's `settings.json`: a **union**
   of `enabledPlugins` + `permissions.allow` (it never clobbers what's there and never
   disables base plugins).
3. Any files in **`rules/`** (if present) are seeded into `.workspace/rules/` (skipping files
   that already exist).

Setting an invalid `BOT_ROLE` (no matching directory) → the entrypoint LOGS a warning and
runs as default, no error.

> Note: `CLAUDE.md` is only seeded when the work dir has no CLAUDE.md. Changing `BOT_ROLE` on
> an already-running bot (one that already has a work-dir CLAUDE.md) will **not** swap the
> CLAUDE.md — to change an existing bot's role, delete/rename `$WORK_DIR/CLAUDE.md` and
> restart, or use a clean volume. (The `settings-fragment` part is a union, so re-running is
> harmless.)

## Adding a new role

1. Create a `roles/<role>/` directory with:
   - `CLAUDE.md` — the role's "how I work" rules (English, generic, layered on the base).
     Reference the workflow stage + the traceability chain (`Closes #x`) + DoR/DoD where it
     fits.
   - `settings-fragment.json` — valid JSON, minimally: extra `enabledPlugins` + extra
     `permissions.allow`. Never disable base plugins. (A generic `_note` may describe it.)
   - (optional) `rules/*.md` — 1-2 behavioral rules seeded into `.workspace/rules/`.
2. No `entrypoint.sh` change is needed — it reads `$BOT_ROLE` dynamically. You only need
   `COPY roles/` in the Dockerfile (already present).
3. `jq . roles/<role>/settings-fragment.json` must parse. `bash -n entrypoint.sh` must be
   clean.
4. Update the role table above + the main READMEs + CHEATSHEET.
