#!/usr/bin/env python3
"""tg-worker — Telegram Bot-API worker for claude-telegram-docker v2.2.

The container's MAIN process. Owns Telegram polling itself (getUpdates long-poll)
and invokes headless `claude -p` once per message. Replaces the old
`claude --channels` transport (whose CLI channel-host poller was unreliable —
see docs/superpowers/specs/2026-07-19-v2.2-worker-image-design.md).

Two threads:
  1. poll loop  — getUpdates → access gate → 👀 ack → `claude -p` → sendMessage.
  2. scheduler  — every ~45s scan $WORK_DIR/reminders/*.json, fire due reminders.

Design constraints:
  - stdlib only (urllib, json, subprocess, threading) — no pip deps.
  - never crash the loop; catch + backoff on every network/subprocess error.
  - subscription auth only: pop ANTHROPIC_API_KEY so the Claude subscription
    (CLAUDE_CODE_OAUTH_TOKEN / on-volume creds) is used, never a metered key.
  - config entirely from env (see Config.from_env).
"""
import os
import re
import json
import time
import threading
import subprocess
import urllib.request
import urllib.parse
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Default tool allowlist for group-exposed bots: shared-memory MCP + read-only
# file tools + web read. NO free Bash (prompt-injection safety). Trusted personal
# bots widen this via TG_WORKER_ALLOWED_TOOLS.
DEFAULT_ALLOWED_TOOLS = "mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch"

# Valid values for `claude -p --permission-mode`. `auto` (interactive Auto Mode)
# is NOT valid for -p, so it maps to acceptEdits.
VALID_PERMISSION_MODES = {"default", "acceptEdits", "bypassPermissions", "plan"}
PERMISSION_MODE_ALIASES = {"auto": "acceptEdits", "manual": "default", "": "acceptEdits"}

REACT_HINT = (
    "Telegram reaction: you MAY begin your reply with ONE contextually-fitting reaction emoji "
    "in the EXACT form [[react:X]] on the very first line (X = one emoji from "
    "\U0001F44D ❤️ \U0001F525 \U0001F389 \U0001F914 \U0001F440 ✅ \U0001F60E \U0001F64F \U0001F4AF \U0001F44C \U0001F62E), "
    "then your normal reply on the next line. Pick one that matches the mood; omit if none fits. "
    "Never explain the tag."
)

REACT_RE = re.compile(r"\s*\[\[react:\s*(.+?)\s*\]\]\s*")
CHUNK = 3800  # Telegram sendMessage text limit is 4096; leave headroom.


# ---------------------------------------------------------------------------
# Pure helpers (no I/O — unit-testable, imported by the inline test + tg-reminder)
# ---------------------------------------------------------------------------

def map_permission_mode(raw):
    """Map a PERMISSION_MODE env value to a valid `claude -p --permission-mode`.

    `auto` -> acceptEdits (auto is interactive-only), `manual` -> default,
    empty -> acceptEdits. Unknown values fall back to acceptEdits.
    """
    v = (raw or "").strip()
    if v in VALID_PERMISSION_MODES:
        return v
    if v in PERMISSION_MODE_ALIASES:
        return PERMISSION_MODE_ALIASES[v]
    return "acceptEdits"


def is_allowed(msg, access, bot_username):
    """Mirror the telegram plugin's access gate.

    DM: sender.id must be in allowFrom.
    Group/supergroup: the group must be listed; if it has an allowFrom the sender
    must be in it; if requireMention is set the bot must be @mentioned. Bot
    senders are always skipped.
    """
    chat = msg.get("chat", {}) or {}
    frm = msg.get("from", {}) or {}
    if frm.get("is_bot"):
        return False
    cid = str(chat.get("id"))
    fid = str(frm.get("id"))
    if chat.get("type") == "private":
        return fid in (access.get("allowFrom") or [])
    g = (access.get("groups") or {}).get(cid)
    if not g:
        return False
    gaf = g.get("allowFrom") or []
    if gaf and fid not in gaf:
        return False
    if g.get("requireMention"):
        text = (msg.get("text") or "") + " " + (msg.get("caption") or "")
        if not (bot_username and ("@" + bot_username).lower() in text.lower()):
            return False
    return True


