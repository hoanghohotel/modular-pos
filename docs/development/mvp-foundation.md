# Kiểm thử nền tảng MVP

## Thiết lập

1. Dùng Supabase local/staging riêng; không chạy `db reset` trên dữ liệu thật.
2. Chạy `supabase start`, `supabase db reset`, `supabase test db`.
3. Đặt URL và anon/publishable key công khai tương ứng vào `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` ở môi trường build.
4. Chạy `npm run build`, phục vụ thư mục `public`, mở `/account.html` (Vercel: `/account`).
5. Tạo tài khoản bằng email/mật khẩu; xác nhận email. Supabase local cung cấp hộp thư kiểm thử, URL hiển thị trong `supabase status`. Không dùng các email mẫu trong seed như tài khoản đăng nhập.
6. Đăng nhập, tạo thương hiệu và cửa hàng. Tải lại trang, đăng nhập lại: cửa hàng vẫn tồn tại.
7. Tạo tài khoản khác: không được thấy thương hiệu/cửa hàng của tài khoản trước.

## Giới hạn của đợt code

- Token chỉ giữ trong bộ nhớ, không lưu localStorage; tải lại phải đăng nhập. Chưa tự refresh token hay hỗ trợ đăng nhập offline.
- Email phải được xác nhận để tạo workspace. Đăng ký tự động cần cấu hình SMTP, redirect URL và chính sách Auth trên Supabase staging/production.
- Mỗi tài khoản tự tạo tối đa một workspace trong đợt này. Chưa có giao diện mời nhân viên, gán vai trò hoặc vận hành POS thật.
- Bảng core mở quyền đọc qua RLS; ghi trực tiếp từ client bị khóa. RPC bootstrap ghi dữ liệu atomically, không nhận actor/role từ client.
- RPC sync và view chẩn đoán cũ bị thu hồi quyền truy cập vì chưa đủ an toàn. Client cũ cần được thay bằng sync engine thật ở đợt sau.
- Migration mới giữ nguyên các migration cũ, dùng ràng buộc composite để chặn ghép tenant/store/device sai. Nếu dữ liệu cũ vi phạm, migration phải dừng để sửa dữ liệu; không bỏ constraint.
- Các file test pgTAP rỗng đã loại khỏi bộ test. Chưa triển khai KDS, in, kho/BOM.
- Trước khi mở production cần kiểm thử Supabase Auth end-to-end, email/SMTP, backup/restore và luồng bán hàng thật.

## Kiểm thử tự động

`npm test` chạy domain test cũ, Auth client và PostgreSQL/PGlite. Bộ database tạo hai tenant, kiểm tra đọc chéo, gán role chéo, thành viên chưa có quyền, quyền theo chi nhánh, khóa membership, chống tự nâng quyền, chặn sync chưa hoàn thiện và bootstrap.

CI còn dựng Supabase, reset database từ migrations nguyên bản và chạy assertion pgTAP. Kiểm thử này cần được theo dõi sau khi đẩy code.
