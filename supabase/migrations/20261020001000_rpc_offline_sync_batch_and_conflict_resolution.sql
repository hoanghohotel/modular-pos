-- ============================================================================
-- MIGRATION 0010: CÁC TRANSACTIONAL RPCs ĐỒNG BỘ LÔ OFFLINE-FIRST
-- (RPC_PULL_STORE_OFFLINE_SNAPSHOT, RPC_PROCESS_SYNC_BATCH, RPC_RESOLVE_SYNC_CONFLICT)
-- & VIEW CHẨN ĐOÁN ĐỒNG BỘ THIẾT BỊ (V_STORE_SYNC_DIAGNOSTICS_SUMMARY)
-- Giai đoạn 5: Kiến trúc Offline-first — Hệ thống Modular POS
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW public.v_store_sync_diagnostics_summary AS
SELECT
    d.organization_id,
    d.store_id,
    s.code AS store_code,
    s.name AS store_name,
    d.id AS device_id,
    d.device_code,
    d.device_name,
    d.platform,
    d.is_authorized,
    d.status AS device_status,
    d.last_seen_at,
    d.last_sync_at,
    COALESCE(w.pending_outbox_count, 0) AS pending_outbox_count,
    COALESCE(w.failed_outbox_count, 0) AS failed_outbox_count,
    COALESCE(w.conflict_outbox_count, 0) AS conflict_outbox_count,
    w.last_pulled_at,
    w.last_pushed_at,
    w.last_acknowledged_operation_id,
    (
        SELECT count(*)::INT
        FROM public.sync_conflicts sc
        WHERE sc.store_id = d.store_id
          AND sc.device_id = d.id
          AND sc.resolution_status = 'PENDING'
    ) AS unresolved_conflicts_count
FROM public.devices d
JOIN public.stores s ON s.id = d.store_id
LEFT JOIN public.device_sync_watermarks w ON w.device_id = d.id;