def parse_react(reply):
    """Split a leading [[react:X]] tag off a reply. Returns (emoji_or_None, rest)."""
    m = REACT_RE.match(reply or "")
    if m:
        return m.group(1), reply[m.end():].lstrip()
    return None, reply


def compute_next_fire(rem, after_dt):
    """Next fire time (naive local datetime) for a reminder strictly after `after_dt`.

    Schema:
      recurrence "once":   {"when": "YYYY-MM-DDTHH:MM[:SS]"}  -> that instant
      recurrence "daily":  {"time": "HH:MM"}                  -> next day at time
      recurrence "weekly": {"time": "HH:MM", "weekday": 0-6}  (Mon=0)
    Returns a datetime, or None if it cannot be computed.
    """
    rec = (rem.get("recurrence") or "once").lower()
    if rec == "once":
        w = rem.get("when")
        if not w:
            return None
        try:
            return datetime.fromisoformat(w)
        except ValueError:
            return None
    # recurring -> parse HH:MM
    try:
        hh, mm = (rem.get("time") or "").split(":")
        hh, mm = int(hh), int(mm)
    except (ValueError, AttributeError):
        return None
    base = after_dt.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if rec == "daily":
        while base <= after_dt:
            base += timedelta(days=1)
        return base
    if rec == "weekly":
        try:
            target = int(rem.get("weekday"))
        except (TypeError, ValueError):
            return None
        # advance day-by-day to the right weekday strictly after after_dt
        for _ in range(0, 15):
            if base > after_dt and base.weekday() == target:
                return base
            base += timedelta(days=1)
        return None
    return None


def build_claude_cmd(prompt, model, permission_mode, allowed_tools, resume_sid):
    """Assemble the `claude -p` argv (pure — no env, no exec)."""
    cmd = [
        "claude", "-p", prompt,
        "--output-format", "json",
        "--permission-mode", permission_mode,
        "--append-system-prompt", REACT_HINT,
        "--allowedTools", allowed_tools,
    ]
    if model:
        cmd += ["--model", model]
    if resume_sid:
        cmd += ["--resume", resume_sid]
    return cmd


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class Config:
    def __init__(self):
        self.state_dir = os.environ.get("TELEGRAM_STATE_DIR", "/home/botuser/.claude/telegram")
        self.config_dir = os.environ.get("CLAUDE_CONFIG_DIR", "/home/botuser/.claude")
        self.work_dir = os.environ.get("WORK_DIR", "/home/botuser/.claude/workspace")
        self.home = os.environ.get("HOME", "/home/botuser")
        self.model = os.environ.get("MODEL", "").strip()
        self.allowed_tools = os.environ.get("TG_WORKER_ALLOWED_TOOLS", DEFAULT_ALLOWED_TOOLS).strip() or DEFAULT_ALLOWED_TOOLS
        # TG_WORKER_PERMISSION_MODE overrides PERMISSION_MODE for the worker.
        raw_pm = os.environ.get("TG_WORKER_PERMISSION_MODE") or os.environ.get("PERMISSION_MODE", "")
        self.permission_mode = map_permission_mode(raw_pm)
        self.reminders_dir = os.path.join(self.work_dir, "reminders")
        self.sess_dir = os.path.join(self.state_dir, "sessions")
        self.offset_file = os.path.join(self.state_dir, "offset")
        self.log_file = os.path.join(self.state_dir, "worker.log")
        self.heartbeat_file = os.path.join(self.state_dir, "worker.heartbeat")
        self.token = self._read_token()

    def _read_token(self):
        p = os.path.join(self.state_dir, ".env")
        try:
            with open(p) as fh:
                for line in fh:
                    m = re.match(r"^\s*TELEGRAM_BOT_TOKEN\s*=\s*(.+?)\s*$", line)
                    if m:
                        return m.group(1).strip().strip('"').strip("'")
        except OSError:
            pass
        return os.environ.get("TELEGRAM_BOT_TOKEN", "")


