-- ============================================================================
-- MIGRATION 0002: 16 BẢNG NHÓM NỀN TẢNG (ORGANIZATIONS, STORES, RBAC, MODULES,
-- DEVICES, SETTINGS, AUDIT LOGS) — Giai đoạn 2: Core & Bảo mật
-- ============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS public.modules (
    module_key VARCHAR(64) PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    description TEXT NOT NULL,
    category VARCHAR(32) NOT NULL CHECK (category IN ('CORE', 'BUSINESS', 'SAAS')),
    module_version VARCHAR(32) NOT NULL DEFAULT '2.0.0',
    is_core BOOLEAN NOT NULL DEFAULT FALSE,
    default_status public.module_activation_status NOT NULL DEFAULT 'ENABLED',
    dependencies JSONB NOT NULL DEFAULT '[]'::JSONB,
    supported_platforms JSONB NOT NULL DEFAULT '["WEB_ADMIN", "WEB_POS", "ANDROID_POS", "IOS_POS"]'::JSONB,
    configuration_schema JSONB NOT NULL DEFAULT '{}'::JSONB,
    default_config JSONB NOT NULL DEFAULT '{}'::JSONB,
    migration_version VARCHAR(32) NOT NULL DEFAULT '20261020000200',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_modules_dependencies_is_array CHECK (jsonb_typeof(dependencies) = 'array'),
    CONSTRAINT chk_modules_core_always_enabled CHECK (NOT is_core OR default_status = 'ENABLED')
);

CREATE TABLE IF NOT EXISTS public.permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    permission_key VARCHAR(128) NOT NULL UNIQUE,
    module_key VARCHAR(64) NOT NULL REFERENCES public.modules(module_key) ON DELETE RESTRICT,
    name VARCHAR(150) NOT NULL,
    description TEXT NOT NULL,
    is_sensitive BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY,
    email VARCHAR(255) NOT NULL UNIQUE,
    full_name VARCHAR(150) NOT NULL,
    phone VARCHAR(32) NULL,
    avatar_url TEXT NULL,
    preferred_locale VARCHAR(16) NOT NULL DEFAULT 'vi-VN',
    status public.entity_lifecycle_status NOT NULL DEFAULT 'ACTIVE',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.organizations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code VARCHAR(32) NOT NULL UNIQUE,
    slug VARCHAR(64) NOT NULL UNIQUE,
    name VARCHAR(200) NOT NULL,
    brand_name VARCHAR(200) NOT NULL,
    owner_user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
    tax_code VARCHAR(32) NULL UNIQUE,
    company_address TEXT NULL,
    contact_email VARCHAR(255) NULL,
    contact_phone VARCHAR(32) NULL,
    logo_url TEXT NULL,
    default_locale VARCHAR(16) NOT NULL DEFAULT 'vi-VN',
    default_currency VARCHAR(8) NOT NULL DEFAULT 'VND',
    default_timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Ho_Chi_Minh',
    status public.entity_lifecycle_status NOT NULL DEFAULT 'ACTIVE',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ NULL
);

CREATE TABLE IF NOT EXISTS public.stores (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
    code VARCHAR(32) NOT NULL,
    name VARCHAR(200) NOT NULL,
    address TEXT NOT NULL,
    phone VARCHAR(32) NULL,
    email VARCHAR(255) NULL,
    tax_code_override VARCHAR(32) NULL,
    currency_code VARCHAR(8) NOT NULL DEFAULT 'VND',
    timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Ho_Chi_Minh',
    is_headquarters BOOLEAN NOT NULL DEFAULT FALSE,
    status public.entity_lifecycle_status NOT NULL DEFAULT 'ACTIVE',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ NULL,
    CONSTRAINT uq_stores_org_code UNIQUE (organization_id, code)
);

CREATE TABLE IF NOT EXISTS public.organization_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    setting_key VARCHAR(128) NOT NULL,
    setting_value JSONB NOT NULL,
    description TEXT NULL,
    updated_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_organization_settings_key UNIQUE (organization_id, setting_key)
);

CREATE TABLE IF NOT EXISTS public.store_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    setting_key VARCHAR(128) NOT NULL,
    setting_value JSONB NOT NULL,
    description TEXT NULL,
    updated_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_store_settings_key UNIQUE (store_id, setting_key)
);

