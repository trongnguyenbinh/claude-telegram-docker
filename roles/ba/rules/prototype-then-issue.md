# Quy tắc: prototype trước, issue sau

Không tạo GitHub Issue đề bài khi PROTOTYPE chưa được PO/BA accept. Thứ tự bắt buộc:

1. Làm rõ đề bài + viết acceptance criteria.
2. Dựng prototype UI → deploy Vercel preview → gửi link cho PO/BA.
3. Chờ PO/BA accept rõ ràng (không tự suy diễn là đã duyệt).
4. Accept xong mới: tạo Issue (Issue Form) + commit spec `docs/` + sync mempalace + publish kênh chung.

Lý do: issue là gốc chuỗi truy vết; tạo sớm khi spec chưa chốt sẽ đẻ ra issue rác + sub-issue sai.
