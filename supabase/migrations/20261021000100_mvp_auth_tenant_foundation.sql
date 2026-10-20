-- MVP foundation: trust Supabase Auth, isolate tenants, deny unfinished sync APIs.
BEGIN;

CREATE OR REPLACE FUNCTION public.current_actor_id() RETURNS UUID
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT auth.uid();
$$;

CREATE OR REPLACE FUNCTION public.is_org_member(p_org_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.memberships m
    JOIN public.profiles p ON p.id = m.user_id AND p.status = 'ACTIVE'
    JOIN public.organizations o ON o.id = m.organization_id AND o.status = 'ACTIVE'
    WHERE m.organization_id = p_org_id AND m.user_id = auth.uid() AND m.status = 'ACTIVE'
  );
$$;

CREATE OR REPLACE FUNCTION public.has_store_access(p_org_id UUID, p_store_id UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT public.is_org_member(p_org_id) AND EXISTS (
    SELECT 1 FROM public.stores s
    JOIN public.memberships m ON m.organization_id = s.organization_id
    WHERE s.id = p_store_id AND s.organization_id = p_org_id AND s.status = 'ACTIVE'
      AND m.user_id = auth.uid() AND m.status = 'ACTIVE'
      AND (m.scope_type = 'ORG_WIDE' OR EXISTS (
        SELECT 1 FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id
        WHERE ur.membership_id = m.id AND ur.organization_id = p_org_id
          AND r.organization_id = p_org_id AND ur.store_id = p_store_id
      ))
  );
$$;

-- Composite foreign keys prevent rows from combining IDs from different tenants.
ALTER TABLE public.stores ADD CONSTRAINT uq_stores_org_id UNIQUE (organization_id, id);
ALTER TABLE public.memberships ADD CONSTRAINT uq_memberships_org_id UNIQUE (organization_id, id);
ALTER TABLE public.roles ADD CONSTRAINT uq_roles_org_id UNIQUE (organization_id, id);
ALTER TABLE public.devices ADD CONSTRAINT uq_devices_org_store_id UNIQUE (organization_id, store_id, id);
ALTER TABLE public.memberships ADD CONSTRAINT fk_memberships_store_tenant
  FOREIGN KEY (organization_id, default_store_id) REFERENCES public.stores(organization_id, id);
ALTER TABLE public.user_roles ADD CONSTRAINT fk_user_roles_membership_tenant
  FOREIGN KEY (organization_id, membership_id) REFERENCES public.memberships(organization_id, id);
ALTER TABLE public.user_roles ADD CONSTRAINT fk_user_roles_role_tenant
  FOREIGN KEY (organization_id, role_id) REFERENCES public.roles(organization_id, id);
ALTER TABLE public.role_permissions ADD CONSTRAINT fk_role_permissions_tenant
  FOREIGN KEY (organization_id, role_id) REFERENCES public.roles(organization_id, id);
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['store_settings','user_roles','store_modules','devices','device_sessions','audit_logs','device_sync_watermarks','sync_conflicts'] LOOP
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id, store_id) REFERENCES public.stores(organization_id, id)', t, 'fk_' || t || '_store_tenant');
  END LOOP;
  FOREACH t IN ARRAY ARRAY['device_sessions','device_sync_watermarks','sync_conflicts','audit_logs'] LOOP
    EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (organization_id, store_id, device_id) REFERENCES public.devices(organization_id, store_id, id)', t, 'fk_' || t || '_device_tenant');
  END LOOP;
END $$;

