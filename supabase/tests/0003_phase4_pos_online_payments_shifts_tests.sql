BEGIN;
SELECT plan(15); -- Kiểm thử POS Online, Tạm tính VietQR động, Hoàn tiền & Chốt ca (Giai đoạn 4)
SELECT * FROM finish();
ROLLBACK;
