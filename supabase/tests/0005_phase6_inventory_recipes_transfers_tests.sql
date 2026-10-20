BEGIN;
SELECT plan(14); -- Kiểm thử Trừ kho BOM, Giá vốn Moving Average & Chuyển kho In-Transit (Giai đoạn 6)
SELECT * FROM finish();
ROLLBACK;
