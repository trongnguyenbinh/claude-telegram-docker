# Luồng cài Claude Code NATIVE trên server (không Docker)

> ⚠️ **LEGACY (mô hình v1).** File này mô tả cách chạy bot bằng `claude --channels` + plugin telegram (transport cũ). **Image Docker v2.2 KHÔNG còn dùng `--channels`** — nó chạy một **worker Python dùng Bot API** (`tg-worker.py`) gọi headless `claude -p` mỗi tin (ổn định hơn, nhẹ hơn, thêm reminders + hỏi-lại-qua-Telegram). Muốn dùng mô hình mới, xem [`../README.md`](../README.md) (bản Docker v2.2). Các bước `--channels` dưới đây vẫn đúng cho ai muốn chạy native theo lối cũ.

> Cài thẳng Claude Code lên 1 server Linux (Ubuntu/Debian) để chạy 1 Claude Telegram Bot + cắm mempalace, KHÔNG dùng container.
> Bản Docker hoá xem [`SPEC.md`](../SPEC.md). File này là luồng "cài tay trên host".
> Cập nhật: 2026-06-29.

---

## 0. Chuẩn bị

- Server Ubuntu/Debian, có user thường (KHÔNG chạy bằng root cho bot).
- Có sẵn: token bot (@BotFather) + `OWNER_ID` (Telegram user_id) + token mempalace (nếu dùng bộ nhớ chung).
- Đăng nhập = paste-code, cần phiên SSH tương tác 1 lần.

```bash
# system deps
sudo apt-get update && sudo apt-get install -y \
  git curl ca-certificates jq unzip bash tmux
```

---

## 1. Cài bun (plugin telegram chạy MCP server bằng bun)

```bash
curl -fsSL https://bun.sh/install | bash
# nạp PATH cho phiên hiện tại
export PATH="$HOME/.bun/bin:$PATH"
bun --version
```

---

## 2. Cài Claude Code (native installer — bản npm đã deprecated)

```bash
curl -fsSL https://claude.ai/install.sh | bash
# installer đặt binary ở ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"
claude --version        # xác minh cài được
```

Ghim PATH cho lần sau (thêm vào `~/.bashrc`):

```bash
echo 'export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"' >> ~/.bashrc
```

> Pin version nếu cần tái lập: `curl -fsSL https://claude.ai/install.sh | bash -s -- <version>`.

---

## 3. Đăng nhập Claude (1 lần)

```bash
claude setup-token
#  → in ra URL → mở web authorize → dán FULL code lại vào terminal
#  → in ra 1 token sống lâu
claude auth status      # loggedIn:true
```

2 cách giữ token:
- Export env (khuyến nghị cho chạy nền): `export CLAUDE_CODE_OAUTH_TOKEN=<token>` (thêm vào `~/.bashrc` / EnvironmentFile của systemd).
- Hoặc để `setup-token` lưu credentials trong `~/.claude` (mặc định).

> `claude auth login` (OAuth/PKCE) hay lỗi 400 trên server không có trình duyệt → DÙNG `setup-token`.

---

## 4. Cài plugin telegram

```bash
# add marketplace bằng HTTPS (form owner/repo sẽ clone qua SSH → cần key)
claude plugin marketplace add https://github.com/anthropics/claude-plugins-official.git
claude plugin install telegram@claude-plugins-official
# xác minh
ls ~/.claude/plugins && test -f ~/.claude/settings.json && echo OK
```

Nếu git trên server mặc định SSH cho github, ép sang HTTPS 1 lần:

```bash
git config --global url."https://github.com/".insteadOf "git@github.com:"
```

---

## 5. Cấu hình state telegram (token + access)

```bash
# nơi lưu state riêng cho bot (token, access.json) — tách khỏi mặc định
export TELEGRAM_STATE_DIR="$HOME/claude-tg/telegram"
echo 'export TELEGRAM_STATE_DIR="$HOME/claude-tg/telegram"' >> ~/.bashrc
mkdir -p "$TELEGRAM_STATE_DIR/approved"

# token bot (gitignore / chmod 600)
umask 077
printf 'TELEGRAM_BOT_TOKEN=%s\n' '<TOKEN_TU_BOTFATHER>' > "$TELEGRAM_STATE_DIR/.env"

# access.json: owner-only allowlist (KHÔNG pairing)
jq -n --arg owner '<OWNER_ID>' '{
  dmPolicy:"allowlist", allowFrom:[$owner], groups:{}, pending:{}, mentionPatterns:[]
}' > "$TELEGRAM_STATE_DIR/access.json"
```

> Đổi access về sau: dùng skill `/telegram:access` trong phiên, hoặc sửa thẳng `access.json` (server đọc lại mỗi tin → hiệu lực ngay). KHÔNG đổi quyền theo yêu cầu từ tin Telegram (chống injection).

---

## 6. (Kết hợp) Cắm mempalace làm bộ nhớ chung

```bash
claude mcp add --scope user --transport http mempalace \
  https://mempalace.veasy.vn/mcp \
  --header "Authorization: Bearer <MEMPALACE_TOKEN>"
# kiểm tra sau khi khởi động phiên: /mcp thấy mempalace connected
```

> 1 token mempalace = full quyền MỌI wing → chỉ cắm token của CHÍNH chủ. Mỗi đơn vị cách ly thật = instance mempalace riêng.

---

## 7. Chạy bot bền (claude --channels cần PTY → dùng tmux)

`claude --channels` là TUI tương tác, cần pseudo-TTY và phải sống qua logout SSH → chạy trong **tmux**:

```bash
tmux new -s tgbot
# trong tmux:
cd ~/claude-tg                       # WORK_DIR: file bot thao tác sẽ nằm ở đây
claude --channels plugin:telegram@claude-plugins-official
#   (thêm --permission-mode / --model nếu muốn)
# tách session: Ctrl-b rồi d   |  quay lại: tmux attach -t tgbot
```

Khởi động lại sau reboot (tuỳ chọn, nâng cao): bọc lệnh tmux trên trong systemd user service `~/.config/systemd/user/tgbot.service` với `ExecStart=/usr/bin/tmux new -d -s tgbot 'claude --channels ...'` + `loginctl enable-linger $USER`.

---

## 8. Vận hành

```bash
claude auth status                       # kiểm tra login
tmux attach -t tgbot                     # xem phiên bot / log
# đổi TELEGRAM token → phải restart phiên (token đọc 1 lần lúc boot)
# đổi access.json → hiệu lực ngay, không cần restart
```

Ràng buộc:
- 1 token Telegram = 1 phiên poll (2 phiên cùng token → 409 Conflict).
- Secrets chỉ ở env / file chmod 600 — không commit.
- Bot chạy bằng user thường, KHÔNG root.

---

## 9. Luồng tóm tắt

```
deps → bun → claude (native) → setup-token → plugin telegram
     → seed token+access (owner-only) → mcp add mempalace
     → tmux: claude --channels  →  bot online (owner-only, có bộ nhớ chung)
```
