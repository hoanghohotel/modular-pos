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
- Mỗi tài khoản tự tạo tối đa một workspace trong đợt này. Chưa có giao diện mời nhân viên/gán vai trò. Menu và lưu đơn online được triển khai trong đợt tiếp theo ở bên dưới.
- Bảng core mở quyền đọc qua RLS; ghi trực tiếp từ client bị khóa. RPC bootstrap ghi dữ liệu atomically, không nhận actor/role từ client.
- RPC sync và view chẩn đoán cũ bị thu hồi quyền truy cập vì chưa đủ an toàn. Client cũ cần được thay bằng sync engine thật ở đợt sau.
- Migration mới giữ nguyên các migration cũ, dùng ràng buộc composite để chặn ghép tenant/store/device sai. Nếu dữ liệu cũ vi phạm, migration phải dừng để sửa dữ liệu; không bỏ constraint.
- Các file test pgTAP rỗng đã loại khỏi bộ test. Chưa triển khai KDS, in, kho/BOM.
- Trước khi mở production cần kiểm thử Supabase Auth end-to-end, email/SMTP, backup/restore và luồng bán hàng thật.

## Kiểm thử tự động

`npm test` chạy domain test cũ, Auth client và PostgreSQL/PGlite. Bộ database tạo hai tenant, kiểm tra đọc chéo, gán role chéo, thành viên chưa có quyền, quyền theo chi nhánh, khóa membership, chống tự nâng quyền, chặn sync chưa hoàn thiện và bootstrap.

CI còn dựng Supabase, reset database từ migrations nguyên bản và chạy assertion pgTAP. Kiểm thử này cần được theo dõi sau khi đẩy code.

## Menu và đơn hàng online

Sau khi đăng nhập, chủ cửa hàng có thể mở phần Thực đơn & đơn hàng:

1. Thêm món, một hoặc nhiều size/giá, topping tùy chọn. Có thể chỉnh giá hoặc ngừng bán từng size.
2. Thêm bàn nếu phục vụ tại chỗ.
3. Chọn món, size, topping, số lượng; thêm vào giỏ và lưu đơn mang về/tại bàn/giao hàng. Giao hàng cần điện thoại và địa chỉ.
4. Mở lại đơn đã lưu. Server kiểm tra revision; nếu máy khác đã sửa, thao tác cũ bị từ chối.
5. Server tính giá từ catalog và lưu snapshot. Gửi lại nguyên yêu cầu với cùng operation ID không tạo đơn mới; tái sử dụng ID với nội dung khác bị từ chối.

Đợt này mới lưu **đơn đang mở, chưa thanh toán**. Chưa triển khai ca, thu tiền, hủy/hoàn tiền, gộp/tách, tự đồng bộ hai màn hình hay lưu giỏ offline. Giỏ chưa lưu sẽ mất khi tải lại trang. Danh sách hiển thị tối đa 200 đơn đang mở gần nhất. Giá được tính lại theo catalog khi lưu, kể cả sửa đơn.

RPC đọc/ghi bảo vệ bằng tenant/store + permission. Owner hiện có quyền quản lý; thành viên chỉ có quyền truy cập chi nhánh chưa tự động được phép bán hoặc sửa menu. Thay đổi món, giá và đơn được ghi audit. Các API sync cũ vẫn bị khóa.