-- Start with read-only policies. Mutations require explicitly authorized RPCs.
CREATE POLICY profiles_read_self ON public.profiles FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY organizations_read_member ON public.organizations FOR SELECT TO authenticated USING (public.is_org_member(id));
CREATE POLICY stores_read_accessible ON public.stores FOR SELECT TO authenticated USING (public.has_store_access(organization_id, id));
CREATE POLICY memberships_read_self ON public.memberships FOR SELECT TO authenticated USING (user_id = auth.uid() AND public.is_org_member(organization_id));
CREATE POLICY user_roles_read_self ON public.user_roles FOR SELECT TO authenticated USING (
  EXISTS (SELECT 1 FROM public.memberships m WHERE m.id = membership_id AND m.user_id = auth.uid())
  AND public.is_org_member(organization_id)
);
CREATE POLICY roles_read_member ON public.roles FOR SELECT TO authenticated USING (public.is_org_member(organization_id));
CREATE POLICY role_permissions_read_member ON public.role_permissions FOR SELECT TO authenticated USING (public.is_org_member(organization_id));
CREATE POLICY organization_settings_read_member ON public.organization_settings FOR SELECT TO authenticated USING (public.is_org_member(organization_id));
CREATE POLICY organization_modules_read_member ON public.organization_modules FOR SELECT TO authenticated USING (public.is_org_member(organization_id));
CREATE POLICY store_settings_read_accessible ON public.store_settings FOR SELECT TO authenticated USING (public.has_store_access(organization_id, store_id));
CREATE POLICY store_modules_read_accessible ON public.store_modules FOR SELECT TO authenticated USING (public.has_store_access(organization_id, store_id));
CREATE POLICY devices_read_accessible ON public.devices FOR SELECT TO authenticated USING (public.has_store_access(organization_id, store_id));
CREATE POLICY device_sessions_read_self ON public.device_sessions FOR SELECT TO authenticated USING (user_id = auth.uid() AND public.has_store_access(organization_id, store_id));
CREATE POLICY modules_read_authenticated ON public.modules FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);
CREATE POLICY permissions_read_authenticated ON public.permissions FOR SELECT TO authenticated USING (auth.uid() IS NOT NULL);

CREATE OR REPLACE FUNCTION public.rpc_bootstrap_workspace(p_name text, p_slug text, p_store_name text, p_store_address text)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  actor uuid := auth.uid(); actor_email text; org_id uuid; store_id uuid; member_id uuid; role_id uuid;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED' USING ERRCODE = '42501'; END IF;
  SELECT email INTO actor_email FROM auth.users WHERE id = actor AND email_confirmed_at IS NOT NULL;
  IF actor_email IS NULL THEN RAISE EXCEPTION 'VERIFIED_EMAIL_REQUIRED' USING ERRCODE = '42501'; END IF;
  IF length(trim(p_name)) NOT BETWEEN 1 AND 200 OR length(trim(p_store_name)) NOT BETWEEN 1 AND 200
    OR length(trim(p_store_address)) NOT BETWEEN 1 AND 500
    OR p_name IS NULL OR p_store_name IS NULL OR p_store_address IS NULL OR p_slug IS NULL
    OR p_slug !~ '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$' THEN
    RAISE EXCEPTION 'INVALID_WORKSPACE_INPUT' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(actor::text, 0));
  IF EXISTS (SELECT 1 FROM public.memberships WHERE user_id = actor) THEN
    RAISE EXCEPTION 'WORKSPACE_ALREADY_EXISTS' USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.profiles (id,email,full_name) VALUES (actor,actor_email,trim(p_name)) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.organizations (code,slug,name,brand_name,owner_user_id)
    VALUES (p_slug,p_slug,trim(p_name),trim(p_name),actor) RETURNING id INTO org_id;
  INSERT INTO public.stores (organization_id,code,name,address,is_headquarters)
    VALUES (org_id,'MAIN',trim(p_store_name),trim(p_store_address),true) RETURNING id INTO store_id;
  INSERT INTO public.memberships (organization_id,user_id,scope_type,default_store_id)
    VALUES (org_id,actor,'ORG_WIDE',store_id) RETURNING id INTO member_id;
  INSERT INTO public.roles (organization_id,code,name,is_system_role,scope_level)
    VALUES (org_id,'OWNER','Chủ sở hữu',true,'ORG_WIDE') RETURNING id INTO role_id;
  INSERT INTO public.user_roles (organization_id,membership_id,role_id,assigned_by)
    VALUES (org_id,member_id,role_id,actor);
  RETURN jsonb_build_object('organization_id',org_id,'store_id',store_id);
END $$;

-- Legacy sync currently acknowledges without persisting orders; never expose it.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_store_sync_diagnostics_summary FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.modules, public.permissions, public.profiles, public.organizations,
  public.stores, public.organization_settings, public.store_settings, public.memberships,
  public.roles, public.role_permissions, public.user_roles, public.organization_modules,
  public.store_modules, public.devices, public.device_sessions, public.audit_logs,
  public.device_sync_watermarks, public.sync_conflicts TO authenticated;
GRANT EXECUTE ON FUNCTION public.current_actor_id(), public.is_org_member(uuid),
  public.has_store_access(uuid,uuid), public.rpc_bootstrap_workspace(text,text,text,text) TO authenticated;
COMMIT;
