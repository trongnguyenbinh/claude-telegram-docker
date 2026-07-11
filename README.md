# claude-telegram-docker

**🇻🇳 Tiếng Việt** · [🇬🇧 English](./README.en.md)

Chạy một con bot Telegram do Claude Code vận hành, gói gọn trong một container duy nhất. **1 image = 1 bot.**
Thiết kế chi tiết: [`SPEC.md`](./SPEC.md). Bảng lệnh vận hành nhanh: [`CHEATSHEET.md`](./CHEATSHEET.md). Vận hành & xử lý sự cố: [`OPERATIONS.md`](./OPERATIONS.md).

## Tính năng (v1.5.0)

- **Quy tắc nền bake sẵn** (`default-CLAUDE.md` → `/data/.claude/CLAUDE.md`, user-level memory, CLAUDE.md work-dir của từng bot layer chồng lên): chỉ nghe owner, phát hiện prompt-injection + cảnh báo owner, cách ly thông tin (không lộ nội dung DM riêng, không mang context giữa các group/DM), bắt xác nhận việc phá hoại, giọng trả lời lịch sự **ghi đè** chế độ cộc lốc/caveman, và tự kiểm tra đã gọi reply tool chưa.
- **Bộ não thứ hai `.workspace/{rules,memory,events,status}`** tạo sẵn trong work dir ở lần chạy đầu; quy ước ghi nằm trong quy tắc nền; đồng bộ với mempalace.
- **`permissions` bake sẵn** trong settings.json: chặn đọc secret (`.env`/`secrets`/key, neo theo cwd nên KHÔNG chặn token `/data` của chính bot) + circuit-breaker cho lệnh phá hoại; cho phép git read-only + `gh` thường dùng.
- **`gh` CLI + `cron` bake sẵn**: GitHub thao tác qua `gh` (auth bằng `-e GH_TOKEN=<PAT>` + `gh auth setup-git`, KHÔNG dùng github MCP plugin vì đang lỗi); cron daemon chạy sẵn cho nhắc lịch.
- **Auto Mode mặc định** (`PERMISSION_MODE=auto`, classifier-gated) → bot không hỏi vặt mà vẫn chặn hành động rủi ro. (`acceptEdits` vẫn hỏi ở mọi lệnh Bash.)
- **UTF-8** (`LANG=C.UTF-8` + `tmux -u`) để tiếng Việt render đúng khi attach session.
- **Chạy dưới root** (không cần đổi image): `-e BOT_USER=root -e BOT_HOME=/root`.
- **Công cụ vận hành**: `bot-doctor` (`docker exec <bot> bot-doctor` — check tmux session / permission mode / poller pending-drain / locale / base CLAUDE.md / .workspace / login + in cách fix) và `tg-healthcheck` gắn làm Docker HEALTHCHECK (đánh dấu container `unhealthy` khi tmux session `claude` chết). Playbook + gotcha ở [`OPERATIONS.md`](./OPERATIONS.md).
- **Biến thể `:playwright`** cho bot cần render UI + chụp màn hình (xem mục dưới).
- **Bot chuyên trách (role profiles)** qua `-e BOT_ROLE=<ba|planner|dev-fe|dev-be|tester>`: seed thêm 1 lớp CLAUDE.md + settings + rules cho từng vai trò trong quy trình delivery, chồng lên base. Bỏ trống = mặc định như cũ (xem mục dưới).

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

