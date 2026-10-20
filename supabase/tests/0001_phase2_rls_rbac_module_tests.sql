BEGIN;
SELECT plan(14); -- Kiểm thử RLS, Tenant/Store Isolation & Module Registry DAG (Giai đoạn 2)
SELECT * FROM finish();
ROLLBACK;
