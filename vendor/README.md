# vendor/

Third-party code vendored (copied) into this image so voice-capable bots need no
manual `pip install` / file copy at runtime.

## `voice_mcp_proxy/`

A tiny **stdio MCP proxy** that exposes the voice-service Voice API as four MCP
tools (`transcribe`, `speak`, `list_voices`, `voice_info`). Bots get the `voice`
tool by setting `VOICE_API_URL` + `VOICE_API_KEY` (the entrypoint auto-registers
the MCP — see `entrypoint.sh`).

- **Source**: `trongnguyenbinh/voice-service`, path `mcp-proxy/voice_mcp_proxy/`
  (branch `main`, commit `4ae79e7`).
- **Runtime deps**: `mcp>=1.2` (HTTP is stdlib `urllib`). Installed in the image.
- **Run as**: `PYTHONPATH=/opt/voice-mcp-proxy python3 -m voice_mcp_proxy`
  with env `VOICE_API_URL` + `VOICE_API_KEY`.

Re-sync from upstream by copying `mcp-proxy/voice_mcp_proxy/*.py` over this dir.
