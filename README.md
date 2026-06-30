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

# Xác thực Claude một lần — tạo token (dùng gói subscription Claude của bạn):
docker exec -it mybot claude setup-token
#   → mở một URL, authorize, dán TOÀN BỘ mã; nó IN RA một token sống lâu.
# Nhét token đó vào env của container rồi tạo lại (recreate):
#   thêm  CLAUDE_CODE_OAUTH_TOKEN=<token>  vào cờ -e / file .env, rồi:
docker rm -f mybot && docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<token-vừa-setup-token-in-ra> \
  -v botdata:/data --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
#   (token qua env = xác thực headless, sống sót cả khi xoá volume. `claude auth
#    login` hay bị lỗi 400 trong container — không có trình duyệt thật / lệch PKCE.)
docker exec mybot claude auth status   # loggedIn:true
```

Xong. Kiểm tra trạng thái / quản lý quyền truy cập:

```bash
docker exec mybot claude auth status
docker exec mybot tg-access status
docker exec mybot tg-access group add <group-id>
```

Image được GitHub Actions publish lên GHCR mỗi lần push vào `main` và mỗi tag `v*`
(`.github/workflows/docker-publish.yml`, linux/amd64 + arm64).

## Hoặc build tại máy (cho phát triển)

```bash
cp .env.example .env      # điền TELEGRAM_BOT_TOKEN + OWNER_ID
docker compose up -d --build
# xác thực một lần — IN RA token (KHÔNG tự lưu):
docker exec -it claude-tg-bot claude setup-token
#   → mở URL, authorize, dán TOÀN BỘ mã; nó in ra token sống lâu.
# Nhét token vào .env, rồi RECREATE (không phải `restart` — restart không nạp lại env):
#   thêm  CLAUDE_CODE_OAUTH_TOKEN=<token-vừa-in>  vào .env, rồi:
docker compose up -d
docker exec claude-tg-bot claude auth status   # loggedIn:true
```

> Lưu ý: `setup-token` chỉ *in ra* một token headless (`Use this token by setting:
> export CLAUDE_CODE_OAUTH_TOKEN=...`). Nó **không** ghi credentials vào volume, nên
> `docker compose restart` không đủ — vẫn `loggedIn:false`. Phải nhét token vào
> `.env` (`CLAUDE_CODE_OAUTH_TOKEN`) và **tạo lại** container (`docker compose up -d`)
> để env được đọc lại.

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
