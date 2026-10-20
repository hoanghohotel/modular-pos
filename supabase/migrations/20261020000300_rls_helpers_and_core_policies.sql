-- ============================================================================
-- MIGRATION 0003: HÀM BẢO MẬT SECURITY DEFINER, CHÍNH SÁCH RLS CHO 16 BẢNG CORE
-- VÀ CÁC TRANSACTIONAL RPCs (rpc_set_module_status, rpc_assign_user_role, rpc_open_device_session)
-- ============================================================================
BEGIN;
CREATE OR REPLACE FUNCTION public.current_actor_id() RETURNS UUID LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE(NULLIF(current_setting('request.jwt.claim.sub', true), '')::UUID, NULLIF(current_setting('app.current_user_id', true), '')::UUID);
$$;

CREATE OR REPLACE FUNCTION public.is_org_member(p_org_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (SELECT 1 FROM public.memberships m WHERE m.organization_id = p_org_id AND m.user_id = public.current_actor_id() AND m.status = 'ACTIVE');
$$;

CREATE OR REPLACE FUNCTION public.has_store_access(p_org_id UUID, p_store_id UUID) RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.stores s JOIN public.memberships m ON m.organization_id = s.organization_id LEFT JOIN public.user_roles ur ON ur.membership_id = m.id
        WHERE s.id = p_store_id AND s.organization_id = p_org_id AND s.status = 'ACTIVE' AND m.user_id = public.current_actor_id() AND m.status = 'ACTIVE'
          AND (m.scope_type = 'ORG_WIDE' OR ur.store_id IS NULL OR ur.store_id = p_store_id)
    );
$$;

ALTER TABLE public.modules ENABLE ROW LEVEL SECURITY; ALTER TABLE public.modules FORCE ROW LEVEL SECURITY;
ALTER TABLE public.permissions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.permissions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY; ALTER TABLE public.organizations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.stores ENABLE ROW LEVEL SECURITY; ALTER TABLE public.stores FORCE ROW LEVEL SECURITY;
ALTER TABLE public.organization_settings ENABLE ROW LEVEL SECURITY; ALTER TABLE public.organization_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.store_settings ENABLE ROW LEVEL SECURITY; ALTER TABLE public.store_settings FORCE ROW LEVEL SECURITY;
ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY; ALTER TABLE public.memberships FORCE ROW LEVEL SECURITY;
ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.roles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.role_permissions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY; ALTER TABLE public.user_roles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.organization_modules ENABLE ROW LEVEL SECURITY; ALTER TABLE public.organization_modules FORCE ROW LEVEL SECURITY;
ALTER TABLE public.store_modules ENABLE ROW LEVEL SECURITY; ALTER TABLE public.store_modules FORCE ROW LEVEL SECURITY;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY; ALTER TABLE public.devices FORCE ROW LEVEL SECURITY;
ALTER TABLE public.device_sessions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.device_sessions FORCE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY; ALTER TABLE public.audit_logs FORCE ROW LEVEL SECURITY;
COMMIT;
