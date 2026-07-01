# claude-telegram-docker

**🇻🇳 Tiếng Việt** · [🇬🇧 English](./README.en.md)

Chạy một con bot Telegram do Claude Code vận hành, gói gọn trong một container duy nhất. **1 image = 1 bot.**
Thiết kế chi tiết: [`SPEC.md`](./SPEC.md).

## Bắt đầu nhanh (dùng image đã publish — khỏi build, khỏi clone)

```bash
docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<lấy từ @BotFather> \
  -e OWNER_ID=<Telegram user_id của bạn> \
  -v botdata:/data \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest

# Xác thực Claude một lần — ĐĂNG NHẬP TƯƠNG TÁC, chạy AS botuser (user bot chạy):
docker exec -it -u botuser mybot claude auth login
#   → mở URL in ra, authorize, dán mã. Creds lưu vào /data/.claude (trên volume)
#     → sống qua restart, KHÔNG cần recreate.
#   ⚠️ PHẢI có -u botuser để creds thuộc botuser; thiếu nó login vào user root → bot đọc không ra.
docker exec -u botuser mybot claude auth status   # loggedIn:true
# (Tuỳ chọn thay thế: -e ANTHROPIC_API_KEY / -e CLAUDE_CODE_OAUTH_TOKEN vẫn dùng được.)
```

Xong. Kiểm tra trạng thái / quản lý quyền truy cập:

```bash
docker exec -u botuser mybot claude auth status
docker exec -u botuser mybot tg-access status
docker exec -u botuser mybot tg-access group add <group-id>
```
> ⚠️ Chạy `tg-access` (và `claude ...`) với **`-u botuser`**. Bot chạy non-root
> (botuser) và `access.json` thuộc botuser; chạy tg-access bằng root thì thay đổi
> KHÔNG lưu được (bị server ghi đè) — group/allow add xong mà `status` vẫn trống.

## Xem bot đang làm gì (monitor session)

`claude --channels` chạy trong một **tmux session tên `claude`**. Hai cách theo dõi:

**1) Attach vào tmux session** — thấy trực tiếp phiên claude live:
```bash
docker exec -it -u botuser mybot tmux attach -t claude
```
> Thoát an toàn bằng **Ctrl+B rồi D** (detach — bot vẫn chạy bình thường, tmux không bị giết). Đây là lý do dùng tmux: an toàn hơn `docker attach` (vốn dễ lỡ Ctrl+C làm tắt bot).
> Nhớ `-u botuser` (session thuộc user botuser).

**2) Đọc transcript** — bản ghi từng phiên (JSONL: claude nghĩ gì, gọi tool nào):
```bash
docker exec mybot sh -c 'ls -t /data/.claude/projects/*/*.jsonl | head'
docker exec mybot sh -c 'tail -f /data/.claude/projects/*/*.jsonl'
```

Image được GitHub Actions publish lên GHCR mỗi lần push vào `main` và mỗi tag `v*`
(`.github/workflows/docker-publish.yml`, linux/amd64 + arm64).

## Hoặc build tại máy (cho phát triển)

```bash
cp .env.example .env      # điền TELEGRAM_BOT_TOKEN + OWNER_ID
docker compose up -d --build
# xác thực một lần — đăng nhập tương tác AS botuser (creds lưu trên volume):
docker exec -it -u botuser claude-tg-bot claude auth login
docker exec -u botuser claude-tg-bot claude auth status   # loggedIn:true
```

> **Permission mode:** mặc định `acceptEdits` — chạy headless không hộp thoại, hợp bot.
> Container chạy non-root (`botuser`): entrypoint khởi động bằng root chỉ để `chown`
> volume rồi hạ quyền xuống botuser (gosu) trước khi chạy `claude --channels`.
>
> ⚠️ **bypassPermissions** (tự chạy MỌI tool không hỏi) KHÔNG chạy được headless: Claude
> Code 2.1.126+ bắt xác nhận hộp thoại "Yes, I accept" mỗi lần start, không có cách skip
> tự động → bot sẽ TREO. Nếu cần, phải bấm tay: `docker exec -it -u botuser <bot> tmux
> attach -t claude` → ↓ chọn "Yes, I accept" → Enter → Ctrl+B D (và lặp lại khi volume mới).
>
> **Đăng nhập** dùng `claude auth login` (tương tác), creds lưu vào `/data/.claude`
> trên volume → sống qua restart, login một lần. Nhớ `-u botuser` để creds thuộc đúng
> user bot chạy.

## Cách hoạt động

- **Base** `debian:bookworm-slim` + `bun` (plugin telegram chạy MCP server bằng bun) + Claude Code CLI (native installer) + plugin telegram bake sẵn trong image.
- **`entrypoint.sh`** (lần chạy đầu): seed plugin đã bake vào volume, ghi bot token, và seed `access.json` thành **`allowlist` với `allowFrom=[OWNER_ID]`** (chỉ owner, không pairing). Sau đó `exec claude --channels plugin:telegram@claude-plugins-official`.
- **State nằm trên volume** (`/data`): config + credentials Claude (`/data/.claude`) và state telegram (`/data/telegram`: token, `access.json`). Sống qua restart; đăng nhập chỉ một lần.
- **Quản trị qua `docker exec tg-access …`** (host = kênh đã xác thực). Không bao giờ đổi quyền truy cập từ một tin nhắn Telegram.

## Biến môi trường

| Biến | Bắt buộc | Ghi chú |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | lấy từ @BotFather |
| `OWNER_ID` | ✅ | Telegram user_id của bạn (1 owner duy nhất) |
| `CLAUDE_CODE_OAUTH_TOKEN` | khuyến nghị | xác thực headless — tạo một lần bằng `claude setup-token`, dán vào đây. Sống sót khi xoá volume. |
| `PERMISSION_MODE` | tuỳ chọn | `default`/`acceptEdits`/`bypassPermissions`/`plan`. Bỏ trống = mặc định của claude. Đặt `bypassPermissions` cho bot tự chạy tool không hỏi (chủ động opt-in). |
| `WORK_DIR` | tuỳ chọn | thư mục claude của bot chạy trong đó (file ops rơi vào đây, đã pre-trust). Mặc định `/working-directory/claude-telegram-bot`; lưu trên volume `botwork`. |
| `ANTHROPIC_API_KEY` | dự phòng | trả tiền theo token thay vì dùng subscription |
| `MODEL` / `TZ` | tuỳ chọn | |

## Lưu ý (gotchas)

- `claude --channels` là TUI tương tác → container cần PTY (`tty: true` + `stdin_open: true`, đã set sẵn trong compose; dùng `-it` với `docker run`).
- **Một token = một container.** Telegram chỉ cho một poller `getUpdates` mỗi token; hai container cùng token → lỗi 409 conflict.
- Đổi token thì phải restart container (token chỉ đọc một lần lúc boot).

## tg-access

Quản trị quyền truy cập. **Luôn chạy với `-u botuser`** (xem cảnh báo ở trên):
`docker exec -u botuser <bot> tg-access <lệnh>`. Thay đổi có hiệu lực NGAY (access.json
đọc lại mỗi tin, không cần restart).

```
tg-access status
tg-access allow <userId> | remove <userId>
tg-access policy <pairing|allowlist|disabled>
tg-access group add <groupId> [--allow id1,id2] [--no-mention]
tg-access group rm <groupId>
tg-access pair <code>
```

## Giấy phép

[MIT](./LICENSE) © Edward Nguyen
