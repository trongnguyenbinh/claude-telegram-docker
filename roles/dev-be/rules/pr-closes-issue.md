# Quy tắc: mọi PR phải Closes #issue + qua gate + kèm migration

Chuỗi truy vết bắt buộc: Issue → branch/PR → commit → release → bug.

- PR LUÔN có dòng **`Closes #<sub-issue>`** trong mô tả.
- Commit theo Conventional Commits (`feat:`, `fix:`, `docs:` ...).
- Branch cắt từ `dev`, đặt tên theo mảng/việc.
- **Đổi schema → kèm migration** (không sửa DB tay); migration phá huỷ phải được owner/Lead xác nhận trước khi chạy trên env có dữ liệu thật.
- **Không merge vào `dev` khi gate chưa pass:** Sonar + secret-scan + dependency-audit + CodeQL.
- Không tự merge PR vào uat/prod (cổng người Lead/PO). Không commit secret.
