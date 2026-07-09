# OPERATIONS — vận hành & xử lý sự cố bot

Ghi chú vận hành + các "gotcha" đã gặp thực tế. Công cụ đi kèm baked trong image:
`bot-doctor` (chẩn đoán) và `tg-healthcheck` (Docker HEALTHCHECK liveness).

## Chẩn đoán nhanh

```bash
docker exec <container> bot-doctor        # chạy hết các bước check + gợi ý fix
docker ps                                 # cột STATUS: healthy / unhealthy (HEALTHCHECK)
docker exec -u botuser <container> tmux attach -t claude   # xem session (thoát: Ctrl+B rồi D)
```

## Recreate / update an toàn (giữ state)

State BỀN nằm ở volume (`/data`, `/working-directory`) + mempalace (remote) → recreate KHÔNG mất.
Chỉ mất "bộ nhớ ngắn hạn" của phiên đang chạy (context RAM); transcript vẫn lưu ở
`/data/.claude/projects/*.jsonl` trên volume.

Quy trình:

1. **Checkpoint mempalace trước** (nếu muốn chắc): chạy 1 lượt cho bot đẩy state bền lên mempalace.
2. **Env-preserving recreate**: copy toàn bộ env từ container cũ, chỉ override cái cần
   (thường `PERMISSION_MODE=auto`), giữ nguyên volumes:
   ```bash
   C=<container>; IMG=ghcr.io/<owner>/claude-telegram-docker:latest
   docker logout ghcr.io; docker pull "$IMG"
   ENVARGS=(); while IFS= read -r e; do case "$e" in PATH=*|HOME=*|HOSTNAME=*|TERM=*|LANG=*|LC_ALL=*|LANGUAGE=*|PERMISSION_MODE=*) continue;; esac; [ -n "$e" ] && ENVARGS+=( -e "$e" ); done < <(docker inspect "$C" --format '{{range .Config.Env}}{{println .}}{{end}}')
   ENVARGS+=( -e PERMISSION_MODE=auto )
   VOLARGS=(); while IFS= read -r m; do [ -n "$m" ] && VOLARGS+=( -v "$m" ); done < <(docker inspect "$C" --format '{{range .Mounts}}{{.Name}}:{{.Destination}}{{println}}{{end}}')
   docker rm -f "$C"; docker run -dt --name "$C" --restart unless-stopped "${ENVARGS[@]}" "${VOLARGS[@]}" "$IMG"
   ```
3. **Verify pending drain**: sau recreate, `bot-doctor` hoặc poll `getWebhookInfo` vài lần —
   `pending_update_count` phải về 0.

## Gotchas đã gặp

- **Poller kẹt sau recreate** — container Up, session sống, auto mode on, NHƯNG
  `pending_update_count` > 0 và không drain (1 tin kẹt trong ô nhập chặn poll tiếp) → bot như chết.
  **Fix:** `docker restart <container>` (1 phát là thông). `bot-doctor` phát hiện được ca này.
  **Tự lành (v1.3.1+):** `tg-watchdog` chạy qua cron mỗi phút — nếu pending kẹt 2 nhịp liền + session đang rảnh, nó tự `tmux send-keys Enter` submit tin kẹt → poller thông lại, thường khỏi cần restart tay. Log: `/tmp/tg-watchdog.log` trong container.
- **Bắt accept liên tục** — bot chạy `PERMISSION_MODE=acceptEdits` (chỉ auto file-edit, VẪN hỏi
  mọi lệnh Bash/network). Muốn không hỏi vặt → `PERMISSION_MODE=auto`. Toggle shift+tab trong
  session KHÔNG bền qua restart; phải set ở env → recreate.
- **Chạy dưới root** — không cần feature riêng: `-e BOT_USER=root -e BOT_HOME=/root` (entrypoint
  `gosu $BOT_USER`).
- **Tiếng Việt vỡ trong tmux** — thiếu locale UTF-8 (debian-slim mặc định C). Image đã đặt
  `LANG=C.UTF-8` + `tmux -u`. Bot cũ: recreate từ image mới.
- **GitHub trong bot** — dùng `gh` (đã baked), auth `-e GH_TOKEN=<PAT>` + `gh auth setup-git`.
  KHÔNG dùng github MCP plugin (bug HTTP 400).
- **Docker exec bot chạy botuser** phải `-u botuser` (tmux socket theo user); bot chạy root thì exec mặc định (root).
- **permissions block** trong staged settings.json chỉ áp cho volume MỚI; bot cũ phải merge
  tay vào `/data/.claude/settings.json` rồi restart.

## HEALTHCHECK

`tg-healthcheck` (Docker HEALTHCHECK) chỉ kiểm tra LIVENESS (session còn sống) → bắt crash/exit,
KHÔNG bắt poller-stall (session vẫn sống). Ghép một watchdog `autoheal` để tự restart container
`unhealthy`. Poller-stall: dùng `bot-doctor`.
