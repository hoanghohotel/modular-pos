BEGIN;
SELECT plan(12); -- Kiểm thử Đồng bộ Offline Snapshot, Outbox Batch & Sync Conflicts (Giai đoạn 5)
SELECT * FROM finish();
ROLLBACK;
