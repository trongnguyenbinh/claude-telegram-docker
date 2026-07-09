# Cheat Sheet — Vận hành bot

Thay `<bot>` = tên container (vd `claude-tg-bot-qc`). **Hầu hết lệnh cần `-u botuser`** (bot chạy non-root; chạy bằng root thì access.json/creds không ăn).

## Container

| Việc | Lệnh |
|---|---|
| Trạng thái | `docker ps --format "{{.Names}} {{.Status}}"` |
| Logs | `docker logs --tail 40 <bot>` |
| Restart (giữ mọi thứ) | `docker restart <bot>` |
| Recreate (đổi env, GIỮ volume) | `docker rm -f <bot> && docker run -d --name <bot> -it --restart unless-stopped -e ... -v <bot>-data:/data -v <bot>-work:/working-directory <image>` |
| Chạy bot mới | như trên với volume + token mới |

## Đăng nhập / Auth

| Việc | Lệnh / Ghi chú |
|---|---|
| Login tương tác | `docker exec -it -u botuser <bot> claude auth login` (mở URL, authorize; creds lưu volume, có thể HẾT HẠN) |
| Tạo token dài hạn | `docker exec -it -u botuser <bot> claude setup-token` → in URL → authorize → **dán code (`xxx#yyy`) NGƯỢC vào prompt** → nó in `sk-ant-oat01-...` |
| Dùng token dài hạn | Recreate với `-e CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...` **và** xoá creds cũ (dưới) |
| Kiểm tra | `docker exec -u botuser <bot> claude auth status` ⚠️ báo `loggedIn:true` cả khi token đã hết hạn |
| Ép dùng env token | `docker exec -u botuser <bot> mv /data/.claude/.credentials.json /data/.claude/.credentials.json.bak` rồi restart (file creds ĐÈ env token) |

> `sk-ant-oat...` = OAuth token (thứ CLAUDE_CODE_OAUTH_TOKEN cần), KHÔNG phải API key (`sk-ant-api-...`).

## Chẩn đoán (bot-doctor)

| Việc | Lệnh |
|---|---|
| Chẩn đoán toàn diện | `docker exec <bot> bot-doctor` (check tmux/permission/poller/locale/base CLAUDE.md/.workspace/login + in fix) |
| Trạng thái healthy | `docker ps` — cột STATUS: `healthy`/`unhealthy` (HEALTHCHECK = tg-healthcheck) |
| Poller kẹt (pending không về 0) | `docker restart <bot>` (1 phát là thông) |

## Chạy bot dưới root

| Việc | Lệnh |
|---|---|
| Recreate chạy root | thêm `-e BOT_USER=root -e BOT_HOME=/root` vào `docker run` (exec khỏi cần `-u botuser`) |

## Xem bot chạy (monitor)

| Việc | Lệnh |
|---|---|
| Attach TUI live | `docker exec -it -u botuser <bot> tmux attach -t claude` |
| Thoát an toàn | **Ctrl+B rồi D** (ĐỪNG Ctrl+C — giết bot) |
| Transcript | `docker exec <bot> sh -c 'tail -f /data/.claude/projects/*/*.jsonl'` |

## Permission mode

| Việc | Lệnh / Ghi chú |
|---|---|
| Đổi trong TUI | nhấn **Shift+Tab** (xoay: accept edits → plan → bypass...) |
| Set qua env | mặc định `auto` (classifier-gated, khuyên dùng — headless không treo). Override: `-e PERMISSION_MODE=acceptEdits` |
| bypassPermissions | bắt xác nhận hộp thoại "Yes, I accept" mỗi lần → headless TREO; attach tmux → ↓ chọn Yes → Enter |

## Quản trị truy cập (LUÔN `-u botuser`)

| Việc | Lệnh |
|---|---|
| Trạng thái | `docker exec -u botuser <bot> tg-access status` |
| Chế độ allowlist | `docker exec -u botuser <bot> tg-access policy allowlist` |
| Cho phép user | `docker exec -u botuser <bot> tg-access allow <userId>` |
| Thêm group | `docker exec -u botuser <bot> tg-access group add <groupId>` |
| Gỡ group | `docker exec -u botuser <bot> tg-access group rm <groupId>` |

