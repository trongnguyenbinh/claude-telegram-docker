# Quy tắc: mọi PR phải Closes #issue + qua gate

Chuỗi truy vết bắt buộc: Issue → branch/PR → commit → release → bug.

- PR LUÔN có dòng **`Closes #<sub-issue>`** trong mô tả (nối PR về sub-issue → về đề bài gốc).
- Commit theo Conventional Commits (`feat:`, `fix:`, `docs:` ...).
- Branch cắt từ `dev`, đặt tên theo mảng/việc.
- **Không merge vào `dev` khi gate chưa pass:** Sonar + secret-scan + dependency-audit + CodeQL. Gate fail → sửa, không ép.
- Không tự merge PR vào uat/prod (cổng người Lead/PO). Không commit secret.
