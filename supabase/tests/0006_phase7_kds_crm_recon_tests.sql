BEGIN;
SELECT plan(15); -- Kiểm thử KDS, Loyalty, Chi phí Quầy & Đối soát Ship COD/VietQR (Giai đoạn 7)
SELECT * FROM finish();
ROLLBACK;
