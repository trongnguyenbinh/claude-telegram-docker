# SPEC — Claude Telegram Bot, đóng gói Docker ("bot-in-a-box")

> Trạng thái: **bản spec để review** (chưa code). Mục tiêu: gói toàn bộ một con Claude-Telegram bot thành 1 Docker image chạy được bằng `docker run` / `docker compose up`, truyền token qua biến môi trường, quản trị qua `docker exec`.
> Cập nhật: 2026-06-26. **Bổ sung §v2.2 (2026-07-19).**

---

## §v2.2 — Worker transport (thay thế `--channels`)

> Từ v2.2, phần transport bên dưới (§2/§6/§7 nói về `claude --channels` + plugin telegram)
> **bị thay thế** bởi mô hình worker. Các phần access/security/state vẫn đúng về ý niệm nhưng
> đổi đường dẫn. Thiết kế đầy đủ + quyết định đã chốt: `docs/superpowers/specs/2026-07-19-v2.2-worker-image-design.md`.

**Vì sao đổi:** poller của `claude --channels` (Claude Code 2.1.214 + plugin telegram) không
ổn định — hay không start được lúc container start/restart (không có `bot.pid`,
`pending_update_count` kẹt) dù `mcp list` báo "Connected". Đã xác minh lỗi nằm ở CLI channel
host của Claude Code, không phải image. Watchdog/retry không trị dứt.

**Kiến trúc v2.2:**
- Tiến trình chính = **worker Python** (`scripts/tg-worker.py`, stdlib thuần): long-poll
  `getUpdates` (timeout 50) → cổng `access.json` (DM `allowFrom`; nhóm `requireMention`/
  `allowFrom`) → react 👀 → gọi headless `claude -p` (`--output-format json`, `--model`,
  `--permission-mode` đã map, `--allowedTools`, `--append-system-prompt` react-hint,
  `--resume` theo `chat_id`) → parse `[[react:X]]` → `sendMessage` (chunk ≤3800, quote-reply
  trong nhóm). Không tmux, không plugin telegram, không cron.
- **Auth subscription**: worker `env.pop(ANTHROPIC_API_KEY)` → luôn dùng
  `CLAUDE_CODE_OAUTH_TOKEN`/creds trên volume, không tính tiền theo token.
- **Layout một volume `~/.claude`** (`/home/botuser/.claude`): config + `plugins/` + creds;
  `telegram/` (`.env`, `access.json`, `sessions/`, `offset`, `worker.log`, `worker.heartbeat`);
  `workspace/` (cwd, `reminders/`, `.workspace/`). CHỈ mount `~/.claude` (mount cả
  `/home/botuser` sẽ che binary claude/bun trong layer image).
- **Quyền**: `--allowedTools` mặc định = `mcp__mempalace,Read,Grep,Glob,WebFetch,WebSearch`
  (KHÔNG Bash tự do — an toàn injection cho bot trong nhóm); nới qua `TG_WORKER_ALLOWED_TOOLS`.
  `PERMISSION_MODE`/`TG_WORKER_PERMISSION_MODE` map sang giá trị `--permission-mode` hợp lệ
  (`default|acceptEdits|bypassPermissions|plan`; `auto`→`acceptEdits`, `manual`→`default`).
- **Nhắc lịch (reminders)**: một luồng scheduler trong worker quét
  `~/.claude/workspace/reminders/*.json` mỗi ~45s; `mode:text` → `sendMessage`, `mode:claude`
  → chạy một lượt `claude -p` rồi gửi output; one-off (`when` ISO) hoặc lặp `daily`/`weekly`
  (theo TZ container). CLI `tg-reminder add|list|remove` + rule trong CLAUDE.md.
- **Hỏi-lại qua Telegram (behavioral)**: cần input của owner → gửi câu hỏi như reply rồi kết
  thúc lượt; tin kế của owner là câu trả lời, phiên tiếp tục nhờ `--resume`. Không
  AskUserQuestion, không chờ terminal. Ép bằng rule CLAUDE.md.
- **Entrypoint (root → botuser)**: seed `~/.claude` từ staged defaults lần đầu (cài mới sạch,
  KHÔNG copy-migrate volume v1), `unset ANTHROPIC_API_KEY`, `exec gosu botuser python3 tg-worker.py`.
- **Healthcheck**: worker sống (pgrep) + heartbeat tươi. Bỏ check tmux; bỏ `tg-watchdog`.
- **Bỏ `/etc/claude-code/managed-settings.json`** (chỉ gate `--channels`, nay không dùng).
- **Image/CI**: ship tag riêng `:v2.2.0` (breaking) + `:v2.2.0-playwright` build FROM base đã
  tag; **KHÔNG đụng `:latest`** (để recreate bot v1 trên `:latest` không nhảy nhầm sang v2.2).
