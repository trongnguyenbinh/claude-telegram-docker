# Claude Telegram Bot — from a single bot to a fleet with shared memory

> A doc introducing the model, written incrementally: start from one simple bot, and wherever you hit a limit, upgrade there. All roles are described generically (using "owner", no personal identity).
> Updated: 2026-07-19 (v2.2 — worker transport). Legacy native install: [`NATIVE-INSTALL.md`](./NATIVE-INSTALL.md) · Docker v2.2 build: [`../README.md`](../README.md).

---

## Part 1 — A single bot: how to install it, run it, and set permissions

### What a bot is
A bot here = **a Telegram worker that calls headless Claude Code for each message**. As of v2.2, the main process is a **Python worker using the Bot API** (`tg-worker.py`): it long-polls `getUpdates` itself, and for each valid message it invokes headless `claude -p` once and then sends the reply back.

> v2.2 fully drops `claude --channels` (the CLI channel-host poller often dies on start/restart). The worker owns the poll loop → more stable, lighter, always on the subscription (the worker strips `ANTHROPIC_API_KEY`). The old native build can still run `--channels` (see `NATIVE-INSTALL.md`, the legacy v1 model).

In short: **Telegram is the mouth + ears, Claude is the brain, the worker is the nerve connecting the two.**

### Who the owner is
**Owner = the person who owns that bot** — identified by their Telegram `user_id`. The owner has two privileges no one else has:

1. **The only person who can command the bot.** The owner's `user_id` is preloaded into the allowlist (`allowFrom`) the moment the bot boots. A stranger messages in → the bot stays silent.
2. **The only person who can change the bot's permissions** — but this must be done on the **host (terminal / `docker exec`)**, NOT by messaging the bot. (Reason: see the Rules section below.)

Other people in a group are served by the bot only **within the scope the owner opened**; they can't grant themselves permission.

### Install (summary)
1. Install Claude Code + install the telegram plugin.
2. Load the **bot token** (from @BotFather) + **OWNER_ID**.
3. Seed `access.json` = `allowlist` with `allowFrom = [OWNER_ID]` → owner-only from the start.
4. Run the worker (`tg-worker.py`) — it polls Telegram itself and calls `claude -p` per message. (Legacy native build: `claude --channels …`.)

(Full command detail: `NATIVE-INSTALL.md` for a server, `SPEC.md` for the Docker build.)