> **Permission mode:** mặc định `auto` (Auto Mode có classifier) — chạy headless không treo, không hỏi vặt mà vẫn chặn hành động rủi ro; hợp bot. `acceptEdits` chỉ tự duyệt file-edit, VẪN hỏi ở mọi lệnh Bash.
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
| `PERMISSION_MODE` | tuỳ chọn | `auto`/`default`/`acceptEdits`/`bypassPermissions`/`manual`/`plan`. **Bỏ trống = `auto`** — Auto Mode có classifier: tự duyệt hành động an toàn, chặn hành động rủi ro/production → bot chạy nền không treo mà vẫn an toàn. Override khi cần, vd `acceptEdits`. |
| `BOT_ROLE` | tuỳ chọn | Bot chuyên trách: `ba`/`planner`/`dev-fe`/`dev-be`/`tester`. Seed CLAUDE.md + settings + rules của vai trò (layer trên base) ở lần chạy đầu. **Bỏ trống / `default` = hành vi mặc định như cũ.** Xem [Bot chuyên trách](#bot-chuyên-trách-role-profiles) + `roles/README.md`. |
| `WORK_DIR` | tuỳ chọn | thư mục claude của bot chạy trong đó (file ops rơi vào đây, đã pre-trust). Mặc định `/working-directory/claude-telegram-bot`; lưu trên volume `botwork`. |
| `ANTHROPIC_API_KEY` | dự phòng | trả tiền theo token thay vì dùng subscription |
| `MODEL` / `TZ` | tuỳ chọn | |

## Lưu ý (gotchas)

- `claude --channels` là TUI tương tác → container cần PTY (`tty: true` + `stdin_open: true`, đã set sẵn trong compose; dùng `-it` với `docker run`).
- **Một token = một container.** Telegram chỉ cho một poller `getUpdates` mỗi token; hai container cùng token → lỗi 409 conflict.
- Đổi token thì phải restart container (token chỉ đọc một lần lúc boot).
- **Poller kẹt sau recreate:** verify `pending_update_count` về 0 (dùng `bot-doctor`); nếu poller đứng (1 tin kẹt ô nhập) → `docker restart <bot>` là thông.
- **`permissions` bake chỉ seed volume MỚI** — bot cũ phải merge tay vào `/data/.claude/settings.json` rồi restart.
- **Network phụ (vd `db-shared`) KHÔNG được giữ khi recreate trơn** → thêm `--network <net>` vào `docker run`.
- Chi tiết + playbook: [`OPERATIONS.md`](./OPERATIONS.md).

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

## Bot chuyên trách (role profiles)

Một bot có thể khởi động ở một **vai trò** trong quy trình delivery bằng AI (Define/BA → Planning → Build → Tester/QA) qua biến `BOT_ROLE`. Mỗi vai trò seed thêm 1 lớp CLAUDE.md "cách làm việc" + `settings-fragment` + rules, **layer chồng lên** base CLAUDE.md (bảo mật, cách ly thông tin, `.workspace`, giọng trả lời vẫn là nền chung).

| `BOT_ROLE` | Giai đoạn | Bot làm gì |
|---|---|---|
| `ba` | Define | Phân tích đề bài, viết acceptance criteria + tài liệu, dựng prototype UI → Vercel preview; PO/BA accept → tạo GitHub Issue + sync mempalace + publish handoff. |
| `planner` | Planning | Phân rã issue cha → sub-issue theo mảng (`area:frontend/backend/db/infra/qa`) + estimate + link cha → Projects board → publish + @mention. |
| `dev-fe` | Build (FE) | Nhặt sub-issue `area:frontend` → branch → code UI → PR `Closes #issue`; biết gate Sonar + security; frontend-design + Vercel + Playwright. |
| `dev-be` | Build (BE) | Nhặt sub-issue `area:backend` → branch → code API/DB + migration → PR `Closes #issue`; ý thức migration/db + gate. |
| `tester` | Tester/QA | Từ release note hướng dẫn test + tạo testcase; nhận log-issue web UAT → đối chiếu đặc tả + mempalace → nghi bug thật thì publish channel + tag Lead. |

**Bỏ trống / không đặt / `default` = hành vi mặc định như cũ, KHÔNG đổi gì** (bot hiện có không bị ảnh hưởng). Role không hợp lệ → entrypoint log cảnh báo rồi chạy như mặc định.

```bash
# ví dụ: khởi động bot BA
docker run -d --name thedots-ba \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> -e BOT_ROLE=ba \
  -v thedots-ba-data:/data --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
```

> CLAUDE.md của vai trò chỉ seed khi work-dir CHƯA có CLAUDE.md (không đè file riêng của bot). Phần `settings-fragment` là union (chạy lại vô hại). Cách thêm vai trò mới: xem [`roles/README.md`](./roles/README.md).

## Biến thể `:playwright` (render UI + chụp màn hình)

Cho bot cần chạy trình duyệt (dựng UI, chụp screenshot). Biến thể này = image nền + Node 20 thật + Chromium + Playwright (nặng hơn ~1GB, **chỉ amd64**). Build bằng `Dockerfile.playwright`, publish tag `:playwright`.

Cấp Playwright cho một bot:

```bash
# 1) Chạy / recreate bot bằng image :playwright (giữ nguyên volume + env như thường)
ghcr.io/trongnguyenbinh/claude-telegram-docker:playwright

# 2) Cắm Playwright MCP bằng BINARY đã bake (KHÔNG dùng npx — npx tải lại package mỗi lần start → lỗi kết nối)
docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless
docker restart <bot>
```

> ⚠️ Phải dùng `playwright-mcp --headless` (binary global đã bake), KHÔNG dùng `npx @playwright/mcp@latest` (tải lại mỗi lần boot → MCP "Failed to connect" + có thể kẹt poller).

## Giấy phép

[MIT](./LICENSE) © Edward Nguyen