- **Di trú**: cài mới sạch từng bot (volume `~/.claude` mới + token + access + mempalace).
  Rollback = image v1.x cũ.

---

## 1. Mục tiêu

Một image duy nhất, chạy lên là có ngay 1 bot Telegram do Claude Code vận hành (nhận DM/nhóm → Claude xử lý → trả lời), **không phải cài tay từng bước**. Mỗi container = 1 bot độc lập (1 token riêng) → nhân bản nhiều bot = chạy nhiều container.

Phi mục tiêu (ngoài phạm vi v1): web UI quản trị, multi-bot orchestrator, auto-update, scaling ngang nhiều node.

---

## 2. Kiến trúc tổng thể

```
docker run / compose
   │  env: TELEGRAM_BOT_TOKEN, ANTHROPIC_API_KEY, OWNER_ID, [TZ, MODEL, AUTO_PAIR]
   ▼
┌─────────────────────────── container ───────────────────────────┐
│ entrypoint.sh                                                     │
│   1. validate env (token, api key, owner bắt buộc)               │
│   2. seed state vào volume nếu chưa có:                          │
│        - $STATE/.env          (TELEGRAM_BOT_TOKEN)               │
│        - $STATE/access.json   (policy=allowlist, allowFrom=[OWNER])│
│   3. exec claude --channels plugin:telegram@claude-plugins-official│
│         (foreground, cần PTY)                                     │
│                                                                  │
│  ~/.claude/plugins  ← telegram plugin ĐÃ bake sẵn trong image    │
│  $STATE (volume)    ← .env, access.json, approved/, bot.pid      │
└──────────────────────────────────────────────────────────────────┘
        ▲ docker exec bot tg-access group add <id>   (quản trị)
```

---

## 3. Thành phần image (Dockerfile)

- **Base:** `node:22-bookworm-slim` (có node + npm).
- **bun:** cài qua `curl -fsSL https://bun.sh/install | bash` (hoặc image bun chính thức nếu gọn hơn — quyết lúc POC).
- **Claude Code CLI:** `npm i -g @anthropic-ai/claude-code`.
- **Telegram plugin: BAKE sẵn lúc build** (xem §7 — đây là phần cần xác minh kỹ).
- **tg-access CLI:** copy `scripts/tg-access` vào `/usr/local/bin` (chmod +x).
- **entrypoint.sh:** copy + chmod +x, đặt làm `ENTRYPOINT`.
- User: chạy bằng user không phải root (vd `node`) cho an toàn; `$STATE` + `~/.claude` thuộc user đó.
- `git`, `curl`, `ca-certificates`, `tini` (init reaper) cài kèm.

---

## 4. Biến môi trường (input khi chạy)

| Biến | Bắt buộc | Ý nghĩa |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | ✅ | Token bot từ @BotFather |
| `OWNER_ID` | ✅ | Telegram user_id chủ bot (1 owner — quyết định §13) → preseed allowlist |
| `CLAUDE_CONFIG_DIR` | (mặc định `/data/.claude`) | Config + credentials Claude → trỏ vào volume để persist login (§5, §7) |
| `TELEGRAM_STATE_DIR` | (mặc định `/data/telegram`) | State plugin telegram (token/access), trỏ vào volume |
| `ANTHROPIC_API_KEY` | ⬜ fallback | Chỉ dùng nếu login paste-code không khả thi (§5) |
| `MODEL` | ⬜ | Model mặc định (vd `claude-sonnet-4-6`) nếu muốn ép |
| `TZ` | ⬜ | Timezone (log/giờ) |
| `MENTION_PATTERNS` | ⬜ | Pattern @mention nếu khác tên bot |

> `AUTO_PAIR` đã BỎ khỏi v1 (quyết định §13: preseed-owner only). Có thể thêm lại ở bản sau nếu cần pairing tự động.

Secrets (token, api key) **không bao giờ** ghi vào image; chỉ truyền runtime qua env / compose / docker secret.

---

## 5. Auth Claude — QUYẾT ĐỊNH: login paste-code (Edward 2026-06-26)

**Primary = đăng nhập tài khoản Claude qua `docker exec`** (xài subscription của Edward, không cần API key riêng). Lệnh ĐÚNG (đã xác minh ở POC — KHÔNG phải `/login`, đó là lệnh gạch chéo trong giao diện tương tác):

```
docker exec -it <bot> claude auth login
#   (hoặc token sống lâu: docker exec -it <bot> claude setup-token)
#   kiểm tra: docker exec <bot> claude auth status
```
→ in **URL OAuth** → mở web authorize → lấy **mã** → **dán lại vào chính phiên đó**. Credentials lưu vào **volume** qua `CLAUDE_CONFIG_DIR=/data/.claude` → **khởi động lại không phải đăng nhập lại**.