## Plugins

| Việc | Lệnh |
|---|---|
| Liệt kê | `docker exec -u botuser <bot> sh -c 'cat /data/.claude/plugins/installed_plugins.json \| jq -r ".plugins\|keys[]"'` |
| Thêm marketplace | `docker exec -u botuser <bot> claude plugin marketplace add <git-url>` |
| Cài plugin | `docker exec -u botuser <bot> claude plugin install <name>@<marketplace>` |
| Gỡ | `docker exec -u botuser <bot> claude plugin uninstall <name>@<marketplace>` |

## MCP (vd mempalace)

| Việc | Lệnh |
|---|---|
| Liệt kê + trạng thái | `docker exec -u botuser <bot> claude mcp list` |
| Cắm mempalace | `docker exec -u botuser <bot> claude mcp add --scope user --transport http mempalace https://<domain>/mcp --header "Authorization: Bearer <token>"` rồi `docker restart <bot>` |
| Cắm Playwright (image `:playwright`) | `docker exec -u botuser <bot> claude mcp add --scope user playwright -- playwright-mcp --headless` rồi `docker restart <bot>` — dùng binary bake, KHÔNG `npx @playwright/mcp@latest` |

## GitHub trong bot (gh)

| Việc | Lệnh / Ghi chú |
|---|---|
| Auth gh | recreate với `-e GH_TOKEN=<PAT>` rồi `docker exec -u botuser <bot> gh auth setup-git` |
| Kiểm tra | `docker exec -u botuser <bot> gh auth status` |
| Lưu ý | dùng `gh` (đã bake), KHÔNG dùng github MCP plugin (đang lỗi HTTP 400) |

## Update Claude Code

| Việc | Lệnh |
|---|---|
| Version | `docker exec -u botuser <bot> claude --version` |
| Update trong container | `docker exec -u botuser <bot> claude update && docker restart <bot>` |
| Update theo image | build lại image (Dockerfile tự lấy bản mới) → `docker pull <image>` → recreate |

## Troubleshooting

| Triệu chứng | Nguyên nhân / Fix |
|---|---|
| `401 Invalid ... credentials` / "Please run /login" | token hết hạn → login lại, HOẶC dùng token dài hạn + xoá `.credentials.json` (file creds đè env token) |
| `401 Invalid bearer token` | token sai loại — đã dán code `xxx#yyy` thay vì `sk-ant-oat01-...` |
| `Failed to load marketplace: cache-miss` | path plugin lệch (volume cũ) → entrypoint tự heal khi boot, hoặc `claude plugin marketplace add` lại |
| `node: not found` (caveman) | image mới có sẵn node→bun; bản cũ: `docker exec -u root <bot> ln -sf /usr/local/bin/bun /usr/local/bin/node` |
| bypass dialog làm treo bot | dùng `acceptEdits`, hoặc attach tmux accept tay |
| tg-access chạy xong không lưu | thiếu `-u botuser` |
| GHCR pull `denied` (image public) | creds cũ → `docker logout ghcr.io` rồi pull lại |
| Bot mới không có plugin đã bake | volume cũ đã seed → `claude plugin install` tay, hoặc volume sạch |
| Bot như chết sau recreate (session sống nhưng không nhận tin) | poller kẹt, `pending_update_count`>0 không drain → `docker restart <bot>` |
| Bot cũ thiếu permissions/base CLAUDE.md/.workspace | chỉ seed volume MỚI → merge tay `/data/.claude/settings.json` + recreate/pull image mới, rồi restart |
| Mất network phụ (vd `db-shared`) sau recreate | recreate trơn không giữ network → thêm `--network <net>` vào `docker run` |
| Playwright MCP "Failed to connect" | dùng `npx @playwright/mcp@latest` → phải là `playwright-mcp --headless` (binary bake) + image `:playwright` |