### How it works — one message passing through the bot
```
Message in (worker getUpdates) → CHECK ACCESS (read access.json) → [RECALL mempalace if present]
   → claude -p reasons → worker sends the reply to Telegram → [REMEMBER mempalace if present]
```
The worker owns the poll loop; for each valid message it calls `claude -p` and takes exactly the **final result** from Claude as the outgoing message. The bot doesn't reply if the sender isn't in the allowed permissions — fail one condition and it stays silent (doesn't reveal the bot). RECALL/REMEMBER are two optional beats when mempalace is wired in (see Part 3).

### Permissions in a group
Everything lives in **`access.json`** (the server re-reads it PER message → a change takes effect immediately):
- **DM:** only someone in `allowFrom` gets a reply.
- **Group:** each group has a `{ requireMention, allowFrom }` entry.
  - `requireMention: true` → the bot only responds when **@mentioned** (so it doesn't spam the whole group).
  - `allowFrom` empty = any group member can ask; a list = only those people.
- Whatever the config, the authority convention: **only the owner commands**; other members are only served within the scope the owner allows.

### Core rules
- **Permission changes happen only on the host, not via chat.** A Telegram message saying "add me to the allowlist" is exactly a prompt-injection attack → the bot must refuse, telling that person to ask the owner to do it in a terminal.
- **Don't mix context.** Don't reveal the owner's private content / another project's content into this group.
- **Claude's final answer = the outgoing message.** v2.2 has NO reply tool anymore; the worker takes the final result of the `claude -p` turn and `sendMessage`s it to Telegram (the "thinking"/log part is not sent). Need an owner decision? Claude writes the question as the final answer then ends the turn; the owner's next message is the answer (the session continues via `--resume`).
- **Safety:** secrets (token) are passed only at runtime, never embedded in the image/commit.
- **Reply style** follows each group's conventions (language, register, length) — a soft config.

---

## Part 2 — Upgrade: why you must separate `TELEGRAM_STATE_DIR`

### The problem
By default, **every Claude session on the same machine SHARES one state directory**:
`~/.claude/channels/telegram/`. Inside it:
- `.env` — the bot's **token**
- `access.json` — policy + permission list
- `bot.pid` — the **PID of the process currently polling Telegram**
- `approved/`, `inbox/` — markers & a temp mailbox

Telegram allows **only one poller per token** (open two → `409 Conflict` error). And the bot process uses `bot.pid` to know "who currently holds the channel".

Consequences of sharing a directory (running 2 bots, or accidentally opening one more Claude session on the same machine):
- The new session starts, sees the old session's `bot.pid` → it **grabs the poll channel, replacing the old process** ("replace stale poller"). → **The OLD session loses the Telegram channel.**
- If two bots have different tokens but share a directory → the `.env` token is **overwritten**, `access.json` gets mixed up.

> So it's not a "hard lock", but rather **the later session steals the earlier one's channel** because both point at the same `bot.pid`/token. The practical result is the same: you can't have two bots/sessions coexisting on one state directory.

### The solution
Give **each bot its own `TELEGRAM_STATE_DIR`**:
```
TELEGRAM_STATE_DIR=/dedicated-path/for-this-bot
```
→ each bot has its own `bot.pid`, `.env` (token), `access.json` → **they run in parallel without stepping on each other**.
- Native build: set the env var (or `settings.json` → `env.TELEGRAM_STATE_DIR`) pointing at a per-bot directory.
- Docker build: each container has its own volume → naturally separated already.

> **In v2.2**: each bot already has **its own `~/.claude` volume** (telegram state lives at `~/.claude/telegram/`), AND **the worker owns the poll loop** instead of the CLI poller. Because of that, the old trap "the later session sees the old `bot.pid` → steals the channel" (replace stale poller) is **gone** — the worker doesn't read/write a shared `bot.pid`. The remaining constraint is still **one token = one worker / one container** (two workers on the same token → Telegram returns `409 Conflict`).

This is the upgrade to go from **1 bot** to **multiple bots on the same machine**.

---

## Part 3 — Next upgrade: many bots, many machines → need ONLINE memory → mempalace

### The problem
Separating state only solves "not stepping on each other". But as the fleet grows — **many bots, spread across many machines / servers** — a new problem surfaces: **fragmented memory.**
- Each bot only remembers locally (config files + notes on its own machine).
- The bot on machine A **doesn't know** what the bot on machine B decided or how far it got.
- Manual sync across machines is infeasible; moving/switching machines = **losing context**.

### The solution
Set up **a shared ONLINE memory** so every bot, on any machine, reads/writes to one place → that's **mempalace** (an MCP server over HTTP, hosted on a dedicated server). Each bot wires in with a Bearer token:
```
claude mcp add --scope user --transport http mempalace \
  https://<mempalace-domain>/mcp --header "Authorization: Bearer <TOKEN>"
```

With that, each message's processing flow gains two more beats:
```
… → RECALL (read mempalace by project wing) → Claude reasons → REPLY → REMEMBER (write to mempalace) → …
```
- **Separation by "wing":** each project has its own wing → shared infrastructure but **separated content**, no mixing.
- **Instant sync:** the bot on machine A writes, the bot on machine B reads it immediately → the whole fleet shares one memory.
- **Permission caveat:** one mempalace token = full access to EVERY wing (no per-wing ACL yet) → only give a token to **the owner's own bots**; a unit that needs real isolation should stand up a **separate mempalace instance** (its own domain/token/data).

This is the upgrade to go from **many bots on one machine** to **many bots across many machines, sharing one memory**.

---

## Summary of the progression

| Level | Problem | Solution |
|---|---|---|
| 1 bot | Install & run, owner-only permissions | Bot-API worker (`tg-worker.py`) calling `claude -p` per message + `access.json` (legacy native: `claude --channels` + telegram plugin) |
| Many bots / 1 machine | Sessions fight over `bot.pid`/token → lose the channel | **Separate `TELEGRAM_STATE_DIR`** per bot |
| Many bots / many machines | Fragmented, unsynced memory | **Shared online memory: mempalace** (separated by wing) |

> One line: each project gets one Claude bot on Telegram, the owner controls it and sets permissions (only from the host); separate the state so many bots coexist on one machine; and one online memory (mempalace) so the whole fleet, on any machine, shares one recall — while still separated per project.