CREATE TABLE IF NOT EXISTS public.memberships (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    employee_code VARCHAR(32) NULL,
    scope_type public.membership_scope_type NOT NULL DEFAULT 'STORE_SPECIFIC',
    default_store_id UUID NULL REFERENCES public.stores(id) ON DELETE SET NULL,
    status public.membership_status NOT NULL DEFAULT 'ACTIVE',
    invited_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_memberships_org_user UNIQUE (organization_id, user_id),
    CONSTRAINT uq_memberships_org_emp_code UNIQUE (organization_id, employee_code)
);

CREATE TABLE IF NOT EXISTS public.roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    code VARCHAR(64) NOT NULL,
    name VARCHAR(120) NOT NULL,
    description TEXT NULL,
    is_system_role BOOLEAN NOT NULL DEFAULT FALSE,
    scope_level public.membership_scope_type NOT NULL DEFAULT 'STORE_SPECIFIC',
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_roles_org_code UNIQUE (organization_id, code)
);

CREATE TABLE IF NOT EXISTS public.role_permissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES public.permissions(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_role_permissions UNIQUE (role_id, permission_id)
);

CREATE TABLE IF NOT EXISTS public.user_roles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    membership_id UUID NOT NULL REFERENCES public.memberships(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES public.roles(id) ON DELETE CASCADE,
    store_id UUID NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    assigned_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_user_roles_membership_role_store UNIQUE NULLS NOT DISTINCT (membership_id, role_id, store_id)
);

CREATE TABLE IF NOT EXISTS public.organization_modules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    module_key VARCHAR(64) NOT NULL REFERENCES public.modules(module_key) ON DELETE RESTRICT,
    status public.module_activation_status NOT NULL DEFAULT 'ENABLED',
    config JSONB NOT NULL DEFAULT '{}'::JSONB,
    updated_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_organization_modules UNIQUE (organization_id, module_key)
);

CREATE TABLE IF NOT EXISTS public.store_modules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    module_key VARCHAR(64) NOT NULL REFERENCES public.modules(module_key) ON DELETE RESTRICT,
    status public.module_activation_status NOT NULL DEFAULT 'ENABLED',
    config JSONB NOT NULL DEFAULT '{}'::JSONB,
    updated_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_store_modules UNIQUE (store_id, module_key)
);

CREATE TABLE IF NOT EXISTS public.devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    device_code VARCHAR(32) NOT NULL,
    device_name VARCHAR(150) NOT NULL,
    device_fingerprint VARCHAR(255) NOT NULL,
    platform public.device_platform_type NOT NULL,
    app_version VARCHAR(32) NULL,
    device_config JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_authorized BOOLEAN NOT NULL DEFAULT FALSE,
    authorized_by UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    authorized_at TIMESTAMPTZ NULL,
    status public.entity_lifecycle_status NOT NULL DEFAULT 'ACTIVE',
    last_seen_at TIMESTAMPTZ NULL,
    last_sync_at TIMESTAMPTZ NULL,
    version INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_devices_store_code UNIQUE (store_id, device_code),
    CONSTRAINT uq_devices_store_fingerprint UNIQUE (store_id, device_fingerprint)
);

CREATE TABLE IF NOT EXISTS public.device_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
    store_id UUID NOT NULL REFERENCES public.stores(id) ON DELETE CASCADE,
    device_id UUID NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ip_address VARCHAR(64) NULL,
    user_agent TEXT NULL,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ NULL,
    end_reason VARCHAR(64) NULL
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    organization_id UUID NOT NULL REFERENCES public.organizations(id) ON DELETE RESTRICT,
    store_id UUID NULL REFERENCES public.stores(id) ON DELETE RESTRICT,
    actor_user_id UUID NULL REFERENCES public.profiles(id) ON DELETE SET NULL,
    device_id UUID NULL REFERENCES public.devices(id) ON DELETE SET NULL,
    module_key VARCHAR(64) NOT NULL REFERENCES public.modules(module_key) ON DELETE RESTRICT,
    action_key VARCHAR(128) NOT NULL,
    entity_type VARCHAR(64) NOT NULL,
    entity_id VARCHAR(128) NOT NULL,
    severity public.audit_severity_level NOT NULL DEFAULT 'INFO',
    reason TEXT NULL,
    before_state JSONB NULL,
    after_state JSONB NULL,
    metadata JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_audit_logs_immutable
BEFORE UPDATE OR DELETE ON public.audit_logs
FOR EACH ROW EXECUTE FUNCTION public.tg_enforce_append_only_ledger();

COMMIT;
