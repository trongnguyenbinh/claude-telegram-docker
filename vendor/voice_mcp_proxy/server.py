"""The stdio MCP proxy: 4 tools that POST to the remote Voice API.

Config via env:
  VOICE_API_URL  base URL of the Voice API (e.g. https://voice.veasy.vn)
  VOICE_API_KEY  per-bot bearer key (vsk_...)

Deps: ``mcp`` only. HTTP is done with stdlib ``urllib`` to keep the shim tiny and
easy to vendor into bot images.
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request

from mcp.server.fastmcp import FastMCP

API_URL = os.environ.get("VOICE_API_URL", "http://localhost:8770").rstrip("/")
API_KEY = os.environ.get("VOICE_API_KEY", "")

mcp = FastMCP("voice")


def _request(method: str, path: str, body: dict | None = None, auth: bool = True) -> dict:
    url = f"{API_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if auth:
        req.add_header("Authorization", f"Bearer {API_KEY}")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"voice-api {exc.code}: {detail}")
    except urllib.error.URLError as exc:
        raise RuntimeError(f"voice-api unreachable at {url}: {exc.reason}")


@mcp.tool()
def transcribe(audio_base64: str, language: str = "vi") -> str:
    """Transcribe an audio clip (voice message) to text.

    audio_base64: audio bytes, base64-encoded (ogg/opus, mp3, wav, m4a...).
    language: expected language code like 'vi' or 'en'; '' to auto-detect.
    """
    out = _request("POST", "/transcribe",
                   {"audio_base64": audio_base64, "language": language or None})
    return out.get("text") or "(no speech detected)"


@mcp.tool()
def speak(text: str, lang: str = "vi", engine: str = "", voice: str = "", style: str = "") -> str:
    """Synthesize speech and return the PUBLIC URL of an Ogg/Opus clip.

    Returns a short URL string (never base64). lang defaults to 'vi'. engine
    ('gtts'|'gemini'), voice and style are optional; voice/style apply to Gemini
    only and fall back to the server defaults when omitted.
    """
    body: dict = {"text": text, "lang": lang or "vi"}
    if engine:
        body["engine"] = engine
    if voice:
        body["voice"] = voice
    if style:
        body["style"] = style
    out = _request("POST", "/speak", body)
    return out["url"]


@mcp.tool()
def list_voices() -> dict:
    """List available Gemini voices and the current server default voice/style."""
    return _request("GET", "/voices")


@mcp.tool()
def voice_info() -> dict:
    """Current engine, default voice and health of the Voice API (proxies /healthz)."""
    return _request("GET", "/healthz", auth=False)


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
