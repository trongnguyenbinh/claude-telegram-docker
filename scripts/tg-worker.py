#!/usr/bin/env python3
"""tg-worker — Telegram Bot-API worker for claude-telegram-docker v2.3.

The container's MAIN process. Owns Telegram polling itself (getUpdates long-poll)
and invokes headless `claude -p` once per message. Replaces the old
`claude --channels` transport (whose CLI channel-host poller was unreliable —
see docs/superpowers/specs/2026-07-19-v2.2-worker-image-design.md).

v2.3 adds media handling: inbound photos (Claude views them via the Read tool),
documents (Read), and voice/audio (transcribed via the Voice API when configured);
plus an optional voice REPLY path (a `[[voice]]`-prefixed reply is spoken and sent
as a Telegram voice bubble). Voice needs VOICE_API_URL + VOICE_API_KEY set.

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
import base64
import shutil
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
# Voice-output marker: a reply beginning with [[voice]] on the first line is spoken
# and sent as a Telegram voice bubble (when the Voice API is configured).
VOICE_RE = re.compile(r"^\s*\[\[voice\]\]\s*\n?", re.IGNORECASE)
CHUNK = 3800  # Telegram sendMessage text limit is 4096; leave headroom.

# Effective-prompt notes appended when the user sends an attachment. Vietnamese
# (the owner's language); tell Claude which built-in tool renders the file.
PROMPT_PHOTO = ("[Người dùng gửi một hình ảnh, đã lưu tại {path}. "
                "Hãy dùng công cụ Read để xem ảnh rồi trả lời.]")
PROMPT_DOC = ("[Người dùng gửi một tệp ({name}), đã lưu tại {path}. "
              "Hãy dùng công cụ Read để đọc nội dung tệp rồi trả lời.]")
PROMPT_VOICE = "[Tin nhắn thoại của người dùng đã được chuyển thành văn bản ở trên.]"

# Shown once when a voice/audio message arrives but no Voice API is configured.
VOICE_DISABLED_MSG = ("Bot này chưa bật tính năng tin nhắn thoại. "
                      "Anh gõ nội dung bằng chữ giúp em nhé.")


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


def parse_voice(reply):
    """Split a leading [[voice]] marker off a reply. Returns (want_voice, rest).

    Runs AFTER parse_react, so `[[react:X]]\\n[[voice]]\\n...` is supported. The
    marker is stripped regardless of whether voice output is actually available.
    """
    m = VOICE_RE.match(reply or "")
    if m:
        return True, reply[m.end():].lstrip()
    return False, reply


def pick_largest_photo(photos):
    """From a Telegram `photo` size list, return the largest entry (by file_size,
    else the last, which Telegram orders ascending). None if empty."""
    if not photos:
        return None
    if any(p.get("file_size") for p in photos):
        return max(photos, key=lambda p: p.get("file_size") or 0)
    return photos[-1]


def detect_attachment(msg):
    """Detect a supported attachment on a Telegram message.

    Returns (kind, file_id, ext, filename) or None.
      kind: "photo" | "document" | "voice"  (audio is unified under "voice")
      ext:  suggested file extension (so the saved file's type is detectable)
    Pure — no I/O.
    """
    photos = msg.get("photo")
    if photos:
        p = pick_largest_photo(photos)
        if p and p.get("file_id"):
            return ("photo", p["file_id"], ".jpg", None)
    doc = msg.get("document")
    if doc and doc.get("file_id"):
        name = doc.get("file_name") or "file"
        ext = os.path.splitext(name)[1] or ".bin"
        return ("document", doc["file_id"], ext, name)
    voice = msg.get("voice")
    if voice and voice.get("file_id"):
        return ("voice", voice["file_id"], ".oga", None)
    audio = msg.get("audio")
    if audio and audio.get("file_id"):
        name = audio.get("file_name") or "audio"
        ext = os.path.splitext(name)[1] or ".mp3"
        return ("voice", audio["file_id"], ext, name)
    return None


def build_media_prompt(kind, caption, path, transcript=None, filename=None):
    """Build the effective `claude -p` prompt for an attachment.

    photo/document: (caption) + a note pointing at the saved abs path + Read hint.
    voice: the transcript (main content) + optional caption + a note it was speech.
    Pure — no I/O.
    """
    caption = (caption or "").strip()
    if kind == "voice":
        parts = []
        body = (transcript or "").strip()
        if body:
            parts.append(body)
        if caption:
            parts.append(caption)
        parts.append(PROMPT_VOICE)
        return "\n\n".join(parts)
    if kind == "photo":
        note = PROMPT_PHOTO.format(path=path)
    else:  # document (incl. images-as-document)
        note = PROMPT_DOC.format(name=filename or "tệp", path=path)
    return (caption + "\n\n" + note) if caption else note


def encode_multipart(fields, file_field, filename, file_bytes, file_content_type):
    """Encode a multipart/form-data body (stdlib only). Returns (body_bytes,
    content_type_header). Used for Bot API sendVoice (file upload)."""
    boundary = "----tgworker%d" % int(time.time() * 1000)
    crlf = b"\r\n"
    bnd = boundary.encode()
    buf = bytearray()
    for k, v in fields.items():
        buf += b"--" + bnd + crlf
        buf += ('Content-Disposition: form-data; name="%s"' % k).encode() + crlf + crlf
        buf += str(v).encode() + crlf
    buf += b"--" + bnd + crlf
    buf += ('Content-Disposition: form-data; name="%s"; filename="%s"'
            % (file_field, filename)).encode() + crlf
    buf += ("Content-Type: %s" % file_content_type).encode() + crlf + crlf
    buf += file_bytes + crlf
    buf += b"--" + bnd + b"--" + crlf
    return bytes(buf), "multipart/form-data; boundary=" + boundary


# --- MarkdownV2 rendering (so ```fences``` become tap-to-copy + *bold* renders) ---
# Telegram MarkdownV2 400s on any unescaped special char in non-code text. We
# tokenize the reply into code vs non-code, escape non-code, keep code literal.

_MD2_SPECIAL = re.compile(r"([_*\[\]()~`>#+\-=|{}.!\\])")
_MD2_FENCE_RE = re.compile(r"```(.*?)```", re.DOTALL)


def _md2_escape(s):
    """Escape every MarkdownV2 special char in ordinary (non-code) text."""
    return _MD2_SPECIAL.sub(r"\\\1", s)


def _md2_code_escape(s):
    """Inside a code span/fence only ` and \\ need escaping."""
    return s.replace("\\", "\\\\").replace("`", "\\`")


def _md2_inline(text):
    """Render a non-fenced text segment: preserve inline `code`, convert common
    emphasis (**bold**/__bold__ -> *bold*, *i*/_i_ italic), escape everything else."""
    if not text:
        return ""
    codes = []

    def _stash(m):
        codes.append(m.group(1))
        return "\x00%d\x00" % (len(codes) - 1)

    text = re.sub(r"`([^`\n]+)`", _stash, text)
    # Emphasis -> private sentinels that survive escaping (tight markers only).
    text = re.sub(r"\*\*(\S(?:.*?\S)?)\*\*", lambda m: "\x01" + m.group(1) + "\x01", text)
    text = re.sub(r"__(\S(?:.*?\S)?)__", lambda m: "\x01" + m.group(1) + "\x01", text)
    text = re.sub(r"(?<![\w*])\*(\S(?:[^*\n]*?\S)?)\*(?![\w*])",
                  lambda m: "\x02" + m.group(1) + "\x02", text)
    text = re.sub(r"(?<![\w_])_(\S(?:[^_\n]*?\S)?)_(?![\w_])",
                  lambda m: "\x02" + m.group(1) + "\x02", text)
    text = _md2_escape(text)
    text = text.replace("\x01", "*").replace("\x02", "_")
    text = re.sub("\x00(\\d+)\x00", lambda m: "`" + _md2_code_escape(codes[int(m.group(1))]) + "`", text)
    return text


def _md2_fence(body):
    """Render a fenced block body (may start with a language tag)."""
    return "```" + _md2_code_escape(body) + "```"


def to_markdownv2(text):
    """Convert Claude's markdown-ish reply into valid Telegram MarkdownV2.

    Fenced ``` blocks + inline `code` stay literal (tap-to-copy); everything else
    has its MarkdownV2 special chars escaped so Telegram never 400s on entities.
    """
    text = text or ""
    out = []
    pos = 0
    for m in _MD2_FENCE_RE.finditer(text):
        out.append(_md2_inline(text[pos:m.start()]))
        out.append(_md2_fence(m.group(1)))
        pos = m.end()
    out.append(_md2_inline(text[pos:]))
    return "".join(out)


def split_chunks(text, limit=CHUNK):
    """Split a reply into ≤limit pieces, preferring paragraph/line boundaries so a
    ``` fence usually stays whole. Splits on RAW text (each chunk is then rendered
    to MarkdownV2 independently)."""
    text = text or ""
    if len(text) <= limit:
        return [text]
    chunks = []
    rest = text
    while len(rest) > limit:
        window = rest[:limit]
        cut = window.rfind("\n\n")
        if cut < limit // 2:
            cut = window.rfind("\n")
        if cut <= 0:
            cut = limit
        chunks.append(rest[:cut])
        rest = rest[cut:].lstrip("\n")
    if rest:
        chunks.append(rest)
    return chunks


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
        # Voice (STT/TTS) via the external Voice API. Both must be set to enable
        # voice transcription (inbound) and voice replies (outbound).
        self.voice_api_url = os.environ.get("VOICE_API_URL", "").strip().rstrip("/")
        self.voice_api_key = os.environ.get("VOICE_API_KEY", "").strip()
        self.voice_enabled = bool(self.voice_api_url and self.voice_api_key)
        self.inbox_dir = os.path.join(self.work_dir, "inbox")
        self.outbox_dir = os.path.join(self.work_dir, "outbox")
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

    def _send_one(self, chat_id, text, reply_to=None):
        """Send one chunk as MarkdownV2; on any API error retry as PLAIN text so a
        reply always gets through (Claude's ``` blocks then render as tap-to-copy)."""
        base = {"chat_id": chat_id}
        if reply_to:
            base["reply_to_message_id"] = reply_to
        p = dict(base, text=to_markdownv2(text), parse_mode="MarkdownV2")
        try:
            self.tg("sendMessage", p)
            return
        except Exception as e:
            self.log("md2 send err (fallback plain)", e)
        try:
            self.tg("sendMessage", dict(base, text=text))
        except Exception as e:
            self.log("send err", e)

    def send(self, chat_id, text, reply_to=None):
        text = text or "(empty)"
        for i, chunk in enumerate(split_chunks(text)):
            self._send_one(chat_id, chunk or "(empty)", reply_to if i == 0 else None)

    def react(self, chat_id, mid, emoji="\U0001F440"):
        try:
            self.tg("setMessageReaction", {
                "chat_id": chat_id, "message_id": mid,
                "reaction": json.dumps([{"type": "emoji", "emoji": emoji}]),
            })
        except Exception:
            pass

    def send_voice(self, chat_id, ogg_path, reply_to=None):
        """Upload an Ogg/Opus clip as a Telegram VOICE bubble (sendVoice, multipart)."""
        fields = {"chat_id": str(chat_id)}
        if reply_to:
            fields["reply_to_message_id"] = str(reply_to)
        with open(ogg_path, "rb") as fh:
            file_bytes = fh.read()
        body, ctype = encode_multipart(fields, "voice", os.path.basename(ogg_path),
                                       file_bytes, "audio/ogg")
        req = urllib.request.Request(self.api + "/sendVoice", data=body)
        req.add_header("Content-Type", ctype)
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)

    # --- file download (telegram + generic URL) ---
    def download_tg_file(self, file_id, dest_dir, ext=""):
        """getFile → download from api.telegram.org/file/bot<token>/<file_path>.
        Returns the saved absolute path, or None on any failure (never raises)."""
        try:
            os.makedirs(dest_dir, exist_ok=True)
            resp = self.tg("getFile", {"file_id": file_id}, timeout=30)
            fp = (resp.get("result") or {}).get("file_path") if resp.get("ok") else None
            if not fp:
                self.log("getFile no file_path", resp)
                return None
            url = "https://api.telegram.org/file/bot%s/%s" % (self.cfg.token, fp)
            suffix = ext or os.path.splitext(fp)[1] or ".bin"
            tag = re.sub(r"[^A-Za-z0-9]", "", str(file_id))[-12:] or "f"
            dest = os.path.join(dest_dir, "%d_%s%s" % (int(time.time()), tag, suffix))
            with urllib.request.urlopen(urllib.request.Request(url), timeout=120) as r, \
                    open(dest, "wb") as fh:
                shutil.copyfileobj(r, fh)
            return dest
        except Exception as e:
            self.log("download_tg_file err", e)
            return None

    def _download_url(self, url, dest_dir, ext=".ogg"):
        try:
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, "%d%s" % (int(time.time() * 1000), ext))
            with urllib.request.urlopen(urllib.request.Request(url), timeout=120) as r, \
                    open(dest, "wb") as fh:
                shutil.copyfileobj(r, fh)
            return dest
        except Exception as e:
            self.log("download_url err", e)
            return None

    # --- voice api (STT / TTS) ---
    def _voice_post(self, path, body, timeout=120):
        url = self.cfg.voice_api_url + path
        data = json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("Authorization", "Bearer " + self.cfg.voice_api_key)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())

    def transcribe_audio(self, path, language="vi"):
        """Voice API /transcribe → transcript text, or None (graceful fallback)."""
        if not self.cfg.voice_enabled:
            return None
        try:
            with open(path, "rb") as fh:
                b64 = base64.b64encode(fh.read()).decode()
        except OSError as e:
            self.log("transcribe read err", e)
            return None
        try:
            out = self._voice_post("/transcribe", {"audio_base64": b64, "language": language})
            return (out or {}).get("text") or None
        except Exception as e:
            self.log("transcribe err", e)
            return None

    def send_voice_reply(self, chat_id, text, reply_to=None):
        """Speak `text` via the Voice API and send it as a voice bubble.
        Returns True on success; False → caller should fall back to sending text."""
        text = (text or "").strip()
        if not (self.cfg.voice_enabled and text):
            return False
        try:
            out = self._voice_post("/speak", {"text": text, "lang": "vi"})
            audio_url = (out or {}).get("url")
        except Exception as e:
            self.log("speak err", e)
            return False
        if not audio_url:
            return False
        ogg = self._download_url(audio_url, self.cfg.outbox_dir, ".ogg")
        if not ogg:
            return False
        try:
            self.send_voice(chat_id, ogg, reply_to)
            return True
        except Exception as e:
            self.log("sendVoice err", e)
            return False

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

    def _prepare_attachment_prompt(self, att, msg, cid, reply_to):
        """Download an attachment (and transcribe voice) → effective prompt text.

        Returns the prompt string, or None when there's nothing to run (e.g. a
        voice message but no Voice API configured, or a download/transcription
        failure) — in which case a suitable notice has already been sent.
        """
        kind, file_id, ext, filename = att
        caption = msg.get("caption") or ""
        if kind == "voice":
            if not self.cfg.voice_enabled:
                self.send(cid, VOICE_DISABLED_MSG, reply_to=reply_to)
                return None
            path = self.download_tg_file(file_id, self.cfg.inbox_dir, ext)
            if not path:
                self.send(cid, "Em không tải được tin nhắn thoại, anh thử gửi lại giúp em nhé.",
                          reply_to=reply_to)
                return None
            transcript = self.transcribe_audio(path)
            if not transcript:
                self.send(cid, "Em chưa nghe rõ nội dung tin nhắn thoại. Anh nói lại hoặc gõ chữ giúp em nhé.",
                          reply_to=reply_to)
                return None
            return build_media_prompt("voice", caption, path, transcript=transcript)
        # photo / document
        path = self.download_tg_file(file_id, self.cfg.inbox_dir, ext)
        if not path:
            self.send(cid, "Em không tải được tệp đính kèm, anh thử gửi lại giúp em nhé.",
                      reply_to=reply_to)
            return None
        return build_media_prompt(kind, caption, path, filename=filename)

    def handle_message(self, msg):
        chat = msg.get("chat", {}) or {}
        cid = chat.get("id")
        text = msg.get("text") or msg.get("caption")
        att = detect_attachment(msg)
        # Proceed if there's text/caption OR a supported attachment; only bail when
        # there's genuinely nothing to act on.
        if cid is None or (not text and att is None):
            return
        if not is_allowed(msg, self.load_access(), self.bot_username):
            return
        is_group = chat.get("type") in ("group", "supergroup")
        reply_to = msg["message_id"] if is_group else None
        self.react(cid, msg["message_id"])  # instant 👀 ack while Claude thinks

        if att is not None:
            prompt = self._prepare_attachment_prompt(att, msg, cid, reply_to)
            if prompt is None:
                return  # notice already sent (e.g. voice not enabled / download failed)
        else:
            prompt = text

        t0 = time.time()
        sid = self.load_sid(cid)
        reply, new_sid = self.run_claude(prompt, resume_sid=sid)
        if new_sid:
            self.save_sid(cid, new_sid)
        emoji, reply = parse_react(reply)
        if emoji:
            self.react(cid, msg["message_id"], emoji)  # replaces 👀
        want_voice, reply = parse_voice(reply)  # strip [[voice]] regardless
        self.log("turn %.1fs chat=%s sid=%s react=%s att=%s voice=%s" % (
            time.time() - t0, cid, new_sid, emoji or "-",
            att[0] if att else "-", "y" if (want_voice and self.cfg.voice_enabled) else "-"))
        if want_voice and self.cfg.voice_enabled and self.send_voice_reply(cid, reply, reply_to):
            return  # sent as a voice bubble
        self.send(cid, reply, reply_to=reply_to)

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
