# claude-telegram-docker

**🇻🇳 Tiếng Việt** · [🇬🇧 English](./README.en.md)

Chạy một con bot Telegram do Claude Code vận hành, gói gọn trong một container duy nhất. **1 image = 1 bot.**
Thiết kế chi tiết: [`SPEC.md`](./SPEC.md). Bảng lệnh vận hành nhanh: [`CHEATSHEET.md`](./CHEATSHEET.md). Vận hành & xử lý sự cố: [`OPERATIONS.md`](./OPERATIONS.md).

## v2.2 — transport "worker" (thay cho `--channels`)

Từ v2.2, image **bỏ hẳn `claude --channels`** (poller của CLI channel-host hay chết lúc start/restart). Thay vào đó là **một worker Python dùng Bot API** (`scripts/tg-worker.py`) làm tiến trình chính của container: nó tự long-poll `getUpdates`, và với mỗi tin thì gọi headless `claude -p` một lần. Ưu điểm:

- **Ổn định**: worker tự làm chủ vòng poll, không phụ thuộc CLI channel-host hay bị kẹt ô nhập.
- **Nhẹ ~20x lúc rảnh** (~13MB vs ~280MB); không tmux, không cron.
- **Luôn dùng subscription** (worker gỡ `ANTHROPIC_API_KEY` → không tốn tiền theo token).
- **Mở khoá tính năng mới**: nhắc lịch (cron/reminders) + hỏi-lại-qua-Telegram.