- ⚠️ **Bắt buộc `-it`** (phiên tương tác có TTY thật). Đã xác minh: lệnh `claude auth login`/`setup-token` tồn tại; nhưng luồng OAuth (dán mã vs redirect trình duyệt) bên trong container cần Edward chạy `-it` với tài khoản anh để chốt — không tự test headless được.
- **Phương án dự phòng = `ANTHROPIC_API_KEY`** (biến môi trường): nếu đăng nhập tương tác không khả thi. Đơn giản, không cần tương tác, nhưng chi phí tính theo key.

→ v1 ưu tiên **login paste-code**; API key là phương án dự phòng. Lưu ý: credentials nằm trên volume → ai có quyền vào volume = có session đăng nhập, bảo vệ volume tương ứng.

---

## 6. Mô hình tiến trình & PTY

- `claude --channels ...` là **phiên TUI tương tác**, không phải daemon. Cần cấp **pseudo-TTY**:
  - compose: `tty: true` + `stdin_open: true`
  - docker run: `-it` (hoặc `-d -it`)
- Chạy **foreground** làm PID 1 (qua `tini` để reap zombie + nhận tín hiệu).
- `restart: unless-stopped` (compose) → bot rớt thì tự dựng lại.
- **1 token = 1 container.** Telegram chỉ cho 1 poller/token; 2 container cùng token → 409 Conflict, cướp update của nhau. Image không tự bảo vệ điều này → ghi rõ trong README.
- Đổi token = phải restart container (token đọc 1 lần lúc boot).

---

## 7. Bake telegram plugin (cần xác minh khi POC)

Plugin bình thường cài qua `/plugin` (tương tác) → không hợp build headless. Hai hướng, **xác minh hướng nào chạy được ở bước POC** (chưa chắc 100% — sẽ kiểm thực tế):

- **(A)** Chạy lệnh cài plugin **non-interactive lúc build** (nếu Claude CLI hỗ trợ cờ kiểu `claude plugin add` / marketplace add headless) → kết quả nằm ở `~/.claude/plugins` + config marketplace → commit vào layer image.
- **(B)** Bake **thủ công**: thêm marketplace `claude-plugins-official` + copy/seed cây `~/.claude/plugins/<telegram>` + ghi file config "installed plugins" mà Claude đọc lúc boot.

Ràng buộc: plugin baked phải khớp version Claude CLI cài trong image (pin version để khỏi vỡ). Plugin set `TELEGRAM_STATE_DIR` để state nằm ở volume (giống cơ chế repo hiện tại).

**Tương tác với volume (vì §5 chốt `CLAUDE_CONFIG_DIR=/data/.claude` nằm trên volume):** plugin baked nằm trong layer image (vd staging `/opt/claude-plugins`), nhưng config dir lại ở volume. → **entrypoint seed lần đầu**: nếu `$CLAUDE_CONFIG_DIR/plugins` trống thì copy plugin + marketplace config từ staging vào volume. Nhờ vậy cả **plugin + credentials login** cùng persist trên volume; lần chạy sau không seed lại, không phải login lại.

> ⚠️ Phần này là rủi ro kỹ thuật cao nhất của dự án — POC nên làm §7 (bake + seed) cùng §5 (login paste-code) TRƯỚC để chốt, rồi mới ráp phần còn lại.

---

## 8. Mô hình access & bảo mật (cốt lõi)

**Mặc định an toàn = preseed owner, KHÔNG pairing.**

- entrypoint seed `access.json`: `dmPolicy = allowlist`, `allowFrom = [OWNER_ID]`.
- → Owner dùng được ngay, người lạ bị bỏ qua, **không cần bước pairing**.
- Đây thay cho ý "auto-whitelist sau pairing".

**Vì sao KHÔNG auto-whitelist-sau-pairing mặc định:** pairing có bước người duyệt chính là lớp chống injection/spam. Auto-approve = ai DM cũng vào → bot mở toang.

- Nếu vẫn muốn pairing tự động: cờ **`AUTO_PAIR=true`** (opt-in), có **cảnh báo log rõ ràng**, và nên giới hạn (vd chỉ auto-approve user ĐẦU TIÊN rồi tự khoá `policy=allowlist`). Mặc định OFF.

**Thêm/sửa access KHÔNG qua chat** (chống prompt-injection) — chỉ qua `docker exec` (kênh host đã xác thực):

```
docker exec <bot> tg-access status
docker exec <bot> tg-access allow <userId>
docker exec <bot> tg-access remove <userId>
docker exec <bot> tg-access group add <groupId> [--allow id1,id2] [--no-mention]
docker exec <bot> tg-access group rm <groupId>
docker exec <bot> tg-access policy <pairing|allowlist|disabled>
docker exec <bot> tg-access pair <code>     # khi AUTO_PAIR=false, duyệt tay
```

