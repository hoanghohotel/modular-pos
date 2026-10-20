-- MIGRATION 0001: EXTENSIONS, DOMAIN ENUMS & AUDIT/VERSION TRIGGER UTILITIES (Giai đoạn 2)
BEGIN;
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "plpgsql";

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'entity_lifecycle_status') THEN
        CREATE TYPE public.entity_lifecycle_status AS ENUM ('ACTIVE', 'INACTIVE', 'SUSPENDED', 'ARCHIVED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'membership_status') THEN
        CREATE TYPE public.membership_status AS ENUM ('INVITED', 'ACTIVE', 'SUSPENDED', 'REVOKED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'membership_scope_type') THEN
        CREATE TYPE public.membership_scope_type AS ENUM ('ORG_WIDE', 'STORE_SPECIFIC');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'module_activation_status') THEN
        CREATE TYPE public.module_activation_status AS ENUM ('ENABLED', 'DRAINING', 'DISABLED');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'device_platform_type') THEN
        CREATE TYPE public.device_platform_type AS ENUM ('WEB_POS', 'WEB_ADMIN', 'ANDROID_POS', 'IOS_POS', 'KDS_DISPLAY', 'PRINT_BRIDGE');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'audit_severity_level') THEN
        CREATE TYPE public.audit_severity_level AS ENUM ('INFO', 'WARNING', 'CRITICAL');
    END IF;
END $$;

CREATE OR REPLACE FUNCTION public.tg_touch_updated_at_and_version()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    IF TG_OP = 'UPDATE' AND NEW.version IS NOT DISTINCT FROM OLD.version THEN
        NEW.version := OLD.version + 1;
    END IF;
    RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION public.tg_enforce_append_only_ledger()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABLE_LEDGER_VIOLATION: Bảng % là sổ cái bất biến, nghiêm cấm thao tác % trực tiếp.', TG_TABLE_NAME, TG_OP USING ERRCODE = '42501';
END; $$;
COMMIT;