CREATE OR REPLACE FUNCTION public.rpc_pull_store_offline_snapshot(
    p_org_id UUID,
    p_store_id UUID,
    p_device_id UUID,
    p_since_timestamp TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_device RECORD;
    v_store RECORD;
    v_pos_config JSONB;
BEGIN
    IF NOT public.has_store_access(p_org_id, p_store_id) THEN
        RAISE EXCEPTION 'STORE_ACCESS_DENIED: Nhân viên không có quyền đồng bộ dữ liệu của chi nhánh này.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_device
    FROM public.devices
    WHERE id = p_device_id
      AND organization_id = p_org_id
      AND store_id = p_store_id;

    IF NOT FOUND OR v_device.status <> 'ACTIVE' OR v_device.is_authorized IS NOT TRUE THEN
        RAISE EXCEPTION 'DEVICE_UNAUTHORIZED: Thiết bị chưa được phê duyệt để tải dữ liệu offline.'
            USING ERRCODE = '42501';
    END IF;

    SELECT id, code, name, address, phone, currency_code, timezone
    INTO v_store
    FROM public.stores
    WHERE id = p_store_id AND organization_id = p_org_id;

    v_pos_config := public.resolve_effective_config(p_org_id, p_store_id, p_device_id, 'sync_engine')
        || public.resolve_effective_config(p_org_id, p_store_id, p_device_id, 'pos');

    INSERT INTO public.device_sync_watermarks (
        organization_id, store_id, device_id, last_pulled_at
    ) VALUES (
        p_org_id, p_store_id, p_device_id, now()
    )
    ON CONFLICT (device_id) DO UPDATE SET
        last_pulled_at = now();

    UPDATE public.devices
    SET last_sync_at = now(), last_seen_at = now()
    WHERE id = p_device_id;

    RETURN jsonb_build_object(
        'pulled_at', now(),
        'store', row_to_json(v_store),
        'pos_config', v_pos_config
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_process_sync_batch(
    p_org_id UUID,
    p_store_id UUID,
    p_device_id UUID,
    p_operations JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_device RECORD;
    v_op JSONB;
    v_op_id UUID;
    v_op_type VARCHAR(64);
    v_entity_type VARCHAR(64);
    v_entity_id UUID;
    v_base_version INTEGER;
    v_payload JSONB;
    v_existing_idem JSONB;
    v_results JSONB := '[]'::JSONB;
    v_single_res JSONB;
    v_existing_order RECORD;
    v_conflict_id UUID;
BEGIN
    IF NOT public.has_store_access(p_org_id, p_store_id) THEN
        RAISE EXCEPTION 'STORE_ACCESS_DENIED: Bạn không có quyền đẩy dữ liệu đồng bộ vào chi nhánh này.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_device
    FROM public.devices
    WHERE id = p_device_id
      AND organization_id = p_org_id
      AND store_id = p_store_id;

    IF NOT FOUND OR v_device.status <> 'ACTIVE' OR v_device.is_authorized IS NOT TRUE THEN
        RAISE EXCEPTION 'DEVICE_UNAUTHORIZED: Thiết bị (%) chưa được phê duyệt để đồng bộ.', p_device_id
            USING ERRCODE = '42501';
    END IF;

    FOR v_op IN SELECT * FROM jsonb_array_elements(p_operations) LOOP
        v_op_id := (v_op ->> 'operation_id')::UUID;
        v_op_type := v_op ->> 'operation_type';
        v_entity_type := COALESCE(v_op ->> 'entity_type', 'order');
        v_entity_id := (v_op ->> 'entity_id')::UUID;
        v_base_version := COALESCE((v_op ->> 'base_version')::INTEGER, 0);
        v_payload := COALESCE(v_op -> 'payload', '{}'::JSONB);

        SELECT response_payload INTO v_existing_idem
        FROM public.idempotency_keys
        WHERE operation_id = v_op_id;

        IF FOUND THEN
            v_results := v_results || jsonb_build_array(
                v_existing_idem || jsonb_build_object('idempotent_replay', TRUE)
            );
            CONTINUE;
        END IF;

        SELECT * INTO v_existing_order
        FROM public.orders
        WHERE id = v_entity_id AND store_id = p_store_id
        FOR UPDATE;

        IF FOUND AND v_existing_order.order_status IN ('COMPLETED', 'CANCELLED', 'MERGED_CLOSED') THEN
            INSERT INTO public.sync_conflicts (
                organization_id, store_id, device_id, operation_id, actor_user_id,
                entity_type, entity_id, operation_type, conflict_type,
                client_base_version, server_current_version,
                client_payload, server_state_snapshot, conflict_reason
            ) VALUES (
                p_org_id, p_store_id, p_device_id, v_op_id, public.current_actor_id(),
                v_entity_type, v_entity_id, v_op_type, 'ORDER_ALREADY_FINALIZED',
                v_base_version, v_existing_order.revision,
                v_payload, row_to_json(v_existing_order)::JSONB,
                'Đơn hàng đã chốt trên server, không áp dụng last-write-wins mù quáng.'
            )
            RETURNING id INTO v_conflict_id;

            v_single_res := jsonb_build_object(
                'operation_id', v_op_id,
                'entity_id', v_entity_id,
                'sync_status', 'CONFLICT',
                'error_category', 'VERSION_CONFLICT',
                'error_code', 'ORDER_ALREADY_FINALIZED',
                'conflict_id', v_conflict_id,
                'server_acknowledged_at', now()
            );
        ELSE
            v_single_res := jsonb_build_object(
                'operation_id', v_op_id,
                'entity_id', v_entity_id,
                'sync_status', 'ACKNOWLEDGED',
                'server_acknowledged_at', now()
            );
        END IF;

        INSERT INTO public.idempotency_keys (
            operation_id, organization_id, store_id, device_id, actor_user_id,
            operation_type, entity_type, entity_id, response_status, response_payload
        ) VALUES (
            v_op_id, p_org_id, p_store_id, p_device_id, public.current_actor_id(),
            v_op_type, v_entity_type, v_entity_id, v_single_res ->> 'sync_status', v_single_res
        );

        v_results := v_results || jsonb_build_array(v_single_res);
    END LOOP;

    INSERT INTO public.device_sync_watermarks (
        organization_id, store_id, device_id, last_pushed_at, last_acknowledged_operation_id
    ) VALUES (
        p_org_id, p_store_id, p_device_id, now(), v_op_id
    )
    ON CONFLICT (device_id) DO UPDATE SET
        last_pushed_at = now(),
        last_acknowledged_operation_id = COALESCE(v_op_id, public.device_sync_watermarks.last_acknowledged_operation_id);

    RETURN jsonb_build_object(
        'processed_at', now(),
        'device_id', p_device_id,
        'results', v_results
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.rpc_resolve_sync_conflict(
    p_org_id UUID,
    p_store_id UUID,
    p_conflict_id UUID,
    p_resolution_status public.sync_conflict_resolution_status,
    p_resolution_notes TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_conflict RECORD;
BEGIN
    IF NOT public.authorize_action(p_org_id, p_store_id, 'store.config.manage', 'stores') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: Chỉ Quản lý Cửa hàng hoặc Chủ sở hữu mới có quyền giải quyết xung đột đồng bộ.'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_conflict
    FROM public.sync_conflicts
    WHERE id = p_conflict_id AND organization_id = p_org_id AND store_id = p_store_id
    FOR UPDATE;

    UPDATE public.sync_conflicts
    SET resolution_status = p_resolution_status,
        resolution_notes = p_resolution_notes,
        resolved_by = public.current_actor_id(),
        resolved_at = now()
    WHERE id = p_conflict_id;

    RETURN jsonb_build_object(
        'conflict_id', p_conflict_id,
        'resolution_status', p_resolution_status,
        'resolved_at', now()
    );
END;
$$;

COMMIT;
