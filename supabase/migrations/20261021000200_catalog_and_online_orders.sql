-- Online sales vertical slice; KDS, printing and ingredient inventory are deferred.
BEGIN;
INSERT INTO public.modules(module_key,name,description,category,is_core)
VALUES ('catalog','Thực đơn','Menu và giá bán','BUSINESS',false),('pos','Bán hàng','Đơn hàng tại cửa hàng','BUSINESS',false)
ON CONFLICT(module_key) DO NOTHING;
INSERT INTO public.permissions(permission_key,module_key,name,description)
VALUES ('catalog.manage','catalog','Quản lý thực đơn','Tạo món, size, topping và giá'),('pos.order.write','pos','Ghi đơn hàng','Tạo và sửa đơn đang mở')
ON CONFLICT(permission_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.authorize_action(p_org_id uuid,p_store_id uuid,p_permission text,p_module text DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
  SELECT public.has_store_access(p_org_id,p_store_id) AND EXISTS (
    SELECT 1 FROM public.memberships m JOIN public.user_roles ur ON ur.membership_id=m.id AND ur.organization_id=m.organization_id
    JOIN public.roles r ON r.id=ur.role_id AND r.organization_id=m.organization_id
    WHERE m.user_id=auth.uid() AND m.organization_id=p_org_id AND m.status='ACTIVE'
      AND (ur.store_id=p_store_id OR (ur.store_id IS NULL AND m.scope_type='ORG_WIDE' AND r.scope_level='ORG_WIDE'))
      AND (r.code='OWNER' OR EXISTS (
        SELECT 1 FROM public.role_permissions rp JOIN public.permissions p ON p.id=rp.permission_id
        WHERE rp.role_id=r.id AND rp.organization_id=p_org_id AND p.permission_key=p_permission
          AND (p_module IS NULL OR p.module_key=p_module)
      ))
  );
$$;

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL,
  name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 200), category text NOT NULL DEFAULT 'Thực đơn',
  active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(organization_id,store_id,id), FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id)
);
CREATE TABLE public.product_variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL, product_id uuid NOT NULL,
  name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100), price bigint NOT NULL CHECK(price BETWEEN 0 AND 1000000000),
  active boolean NOT NULL DEFAULT true, UNIQUE(organization_id,store_id,id),
  FOREIGN KEY(organization_id,store_id,product_id) REFERENCES public.products(organization_id,store_id,id)
);
CREATE TABLE public.product_modifiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL, product_id uuid NOT NULL,
  name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100), price bigint NOT NULL CHECK(price BETWEEN 0 AND 1000000000),
  active boolean NOT NULL DEFAULT true, UNIQUE(organization_id,store_id,id),
  FOREIGN KEY(organization_id,store_id,product_id) REFERENCES public.products(organization_id,store_id,id)
);
CREATE TABLE public.service_positions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL,
  name text NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 100), active boolean NOT NULL DEFAULT true,
  UNIQUE(store_id,name), UNIQUE(organization_id,store_id,id),
  FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id)
);
CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL,
  channel text NOT NULL CHECK(channel IN ('DINE_IN','TAKEAWAY','DELIVERY')),
  position_id uuid, customer jsonb NOT NULL DEFAULT '{}'::jsonb,
  order_status text NOT NULL DEFAULT 'OPEN' CHECK(order_status IN ('OPEN','PAID','VOID')),
  total_amount bigint NOT NULL DEFAULT 0 CHECK(total_amount>=0), revision integer NOT NULL DEFAULT 1,
  created_by uuid NOT NULL REFERENCES public.profiles(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK((channel='DINE_IN' AND position_id IS NOT NULL) OR (channel<>'DINE_IN' AND position_id IS NULL)),
  UNIQUE(organization_id,store_id,id), FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id),
  FOREIGN KEY(organization_id,store_id,position_id) REFERENCES public.service_positions(organization_id,store_id,id)
);
CREATE UNIQUE INDEX orders_one_open_order_per_table ON public.orders(store_id,position_id) WHERE order_status='OPEN' AND position_id IS NOT NULL;
CREATE INDEX orders_store_status_updated ON public.orders(store_id,order_status,updated_at DESC);
CREATE TABLE public.order_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL, order_id uuid NOT NULL,
  variant_id uuid NOT NULL, product_name text NOT NULL, variant_name text NOT NULL,
  quantity integer NOT NULL CHECK(quantity BETWEEN 1 AND 999), unit_amount bigint NOT NULL CHECK(unit_amount>=0),
  modifier_snapshot jsonb NOT NULL DEFAULT '[]'::jsonb, line_amount bigint NOT NULL CHECK(line_amount=quantity::bigint*unit_amount),
  FOREIGN KEY(organization_id,store_id,order_id) REFERENCES public.orders(organization_id,store_id,id),
  FOREIGN KEY(organization_id,store_id,variant_id) REFERENCES public.product_variants(organization_id,store_id,id)
);
CREATE TABLE public.order_requests (
  organization_id uuid NOT NULL, store_id uuid NOT NULL, operation_id uuid NOT NULL,
  actor_id uuid NOT NULL REFERENCES public.profiles(id), request_payload jsonb NOT NULL, response_payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(organization_id,store_id,operation_id),
  FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id)
);
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['products','product_variants','product_modifiers','service_positions','orders','order_items'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY read_store ON public.%I FOR SELECT TO authenticated USING(public.has_store_access(organization_id,store_id))',t);
    EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
    EXECUTE format('GRANT SELECT ON public.%I TO authenticated',t);
  END LOOP;
END $$;
ALTER TABLE public.order_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_requests FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.order_requests FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.rpc_create_product(p_org_id uuid,p_store_id uuid,p_product jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE product_id uuid; v jsonb;
BEGIN
  IF NOT public.authorize_action(p_org_id,p_store_id,'catalog.manage','catalog') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
  IF jsonb_typeof(p_product)<>'object' OR p_product IS NULL OR p_product->>'name' IS NULL
    OR jsonb_typeof(p_product->'variants') IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_product->'variants') NOT BETWEEN 1 AND 20
    OR (p_product ? 'modifiers' AND jsonb_typeof(p_product->'modifiers')<>'array') THEN
    RAISE EXCEPTION 'INVALID_PRODUCT' USING ERRCODE='22023';
  END IF;
  IF jsonb_array_length(COALESCE(p_product->'modifiers','[]'))>30 THEN RAISE EXCEPTION 'TOO_MANY_MODIFIERS' USING ERRCODE='22023'; END IF;
  INSERT INTO public.products(organization_id,store_id,name,category) VALUES(p_org_id,p_store_id,trim(p_product->>'name'),COALESCE(NULLIF(trim(p_product->>'category'),''),'Thực đơn')) RETURNING id INTO product_id;
  FOR v IN SELECT value FROM jsonb_array_elements(p_product->'variants') LOOP
    IF jsonb_typeof(v->'price') IS DISTINCT FROM 'number' OR (v->>'price')::numeric<>trunc((v->>'price')::numeric) THEN RAISE EXCEPTION 'INVALID_PRICE' USING ERRCODE='22023'; END IF;
    INSERT INTO public.product_variants(organization_id,store_id,product_id,name,price) VALUES(p_org_id,p_store_id,product_id,v->>'name',(v->>'price')::bigint);
  END LOOP;
  FOR v IN SELECT value FROM jsonb_array_elements(COALESCE(p_product->'modifiers','[]')) LOOP
    IF jsonb_typeof(v->'price') IS DISTINCT FROM 'number' OR (v->>'price')::numeric<>trunc((v->>'price')::numeric) THEN RAISE EXCEPTION 'INVALID_PRICE' USING ERRCODE='22023'; END IF;
    INSERT INTO public.product_modifiers(organization_id,store_id,product_id,name,price) VALUES(p_org_id,p_store_id,product_id,v->>'name',(v->>'price')::bigint);
  END LOOP;
  INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,after_state)
    VALUES(p_org_id,p_store_id,auth.uid(),'catalog','catalog.product.created','product',product_id::text,p_product);
  RETURN product_id;
