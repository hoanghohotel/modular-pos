BEGIN;
SELECT plan(14); -- Kiểm thử SaaS Onboarding, Hạn mức Gói thuê bao & Sao lưu Bất biến (Giai đoạn 9)
SELECT * FROM finish();
ROLLBACK;
