-- ============================================================================
-- MIGRATION 0007: BẢNG DẤU MỐC ĐỒNG BỘ THIẾT BỊ (DEVICE_SYNC_WATERMARKS),
-- BẢNG XUNG ĐỘT ĐỒNG BỘ (SYNC_CONFLICTS) & CHÍNH SÁCH ROW LEVEL SECURITY (RLS)
-- Giai đoạn 5: Kiến trúc Offline-first — Hệ thống Modular POS
-- (Các Transactional RPCs đồng bộ lô được định nghĩa tại Migration 0010)
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sync_conflict_type') THEN
        CREATE TYPE public.sync_conflict_type AS ENUM (
            'ORDER_ALREADY_FINALIZED',
            'ITEM_MODIFIED_AFTER_PAYMENT',
            'OVERPAYMENT_DUPLICATE',
            'SHIFT_ALREADY_CLOSED_CONFLICT',
            'PRICE_OUT_OF_BOUNDS_CONFLICT',
            'VERSION_MISMATCH_UNMERGEABLE'
        );
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'sync_conflict_resolution_status') THEN
        CREATE TYPE public.sync_conflict_resolution_status AS ENUM (
            'PENDING',
            'RESOLVED_KEEP_SERVER',
            'RESOLVED_APPLY_CLIENT',
            'RESOLVED_MERGED',
            'DISMISSED'
        );
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.device_sync_watermarks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE UNIQUE,
    last_pulled_at TIMESTAMPTZ NULL,
    last_pushed_at TIMESTAMPTZ NULL,
    last_acknowledged_operation_id UUID NULL,
    pending_outbox_count INTEGER NOT NULL DEFAULT 0 CHECK (pending_outbox_count >= 0),
    failed_outbox_count INTEGER NOT NULL DEFAULT 0 CHECK (failed_outbox_count >= 0),
    conflict_outbox_count INTEGER NOT NULL DEFAULT 0 CHECK (conflict_outbox_count >= 0),
    client_app_version VARCHAR(32) NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_device_sync_watermarks_store
ON public.device_sync_watermarks(organization_id, store_id, updated_at DESC);

CREATE TRIGGER trg_device_sync_watermarks_touch
BEFORE UPDATE ON public.device_sync_watermarks
FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at_and_version();

CREATE TABLE IF NOT EXISTS public.sync_conflicts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
    device_id UUID NOT NULL REFERENCES public.devices(id) ON DELETE RESTRICT,
    operation_id UUID NOT NULL UNIQUE,
    actor_user_id UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id UUID NOT NULL,
    operation_type VARCHAR(64) NOT NULL,
    conflict_type public.sync_conflict_type NOT NULL,
    client_base_version INTEGER NOT NULL DEFAULT 0,
    server_current_version INTEGER NOT NULL DEFAULT 1,
    client_payload JSONB NOT NULL,
    server_state_snapshot JSONB NOT NULL,
    conflict_reason TEXT NOT NULL,
    resolution_status public.sync_conflict_resolution_status NOT NULL DEFAULT 'PENDING',
    resolution_notes TEXT NULL,
    resolved_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    resolved_at TIMESTAMPTZ NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_store_status
ON public.sync_conflicts(organization_id, store_id, resolution_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_sync_conflicts_entity
ON public.sync_conflicts(store_id, entity_type, entity_id);

CREATE TRIGGER trg_sync_conflicts_touch
BEFORE UPDATE ON public.sync_conflicts
FOR EACH ROW EXECUTE FUNCTION public.tg_touch_updated_at_and_version();

ALTER TABLE public.device_sync_watermarks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_sync_watermarks FORCE ROW LEVEL SECURITY;

ALTER TABLE public.sync_conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_conflicts FORCE ROW LEVEL SECURITY;

CREATE POLICY pol_device_sync_watermarks_select ON public.device_sync_watermarks
    FOR SELECT USING (public.has_store_access(organization_id, store_id));

CREATE POLICY pol_sync_conflicts_select ON public.sync_conflicts
    FOR SELECT USING (public.has_store_access(organization_id, store_id));

COMMIT;