END $$;
CREATE FUNCTION public.rpc_update_variant(p_org_id uuid,p_store_id uuid,p_variant_id uuid,p_price bigint,p_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT public.authorize_action(p_org_id,p_store_id,'catalog.manage','catalog') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
  UPDATE public.product_variants SET price=p_price,active=p_active WHERE id=p_variant_id AND organization_id=p_org_id AND store_id=p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'VARIANT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,after_state)
    VALUES(p_org_id,p_store_id,auth.uid(),'catalog','catalog.variant.updated','variant',p_variant_id::text,jsonb_build_object('price',p_price,'active',p_active));
END $$;
CREATE FUNCTION public.rpc_create_position(p_org_id uuid,p_store_id uuid,p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE result uuid;
BEGIN
  IF NOT public.authorize_action(p_org_id,p_store_id,'catalog.manage','catalog') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
  INSERT INTO public.service_positions(organization_id,store_id,name) VALUES(p_org_id,p_store_id,trim(p_name)) RETURNING id INTO result;
  RETURN result;
END $$;
CREATE FUNCTION public.rpc_store_context(p_org_id uuid,p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
  IF NOT public.has_store_access(p_org_id,p_store_id) THEN RAISE EXCEPTION 'STORE_ACCESS_DENIED' USING ERRCODE='42501'; END IF;
  RETURN jsonb_build_object('can_manage_catalog',public.authorize_action(p_org_id,p_store_id,'catalog.manage','catalog'),'can_sell',public.authorize_action(p_org_id,p_store_id,'pos.order.write','pos'));
END $$;

CREATE FUNCTION public.rpc_save_order(p_org_id uuid,p_store_id uuid,p_operation_id uuid,p_channel text,p_position_id uuid,p_items jsonb,p_customer jsonb DEFAULT '{}'::jsonb,p_order_id uuid DEFAULT NULL,p_expected_revision integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE req jsonb; previous public.order_requests%ROWTYPE; existing public.orders%ROWTYPE;
  item jsonb; variant record; modifier record; qty integer; unit_price bigint; total bigint:=0;
  option_ids jsonb; options jsonb; order_id uuid; result jsonb;
BEGIN
  IF NOT public.authorize_action(p_org_id,p_store_id,'pos.order.write','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
  IF p_operation_id IS NULL OR p_channel IS NULL OR p_channel NOT IN ('DINE_IN','TAKEAWAY','DELIVERY')
    OR jsonb_typeof(p_items) IS DISTINCT FROM 'array' OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 100
    OR jsonb_typeof(p_customer) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'INVALID_ORDER' USING ERRCODE='22023'; END IF;
  IF p_channel='DELIVERY' AND (length(COALESCE(trim(p_customer->>'phone'),'')) NOT BETWEEN 8 AND 20 OR length(COALESCE(trim(p_customer->>'address'),'')) NOT BETWEEN 3 AND 500) THEN
    RAISE EXCEPTION 'DELIVERY_DETAILS_REQUIRED' USING ERRCODE='22023'; END IF;
  IF (p_channel='DINE_IN') IS DISTINCT FROM (p_position_id IS NOT NULL) THEN RAISE EXCEPTION 'INVALID_POSITION' USING ERRCODE='22023'; END IF;
  req:=jsonb_build_object('channel',p_channel,'position_id',p_position_id,'items',p_items,'customer',p_customer,'order_id',p_order_id,'revision',p_expected_revision);
  -- Serializes writes within a store, including retries and two terminals on one table.
  PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
  SELECT * INTO previous FROM public.order_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
  IF FOUND THEN
    IF previous.actor_id<>auth.uid() OR previous.request_payload<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
    RETURN previous.response_payload || jsonb_build_object('replayed',true);
  END IF;
  IF p_position_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.service_positions WHERE id=p_position_id AND organization_id=p_org_id AND store_id=p_store_id AND active) THEN RAISE EXCEPTION 'POSITION_NOT_FOUND' USING ERRCODE='P0002'; END IF;
  IF p_order_id IS NOT NULL THEN
    SELECT * INTO existing FROM public.orders WHERE id=p_order_id AND organization_id=p_org_id AND store_id=p_store_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
    IF existing.order_status<>'OPEN' THEN RAISE EXCEPTION 'ORDER_FINALIZED' USING ERRCODE='55000'; END IF;
    IF p_expected_revision IS DISTINCT FROM existing.revision THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
    order_id:=existing.id;
    DELETE FROM public.order_items WHERE order_items.order_id=existing.id;
    UPDATE public.orders SET channel=p_channel,position_id=p_position_id,customer=p_customer,revision=revision+1,updated_at=now() WHERE id=existing.id;
  ELSE
    INSERT INTO public.orders(organization_id,store_id,channel,position_id,customer,created_by) VALUES(p_org_id,p_store_id,p_channel,p_position_id,p_customer,auth.uid()) RETURNING id INTO order_id;
  END IF;
  FOR item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(item->'quantity') IS DISTINCT FROM 'number' OR (item->>'quantity')::numeric<>trunc((item->>'quantity')::numeric) THEN RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE='22023'; END IF;
    qty:=(item->>'quantity')::integer;
    IF qty NOT BETWEEN 1 AND 999 THEN RAISE EXCEPTION 'INVALID_QUANTITY' USING ERRCODE='22023'; END IF;
    SELECT v.*,p.name AS product_name INTO variant FROM public.product_variants v JOIN public.products p ON p.id=v.product_id
      WHERE v.id=(item->>'variant_id')::uuid AND v.organization_id=p_org_id AND v.store_id=p_store_id AND v.active AND p.active;
    IF NOT FOUND THEN RAISE EXCEPTION 'VARIANT_UNAVAILABLE' USING ERRCODE='P0002'; END IF;
    unit_price:=variant.price; options:='[]'::jsonb; option_ids:=COALESCE(item->'modifier_ids','[]'::jsonb);
    IF jsonb_typeof(option_ids) IS DISTINCT FROM 'array' OR jsonb_array_length(option_ids)>30 THEN RAISE EXCEPTION 'INVALID_MODIFIERS' USING ERRCODE='22023'; END IF;
    IF (SELECT count(*)<>count(DISTINCT value) FROM jsonb_array_elements_text(option_ids)) THEN RAISE EXCEPTION 'DUPLICATE_MODIFIER' USING ERRCODE='22023'; END IF;
    FOR modifier IN SELECT m.* FROM jsonb_array_elements_text(option_ids) x(id)
      LEFT JOIN public.product_modifiers m ON m.id=x.id::uuid AND m.product_id=variant.product_id AND m.organization_id=p_org_id AND m.store_id=p_store_id AND m.active LOOP
      IF modifier.id IS NULL THEN RAISE EXCEPTION 'MODIFIER_UNAVAILABLE' USING ERRCODE='P0002'; END IF;
      unit_price:=unit_price+modifier.price;
      options:=options||jsonb_build_array(jsonb_build_object('id',modifier.id,'name',modifier.name,'price',modifier.price));
    END LOOP;
    INSERT INTO public.order_items(organization_id,store_id,order_id,variant_id,product_name,variant_name,quantity,unit_amount,modifier_snapshot,line_amount)
      VALUES(p_org_id,p_store_id,order_id,variant.id,variant.product_name,variant.name,qty,unit_price,options,qty::bigint*unit_price);
    total:=total+qty::bigint*unit_price;
  END LOOP;
  UPDATE public.orders SET total_amount=total WHERE id=order_id RETURNING jsonb_build_object('order_id',id,'revision',revision,'total_amount',total_amount,'status',order_status) INTO result;
  INSERT INTO public.order_requests(organization_id,store_id,operation_id,actor_id,request_payload,response_payload) VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,result);
  INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,before_state,after_state)
    VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.order.saved','order',order_id::text,to_jsonb(existing),result);
  RETURN result;
END $$;
CREATE POLICY audit_logs_read_manager ON public.audit_logs FOR SELECT TO authenticated
  USING(store_id IS NOT NULL AND public.authorize_action(organization_id,store_id,'catalog.manage','catalog'));
REVOKE ALL ON FUNCTION public.authorize_action(uuid,uuid,text,text),public.rpc_create_product(uuid,uuid,jsonb),public.rpc_update_variant(uuid,uuid,uuid,bigint,boolean),public.rpc_create_position(uuid,uuid,text),public.rpc_store_context(uuid,uuid),public.rpc_save_order(uuid,uuid,uuid,text,uuid,jsonb,jsonb,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.authorize_action(uuid,uuid,text,text),public.rpc_create_product(uuid,uuid,jsonb),public.rpc_update_variant(uuid,uuid,uuid,bigint,boolean),public.rpc_create_position(uuid,uuid,text),public.rpc_store_context(uuid,uuid),public.rpc_save_order(uuid,uuid,uuid,text,uuid,jsonb,jsonb,uuid,integer) TO authenticated;
COMMIT;
