# Role profiles — bot chuyên trách

Mỗi con bot `claude-telegram-docker` có thể khởi động ở một **vai trò chuyên trách** qua biến môi trường `BOT_ROLE`. Vai trò xuất phát từ quy trình delivery bằng AI agent (Define/BA → Planning → Build → Tester/QA), nơi **1 vai trò = 1 bot**.

## Vai trò có sẵn

| `BOT_ROLE` | Giai đoạn | Bot làm gì |
|---|---|---|
| `ba` | 1 · Define | Business Analyst: phân tích đề bài, viết acceptance criteria + tài liệu, dựng prototype UI → deploy Vercel preview; PO/BA accept → tạo GitHub Issue (Issue Form) + sync mempalace + publish handoff kênh chung. |
| `planner` | 2 · Planning | Phân rã issue cha → sub-issue theo mảng (`area:frontend/backend/db/infra/qa`) + mô tả + estimate + link issue cha → Projects board → publish + @mention đúng người. |
| `dev-fe` | 3 · Build (FE) | Nhặt sub-issue `area:frontend` → branch → code UI (Angular/React) → PR `Closes #issue`; biết gate Sonar + security; frontend-design + Vercel + Playwright. |
| `dev-be` | 3 · Build (BE) | Nhặt sub-issue `area:backend` → branch → code API/DB (Spring, migration) → PR `Closes #issue`; ý thức migration/db + gate. |
| `tester` | 5 · Tester/QA | Từ release note hướng dẫn test + tạo file testcase; nhận log-issue web UAT (URL + mô tả + screenshot) → đối chiếu đặc tả + mempalace → nghi bug thật thì publish channel + tag Lead. |

Không đặt `BOT_ROLE` (hoặc để trống / `default`) = **hành vi mặc định như cũ, KHÔNG đổi gì.**

## Cách dùng

```bash
docker run -d --name thedots-ba \
  -e TELEGRAM_BOT_TOKEN=<token> -e OWNER_ID=<id> \
  -e BOT_ROLE=ba \
  -v thedots-ba-data:/data \
  --restart unless-stopped \
  ghcr.io/trongnguyenbinh/claude-telegram-docker:latest
```

## Cơ chế hoạt động (seed lần chạy đầu, idempotent)

Ở `entrypoint.sh`, nếu `BOT_ROLE` được đặt, khác rỗng và khác `default`, và thư mục `roles/$BOT_ROLE/` có trong image (`/usr/local/share/claude-telegram/roles/`):

1. **`CLAUDE.md`** của vai trò được seed thành **CLAUDE.md work-dir của bot** (`$WORK_DIR/CLAUDE.md`) — **chỉ khi file đó chưa tồn tại** (không đè CLAUDE.md riêng của bot). Nó **layer chồng lên** base CLAUDE.md đã bake (bảo mật + cách ly + `.workspace` + giọng trả lời vẫn là nền chung).
2. **`settings-fragment.json`** được jq-merge vào `settings.json` của bot: **union** `enabledPlugins` + `permissions.allow` (không đè cái sẵn có, không tắt plugin nền).
3. Các file trong **`rules/`** (nếu có) được seed vào `.workspace/rules/` (bỏ qua file đã tồn tại).

Đặt `BOT_ROLE` không hợp lệ (không có thư mục tương ứng) → entrypoint LOG cảnh báo rồi chạy như mặc định, không lỗi.

> Lưu ý: `CLAUDE.md` chỉ seed khi work-dir chưa có CLAUDE.md. Đổi `BOT_ROLE` trên một bot đã chạy (đã có work-dir CLAUDE.md) sẽ **không** tự thay CLAUDE.md — muốn đổi role của bot cũ thì xoá/đổi tên `$WORK_DIR/CLAUDE.md` rồi restart, hoặc dùng volume sạch. (Phần `settings-fragment` là union nên chạy lại vô hại.)

## Thêm một vai trò mới

1. Tạo thư mục `roles/<role>/` với:
   - `CLAUDE.md` — quy tắc "cách làm việc" của vai trò (tiếng Việt, không em-dash, layer trên base). Tham chiếu giai đoạn quy trình + chuỗi truy vết (`Closes #x`) + DoR/DoD nếu hợp.
   - `settings-fragment.json` — JSON hợp lệ, tối thiểu: `enabledPlugins` bổ sung + `permissions.allow` bổ sung. Không tắt plugin nền. (Có thể để `_note` mô tả.)
   - (tuỳ chọn) `rules/*.md` — 1-2 quy tắc hành vi seed vào `.workspace/rules/`.
2. Không cần sửa `entrypoint.sh` — nó đọc động theo `$BOT_ROLE`. Chỉ cần `COPY roles/` trong Dockerfile (đã có).
3. `jq . roles/<role>/settings-fragment.json` phải parse được. `bash -n entrypoint.sh` phải sạch.
4. Cập nhật bảng vai trò ở trên + README chính + CHEATSHEET.