class Worker:
    def __init__(self, cfg):
        self.cfg = cfg
        self.api = "https://api.telegram.org/bot" + cfg.token
        self.bot_username = None
        os.makedirs(cfg.sess_dir, exist_ok=True)
        os.makedirs(cfg.reminders_dir, exist_ok=True)

    # --- logging / heartbeat ---
    def log(self, *a):
        line = time.strftime("%Y-%m-%d %H:%M:%S") + " " + " ".join(str(x) for x in a)
        print(line, flush=True)
        try:
            with open(self.cfg.log_file, "a") as fh:
                fh.write(line + "\n")
        except OSError:
            pass

    def beat(self):
        try:
            with open(self.cfg.heartbeat_file, "w") as fh:
                fh.write(str(int(time.time())))
        except OSError:
            pass

    # --- telegram bot api ---
    def tg(self, method, params, timeout=60):
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(self.api + "/" + method, data=data)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)

    def send(self, chat_id, text, reply_to=None):
        text = text or "(empty)"
        for i in range(0, max(len(text), 1), CHUNK):
            p = {"chat_id": chat_id, "text": text[i:i + CHUNK] or "(empty)"}
            if reply_to and i == 0:
                p["reply_to_message_id"] = reply_to
            try:
                self.tg("sendMessage", p)
            except Exception as e:
                self.log("send err", e)

    def react(self, chat_id, mid, emoji="\U0001F440"):
        try:
            self.tg("setMessageReaction", {
                "chat_id": chat_id, "message_id": mid,
                "reaction": json.dumps([{"type": "emoji", "emoji": emoji}]),
            })
        except Exception:
            pass

    # --- access ---
    def load_access(self):
        try:
            with open(os.path.join(self.cfg.state_dir, "access.json")) as fh:
                return json.load(fh)
        except (OSError, ValueError):
            return {}

    # --- per-chat session persistence ---
    def _sess_path(self, chat_id):
        return os.path.join(self.cfg.sess_dir, str(chat_id))

    def load_sid(self, chat_id):
        try:
            return open(self._sess_path(chat_id)).read().strip() or None
        except OSError:
            return None

    def save_sid(self, chat_id, sid):
        if sid:
            try:
                open(self._sess_path(chat_id), "w").write(sid)
            except OSError:
                pass

    # --- claude invocation ---
    def _claude_env(self):
        env = dict(os.environ)
        env.pop("ANTHROPIC_API_KEY", None)  # force subscription
        env["CLAUDE_CONFIG_DIR"] = self.cfg.config_dir
        env["HOME"] = self.cfg.home
        env["WORK_DIR"] = self.cfg.work_dir
        env["PATH"] = (self.cfg.home + "/.local/bin:" + self.cfg.home + "/.bun/bin:"
                       + env.get("PATH", "/usr/local/bin:/usr/bin:/bin"))
        return env

    def run_claude(self, prompt, resume_sid=None, timeout=600):
        """Run one headless `claude -p` turn. Returns (reply_text, session_id)."""
        cmd = build_claude_cmd(prompt, self.cfg.model, self.cfg.permission_mode,
                               self.cfg.allowed_tools, resume_sid)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               env=self._claude_env(), cwd=self.cfg.work_dir, timeout=timeout)
        except subprocess.TimeoutExpired:
            return "[worker] claude timeout %ss" % timeout, None
        except Exception as e:
            return "[worker] claude spawn error: %s" % e, None
        try:
            out = json.loads(p.stdout)
            return (out.get("result") or "(empty result)"), out.get("session_id")
        except ValueError:
            return (p.stdout or p.stderr or "[worker] no output")[:1500], None

    def handle_message(self, msg):
        chat = msg.get("chat", {}) or {}
        cid = chat.get("id")
        text = msg.get("text") or msg.get("caption")
        if not text or cid is None:
            return
        if not is_allowed(msg, self.load_access(), self.bot_username):
            return
        is_group = chat.get("type") in ("group", "supergroup")
        self.react(cid, msg["message_id"])  # instant 👀 ack while Claude thinks
        t0 = time.time()
        sid = self.load_sid(cid)
        reply, new_sid = self.run_claude(text, resume_sid=sid)
        if new_sid:
            self.save_sid(cid, new_sid)
        emoji, reply = parse_react(reply)
        if emoji:
            self.react(cid, msg["message_id"], emoji)  # replaces 👀
        self.log("turn %.1fs chat=%s sid=%s react=%s" % (time.time() - t0, cid, new_sid, emoji or "-"))
        self.send(cid, reply, reply_to=msg["message_id"] if is_group else None)

    # --- reminders ---
    def _iter_reminders(self):
        try:
            names = sorted(os.listdir(self.cfg.reminders_dir))
        except OSError:
            return
        for name in names:
            if not name.endswith(".json"):
                continue
            path = os.path.join(self.cfg.reminders_dir, name)
            try:
                with open(path) as fh:
                    yield path, json.load(fh)
            except (OSError, ValueError) as e:
                self.log("reminder load err", name, e)

    def _save_reminder(self, path, rem):
        try:
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(rem, fh, indent=2)
            os.replace(tmp, path)
        except OSError as e:
            self.log("reminder save err", path, e)

    def _fire_reminder(self, rem):
        cid = rem.get("chat_id")
        if cid is None:
            return
        mode = rem.get("mode", "text")
        if mode == "claude":
            prompt = rem.get("prompt") or rem.get("text") or ""
            reply, _sid = self.run_claude(prompt, resume_sid=None)
            emoji, reply = parse_react(reply)
            self.send(cid, reply)
        else:
            self.send(cid, rem.get("text") or rem.get("prompt") or "(reminder)")

    def scheduler_tick(self, now=None):
        now = now or datetime.now()
        for path, rem in self._iter_reminders():
            if not rem.get("enabled", True):
                continue
            nf = rem.get("next_fire")
            if not nf:
                nf_dt = compute_next_fire(rem, now)
                if nf_dt is None:
                    self.log("reminder disabled (bad schedule)", os.path.basename(path))
                    rem["enabled"] = False
                    self._save_reminder(path, rem)
                    continue
                rem["next_fire"] = nf_dt.isoformat()
                self._save_reminder(path, rem)
                nf = rem["next_fire"]
            try:
                due = now >= datetime.fromisoformat(nf)
            except ValueError:
                continue
            if not due:
                continue
            self.log("firing reminder", rem.get("id"), "mode=%s chat=%s" % (rem.get("mode"), rem.get("chat_id")))
            try:
                self._fire_reminder(rem)
            except Exception as e:
                self.log("reminder fire err", rem.get("id"), e)
            rec = (rem.get("recurrence") or "once").lower()
            if rec == "once":
                rem["enabled"] = False
                rem.pop("next_fire", None)
            else:
                nxt = compute_next_fire(rem, now)
                rem["next_fire"] = nxt.isoformat() if nxt else None
                if nxt is None:
                    rem["enabled"] = False
            self._save_reminder(path, rem)

    def scheduler_loop(self):
        while True:
            try:
                self.scheduler_tick()
            except Exception as e:
                self.log("scheduler err", e)
            self.beat()
            time.sleep(45)

    # --- poll loop ---
    def poll_loop(self):
        off = 0
        try:
            off = int(open(self.cfg.offset_file).read().strip())
        except (OSError, ValueError):
            pass
        backoff = 3
        while True:
            self.beat()
            try:
                resp = self.tg("getUpdates", {"offset": off + 1, "timeout": 50}, timeout=60)
                backoff = 3
            except Exception as e:
                self.log("getUpdates err", e)
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)
                continue
            for upd in resp.get("result", []):
                off = upd["update_id"]
                try:
                    open(self.cfg.offset_file, "w").write(str(off))
                except OSError:
                    pass
                msg = upd.get("message") or upd.get("edited_message") or {}
                try:
                    self.handle_message(msg)
                except Exception as e:
                    self.log("handle err", e)

    def run(self):
        try:
            me = self.tg("getMe", {}, timeout=15)
            self.bot_username = (me.get("result") or {}).get("username")
        except Exception as e:
            self.log("getMe err", e)
        self.log("worker online — bot @%s model=%s perm=%s tools=[%s] config=%s" % (
            self.bot_username, self.cfg.model or "default", self.cfg.permission_mode,
            self.cfg.allowed_tools, self.cfg.config_dir))
        self.beat()
        t = threading.Thread(target=self.scheduler_loop, name="scheduler", daemon=True)
        t.start()
        self.poll_loop()


def main():
    cfg = Config()
    if not cfg.token:
        raise SystemExit("[tg-worker] no TELEGRAM_BOT_TOKEN (looked in %s/.env and env)" % cfg.state_dir)
    Worker(cfg).run()


if __name__ == "__main__":
    main()