**Breaking**: layout đổi sang **một volume `~/.claude` duy nhất**; không tương thích ngược volume `/data` của v1.x. Ship dưới tag riêng **`:v2.2.0`** (KHÔNG đụng `:latest`). Migrate = cài mới sạch (xem [Di trú](#di-trú-từ-v1x-sang-v22-cài-mới-sạch)). Rollback = quay lại image v1.x cũ.

## Tính năng

- **Worker Bot-API** (`tg-worker.py`, stdlib thuần): getUpdates long-poll → cổng access.json (DM + nhóm) → react 👀 → `claude -p` (json) → sendMessage (chunk ≤3800, quote-reply trong nhóm) → parse `[[react:X]]`; giữ session theo từng `chat_id` (`--resume`). Không crash vòng lặp; log ở `~/.claude/telegram/worker.log`.
- **Nhắc lịch / reminders**: một luồng scheduler trong worker quét `~/.claude/workspace/reminders/*.json` mỗi ~45s và bắn khi tới hạn (`mode:text` → gửi thẳng; `mode:claude` → chạy một lượt `claude -p` rồi gửi kết quả). One-off hoặc lặp daily/weekly, theo giờ container (Asia/Ho_Chi_Minh). CLI: `tg-reminder add|list|remove`.
- **Hỏi-lại qua Telegram**: khi cần owner quyết, Claude GỬI câu hỏi như một reply rồi KẾT THÚC lượt; tin kế tiếp của owner là câu trả lời, phiên tiếp tục nhờ `--resume` (không AskUserQuestion, không chờ terminal). Ép bằng rule trong CLAUDE.md.
- **Quyền an toàn theo mặc định**: `--allowedTools` mặc định = `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch` — **KHÔNG có Bash tự do** (an toàn cho bot đứng trong nhóm, chống prompt-injection). Bot cá nhân tin cậy nới thêm qua `TG_WORKER_ALLOWED_TOOLS`. `PERMISSION_MODE`/`TG_WORKER_PERMISSION_MODE` map sang `--permission-mode` hợp lệ (`auto`→`acceptEdits`).
- **Quy tắc nền bake sẵn** (`default-CLAUDE.md` → `~/.claude/CLAUDE.md`): chỉ nghe owner, phát hiện prompt-injection + cảnh báo, cách ly ngữ cảnh giữa các nhóm/DM, bắt xác nhận việc phá hoại, giọng trả lời lịch sự (ghi đè caveman), + quy tắc worker (câu trả lời cuối = tin gửi cho owner) + hỏi-lại-qua-Telegram + quản lý reminder.
- **Bộ não thứ hai `.workspace/{rules,memory,events,status}`** tạo sẵn trong work dir; SessionStart hook nạp lại mỗi lượt `claude -p`; đồng bộ tuỳ chọn với mempalace.
- **`permissions` bake sẵn** trong settings.json (chặn đọc secret + circuit-breaker phá hoại; cho git read-only + `gh`).
- **`gh` CLI bake sẵn** cho thao tác GitHub. **TZ=Asia/Ho_Chi_Minh** + **UTF-8** (`LANG=C.UTF-8`).
- **Chạy dưới root** nếu cần: `-e BOT_USER=root -e BOT_HOME=/root`.
- **Công cụ vận hành**: `bot-doctor` (check tiến trình worker / heartbeat / quyền / poller drain / login / reminders) + `tg-healthcheck` gắn HEALTHCHECK (worker sống + heartbeat tươi).
- **Biến thể `:v2.2.0-playwright`** cho bot cần render UI + chụp màn hình (build FROM base v2.2.0).
- **Bot chuyên trách (role profiles)** qua `-e BOT_ROLE=<ba|planner|dev-fe|dev-be|tester|infra>` — layer thêm CLAUDE.md + settings + rules; bỏ trống = mặc định.

## Bắt đầu nhanh (image v2.2.0 đã publish)

```bash
docker run -d --name mybot \
  -e TELEGRAM_BOT_TOKEN=<lấy từ @BotFather> \
  -e OWNER_ID=<Telegram user_id của bạn> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<tạo bằng: claude setup-token> \
  -v mybot-claude:/home/botuser/.claude \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
```

Worker là daemon headless — **KHÔNG cần `-it`/PTY** (khác `--channels` cũ). Xác thực dùng **subscription**: cấp `CLAUDE_CODE_OAUTH_TOKEN` (khuyến nghị, tạo một lần bằng `claude setup-token`), hoặc đăng nhập tương tác một lần (creds lưu trên volume `~/.claude`):

```bash
docker exec -it -u botuser mybot claude auth login
docker exec -u botuser mybot claude auth status   # loggedIn:true
```

> ⚠️ `ANTHROPIC_API_KEY` bị worker **cố ý bỏ qua** (ép dùng subscription). Đừng dựa vào nó để auth.

Kiểm tra / quản lý quyền truy cập:

```bash
docker exec -u botuser mybot bot-doctor
docker exec -u botuser mybot tg-access status
docker exec -u botuser mybot tg-access group add <group-id>
```
> ⚠️ Chạy `tg-access` (và `claude ...`) với **`-u botuser`** (bot chạy non-root; chạy bằng root thì file trong `~/.claude` bị root chiếm).

## Xem bot đang làm gì

Không còn tmux. Theo dõi qua log worker + transcript:

```bash
docker logs --tail 40 mybot
docker exec -u botuser mybot sh -c 'tail -f /home/botuser/.claude/telegram/worker.log'
# transcript từng lượt claude -p (JSONL):
docker exec -u botuser mybot sh -c 'tail -f /home/botuser/.claude/projects/*/*.jsonl'
```

## Build tại máy (phát triển)

```bash
cp .env.example .env      # điền TELEGRAM_BOT_TOKEN + OWNER_ID + CLAUDE_CODE_OAUTH_TOKEN
docker compose up -d --build
docker exec -u botuser claude-tg-bot bot-doctor
```

## Cách hoạt động

- **Base** `debian:bookworm-slim` + `bun` + Claude Code CLI (native installer) + `python3` (runtime worker). **Không** cài plugin telegram.
- **`entrypoint.sh`** (chạy dưới root): seed config bake sẵn vào volume `~/.claude` **lần đầu (cài mới sạch, KHÔNG migrate copy)**, seed token + `access.json` (`allowlist`, `allowFrom=[OWNER_ID]`), `unset ANTHROPIC_API_KEY`, rồi `exec gosu botuser python3 tg-worker.py`.
- **State trên một volume `~/.claude`**: `settings.json`/`CLAUDE.md`/`plugins/`/creds; `telegram/` (token, `access.json`, `sessions/`, `worker.log`); `workspace/` (cwd, `reminders/`, `.workspace/`).
- **Quản trị qua `docker exec tg-access …`** (host = kênh đã xác thực). Không bao giờ đổi quyền từ tin Telegram.

## Biến môi trường

| Biến | Bắt buộc | Ghi chú |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | lấy từ @BotFather |
| `OWNER_ID` | ✅ | Telegram user_id của bạn (1 owner) |
| `CLAUDE_CODE_OAUTH_TOKEN` | khuyến nghị | xác thực headless (subscription) — tạo bằng `claude setup-token`. Sống sót khi xoá volume. |
| `TG_WORKER_ALLOWED_TOOLS` | tuỳ chọn | comma-list cho `--allowedTools`. Mặc định `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch` (KHÔNG Bash). Nới cho bot cá nhân tin cậy. |
| `TG_WORKER_PERMISSION_MODE` | tuỳ chọn | `--permission-mode` của worker (`default`/`acceptEdits`/`bypassPermissions`/`plan`). Không set → lấy `PERMISSION_MODE`. |
| `PERMISSION_MODE` | tuỳ chọn | Alias: `auto`→`acceptEdits`, `manual`→`default`, rỗng→`acceptEdits`. |
| `MODEL` | tuỳ chọn | vd `sonnet` |
| `TZ` | tuỳ chọn | mặc định `Asia/Ho_Chi_Minh` — scheduler nhắc lịch bắn theo giờ này |
| `BOT_ROLE` | tuỳ chọn | `ba`/`planner`/`dev-fe`/`dev-be`/`tester`/`infra`; bỏ trống = mặc định |
| `WORK_DIR` / `CLAUDE_CONFIG_DIR` / `TELEGRAM_STATE_DIR` | tuỳ chọn | mặc định layout `~/.claude` |

## Nhắc lịch (reminders)

Owner nói "nhắc anh 8h sáng mai họp" / "mỗi thứ 2 9h nhắc report" → Claude dùng `tg-reminder` tạo reminder; scheduler trong worker bắn khi tới hạn (giờ container).

```bash
tg-reminder add --chat <chat_id> --text "Uống nước" --daily 15:00
tg-reminder add --chat <chat_id> --prompt "Tóm tắt tin AI hôm nay" --weekly mon 09:00
tg-reminder add --chat <chat_id> --text "Họp team" --at 2026-07-20T08:00
tg-reminder list
tg-reminder remove <id>
```
`--text` = gửi thẳng chuỗi; `--prompt` = chạy một lượt `claude -p` rồi gửi output (nội dung động). Đúng một trong `--text`/`--prompt`, đúng một lịch (`--at`/`--daily`/`--weekly`).

## Di trú từ v1.x sang v2.2 (cài mới sạch)

v2.2 KHÔNG migrate volume `/data` cũ (copy sẽ vỡ đường dẫn plugin). Mỗi bot làm mới:

```bash
# 1) tạo volume ~/.claude mới, chạy container trên :v2.2.0 (giữ token + owner)
docker run -d --name <bot> --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e CLAUDE_CODE_OAUTH_TOKEN=<oauth> -e MODEL=sonnet \
  -v <bot>-claude:/home/botuser/.claude \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:v2.2.0
# 2) cắm lại mempalace MCP (token riêng từng bot)
docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace \
  https://<domain>/mcp --header "Authorization: Bearer <token>"
docker restart <bot>
# 3) bật nhóm (chủ tự chạy ở terminal)
docker exec -u botuser <bot> tg-access group add <groupId>
```
Rollback = giữ nguyên container/volume v1.x cũ (đừng xoá cho tới khi v2.2 chạy ổn).

## Lưu ý (gotchas)

- **Một token = một container.** Telegram chỉ cho một poller `getUpdates`/token → hai container cùng token = 409 conflict.
- Đổi token thì restart container (worker đọc token một lần lúc boot).
- **Chỉ mount `~/.claude`**, đừng mount cả `/home/botuser` (sẽ che mất binary `claude`/`bun` trong layer image).
- **Bot đứng trong nhóm**: giữ `TG_WORKER_ALLOWED_TOOLS` mặc định (không Bash) để an toàn injection.
- Chi tiết + playbook: [`OPERATIONS.md`](./OPERATIONS.md).

## tg-access

```
tg-access status
tg-access allow <userId> | remove <userId>
tg-access policy <pairing|allowlist|disabled>
tg-access group add <groupId> [--allow id1,id2] [--no-mention]
tg-access group rm <groupId>
tg-access pair <code>
```

## Bot chuyên trách (role profiles)

Bỏ trống = mặc định. Chi tiết: [`roles/README.md`](./roles/README.md).

| `BOT_ROLE` | Giai đoạn | Bot làm gì |
|---|---|---|
| `ba` | Define | Làm rõ yêu cầu, user story + acceptance criteria + spec gọn, prototype UI → preview; sign-off → tạo work item + sync KB + handoff. |
| `planner` | Planning | Phân rã item cha → sub-task theo mảng + estimate + link → board → publish. |
| `dev-fe` | Build (FE) | Nhặt `area:frontend` → branch → code UI → PR `Closes #issue`. |
| `dev-be` | Build (BE) | Nhặt `area:backend` → branch → code API/DB + migration → PR. |
| `tester` | Tester/QA | Từ release notes viết test case; nhận bug → đối chiếu spec → publish + tag lead. |
| `infra` | Ops | Agent DevOps cho fleet: deploy/recreate/update bot, triage health/logs. Chỉ nghe owner; xác nhận trước hành động phá hoại; không in secret. |

## Biến thể `:v2.2.0-playwright` (render UI + chụp màn hình)

Base v2.2.0 + Node 20 thật + Chromium + Playwright (nặng ~1GB, **chỉ amd64**). Cấp cho một bot:

```bash
# chạy/recreate bot trên image :v2.2.0-playwright (giữ volume + env)
docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless
docker restart <bot>
# nới allowedTools để bot dùng được browser:
#   -e TG_WORKER_ALLOWED_TOOLS="mcp__mempalace,mcp__playwright,Read,Grep,Glob,WebFetch,WebSearch"
```
> ⚠️ Dùng `playwright-mcp --headless` (binary bake sẵn), KHÔNG dùng `npx @playwright/mcp@latest`.

## Giấy phép

[MIT](./LICENSE) © Edward Nguyen

## Contributors

Thanks to everyone who has contributed to this project 💙

[![Contributors](https://contrib.rocks/image?repo=trongnguyenbinh/claude-telegram-docker)](https://github.com/trongnguyenbinh/claude-telegram-docker/graphs/contributors)
