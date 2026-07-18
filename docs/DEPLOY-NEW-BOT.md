# Dựng thêm 1 bot mới (runbook thực chiến — v2.2 worker)

> v2.2 = transport worker (`tg-worker.py`), layout một volume `~/.claude`. 1 image = 1 bot: mỗi bot có Telegram identity riêng, volume riêng, container riêng. Các bot có thể chung 1 `CLAUDE_CODE_OAUTH_TOKEN` (mỗi bot = 1 phiên `claude -p` song song trên cùng account). Worker là daemon headless — KHÔNG cần `-it`/PTY.

## 0. Chuẩn bị
- **Token Telegram bot mới** từ @BotFather (`/newbot`). Không dùng chung handle với bot khác.
- Chọn `NAME` (vd `bot-claude-support`) → dùng cho container + volume.
- `OWNER_ID` = user_id Telegram của chủ.
- `MODEL` (tuỳ chọn) — vd `sonnet`. `CLAUDE_CODE_OAUTH_TOKEN` (subscription) — reuse từ bot cũ (mục 2).
- Soạn sẵn `CLAUDE.md` (rule + ngữ cảnh) cho bot nếu muốn (tuỳ chọn).

## 1. Chạy container (entrypoint tự seed access.json + workspace)
```bash
docker run -dt --name ${NAME} --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN="$TG" -e OWNER_ID="$OWNER_ID" \
  -e CLAUDE_CODE_OAUTH_TOKEN="$OAUTH" -e MODEL=sonnet \
  -v ${NAME}-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
```
> Entrypoint tự seed `access.json` (allowlist owner-only, `mentionPatterns` từ getMe) với `groups:{}` rỗng, + `~/.claude/workspace/{reminders,.workspace}`. `ANTHROPIC_API_KEY` bị worker bỏ qua (ép subscription).
> Bot cá nhân tin cậy muốn nới quyền: thêm `-e TG_WORKER_ALLOWED_TOOLS="mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch,Bash,Edit,Write"`.

## 2. Reuse OAuth token từ bot đang chạy (không in ra)
```bash
OAUTH=$(docker inspect <bot-cũ> --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p')
```

## 3. Seed CLAUDE.md dự án (tuỳ chọn)
```bash
# work-dir CLAUDE.md của bot = ~/.claude/workspace/CLAUDE.md (layer trên base). PHẢI chown 1000:1000.
docker cp CLAUDE.md ${NAME}:/home/botuser/.claude/workspace/CLAUDE.md
docker exec -u root ${NAME} chown 1000:1000 /home/botuser/.claude/workspace/CLAUDE.md
```
> Base CLAUDE.md (bảo mật + quy tắc worker) đã được entrypoint seed sẵn vào `~/.claude/CLAUDE.md`.

## 4. Cắm mempalace (nếu muốn chung bộ não)
```bash
TOKEN=$(docker exec -u botuser <bot-cũ> sh -c 'cat /home/botuser/.claude/.claude.json' \
  | jq -r '[.. | objects | (.mcpServers?.mempalace?.headers?.Authorization // empty)] | map(select(length>0)) | .[0]' | sed 's/^Bearer //')
docker exec -u botuser ${NAME} sh -c \
  "HOME=/home/botuser CLAUDE_CONFIG_DIR=/home/botuser/.claude claude mcp add --scope user --transport http mempalace https://mempalace.veasy.vn/mcp --header 'Authorization: Bearer $TOKEN'"
docker restart ${NAME}
docker exec -u botuser ${NAME} sh -c 'HOME=/home/botuser CLAUDE_CONFIG_DIR=/home/botuser/.claude claude mcp list'
```
> mempalace đã có trong `TG_WORKER_ALLOWED_TOOLS` mặc định.

## 5. Bật nhóm (chủ tự chạy ở terminal)
```bash
docker exec -u botuser ${NAME} tg-access group add <groupId>
```
> access.json đọc lại theo từng tin → hiệu lực NGAY, không cần restart. Bot phải được add vào nhóm.

## 6. Kiểm tra
```bash
docker exec ${NAME} bot-doctor
docker exec -u botuser ${NAME} sh -c 'tail -20 /home/botuser/.claude/telegram/worker.log'
```

## ⚠️ GOTCHAS (đọc kỹ)
- **MỌI `docker exec` thao tác state phải kèm `-u botuser`** (tg-access, claude mcp, tg-reminder). Chạy bằng root → file trong `~/.claude` bị root chiếm.
- **`tg-access` (mọi mutation access) chỉ chạy ở host/terminal**, KHÔNG wire vào tin Telegram (chống prompt-injection). access.json auto-seed `groups:{}` rỗng → luôn phải add nhóm thủ công.
- Xem bot live (không tmux nữa): `docker logs -f ${NAME}` hoặc `tail -f ~/.claude/telegram/worker.log`.
- Chỉ mount `~/.claude` — đừng mount cả `/home/botuser` (che binary claude/bun trong image).
- Token bí mật: reuse qua `docker inspect` / config bot cũ, KHÔNG in ra chat. Token BotFather lỡ lộ → `/revoke`.
