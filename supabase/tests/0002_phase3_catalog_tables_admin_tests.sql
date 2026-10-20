BEGIN;
SELECT plan(12); -- Kiểm thử 20 Bàn + 10 Mang về + 10 Giao hàng & Bảng giá Chi nhánh (Giai đoạn 3)
SELECT * FROM finish();
ROLLBACK;