`tg-access` = script sửa `$STATE/access.json` theo đúng schema plugin (server đọc lại theo từng tin → hiệu lực ngay, không restart).

---

## 9. State & persistence

- `TELEGRAM_STATE_DIR=/data` → **mount volume** (`-v botdata:/data` hoặc bind mount).
- Nội dung: `.env` (token), `access.json` (policy + allowlist + groups), `approved/<id>` (marker), `bot.pid`.
- Volume giúp: giữ access qua restart + `docker exec tg-access` sửa được + backup dễ.
- `~/.claude` (plugin + config) nằm trong image (read-mostly); chỉ state động ra volume.

---

## 10. Cấu trúc thư mục dự án

```
claude-telegram-docker/
├── SPEC.md                  ← (file này)
├── README.md                ← build & run, ví dụ lệnh
├── Dockerfile
├── docker-compose.yml       ← ví dụ 1 bot (env + volume + tty + restart)
├── docker-compose.multi.yml ← ví dụ nhiều bot (mỗi service 1 token/volume)
├── entrypoint.sh            ← validate env → seed state → exec claude --channels
├── scripts/
│   └── tg-access            ← CLI quản trị access (docker exec)
├── .env.example             ← mẫu biến (không commit .env thật)
└── .dockerignore
```

---

## 11. Build & chạy (dự kiến)

```bash
# build
docker build -t claude-telegram-docker .

# chạy 1 bot (token + owner; auth login ở bước sau)
docker run -d --name mybot -it --restart unless-stopped \
  -e TELEGRAM_BOT_TOKEN=*** -e OWNER_ID=<your-telegram-user-id> \
  -v mybot-data:/data \
  claude-telegram-docker

# login Claude (1 lần) — setup-token IN RA token, KHÔNG tự lưu creds:
docker exec -it mybot claude setup-token
#   → mở URL in ra, authorize, paste FULL code; nó in ra token sống-lâu (1 năm).
# Nhét token vào env rồi RECREATE (restart KHÔNG nạp lại env → vẫn loggedIn:false):
#   thêm  CLAUDE_CODE_OAUTH_TOKEN=<token-vừa-in>  vào .env, rồi:
docker compose up -d
docker exec mybot claude auth status   # loggedIn:true là xong

# thêm 1 nhóm
docker exec mybot tg-access group add <group-id>

# xem access
docker exec mybot tg-access status
```

> Fallback nếu paste-code không chạy được: thêm `-e ANTHROPIC_API_KEY=***` lúc `docker run`, bỏ bước `claude /login`.

compose: `docker compose up -d` với file có sẵn env/volume/tty.

---

## 12. Bảo mật (checklist)

- Secrets chỉ runtime (env / docker secret), **không bake vào image**, không commit `.env`.
- `OWNER_ID` preseed + `allowlist` → bot owner-only ngay từ boot.
- Access mutation chỉ qua `docker exec` (host), **không qua tin Telegram**.
- 1 API key/bot nếu muốn tách billing + giảm bán kính rủi ro khi lộ.
- Container chạy non-root + read-only rootfs (nếu khả thi) + chỉ `/data` ghi được.
- `AUTO_PAIR` mặc định OFF; bật phải hiểu rủi ro.
- Plugin/CLI version PIN để build tái lập (reproducible).

---

## 13. Quyết định (Edward chốt 2026-06-26)

1. **Auth:** ✅ **Login paste-code qua `docker exec` (primary)**, xài subscription Claude; `ANTHROPIC_API_KEY` = fallback. Creds persist trên volume. (§5)
2. **Base image:** ✅ **`node:22-slim` + cài bun** (bun bắt buộc vì plugin telegram chạy server bằng bun).
3. **Pairing:** ✅ **Preseed-owner only**, KHÔNG `AUTO_PAIR` ở v1.
4. **Phân phối:** ✅ **Build local test trước**, ổn thì lên **GHCR** (CI defer).
5. **Tên image:** ✅ **`claude-telegram-docker`**.
6. **Owner:** ✅ **1 owner** (`OWNER_ID` đơn, không list).

---

## 14. Rủi ro & thứ tự làm (POC)

1. **§7 bake plugin** (rủi ro cao nhất) → POC chứng minh trước.
2. **§6 PTY + auth** → claude --channels sống được trong container, nhận được tin test.
3. **§8 entrypoint seed + tg-access** → owner-only chạy ngay, exec thêm id được.
4. Ráp Dockerfile + compose + README.
5. (Tuỳ chọn) push GHCR + CI build.

> Khi xác minh bất kỳ hành vi nào của Claude CLI / plugin mà chưa chắc → kiểm thực tế ở POC, không phỏng đoán đưa vào tài liệu.
