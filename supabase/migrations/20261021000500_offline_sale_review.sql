BEGIN;
INSERT INTO public.permissions(permission_key,module_key,name,description) VALUES
 ('pos.offline.resolve','pos','Đối soát đơn offline','Duyệt hủy bản ghi chưa lên server sau khi đối soát tiền khách')
ON CONFLICT(permission_key) DO NOTHING;
CREATE TABLE public.offline_sale_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), organization_id uuid NOT NULL, store_id uuid NOT NULL,
 operation_id uuid NOT NULL, actor_id uuid NOT NULL REFERENCES public.profiles(id), sender_name text NOT NULL,
 request_payload jsonb NOT NULL, item_labels jsonb NOT NULL DEFAULT '[]'::jsonb, note text NOT NULL CHECK(length(trim(note)) BETWEEN 3 AND 500),
 created_at timestamptz NOT NULL DEFAULT now(), status text NOT NULL DEFAULT 'OPEN' CHECK(status IN ('OPEN','CANCELLED')),
 resolved_by uuid REFERENCES public.profiles(id), resolved_at timestamptz, resolution_operation_id uuid,
 resolution_reason text, cash_refunded boolean, result jsonb NOT NULL DEFAULT '{}'::jsonb,
 UNIQUE(organization_id,store_id,operation_id), UNIQUE(organization_id,store_id,resolution_operation_id),
 FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id),
 CHECK((status='OPEN' AND resolved_by IS NULL AND resolved_at IS NULL) OR
       (status<>'OPEN' AND resolved_by IS NOT NULL AND resolved_at IS NOT NULL))
);
ALTER TABLE public.offline_sale_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.offline_sale_reviews FORCE ROW LEVEL SECURITY;
REVOKE ALL ON public.offline_sale_reviews FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.offline_sale_reviews TO authenticated;
CREATE POLICY read_offline_review ON public.offline_sale_reviews FOR SELECT TO authenticated
 USING(public.has_store_access(organization_id,store_id) AND
  (actor_id=auth.uid() OR public.authorize_action(organization_id,store_id,'pos.offline.resolve','pos')));
CREATE INDEX offline_sale_reviews_open ON public.offline_sale_reviews(store_id,created_at,id) WHERE status='OPEN';
CREATE INDEX offline_sale_reviews_actor_receipts ON public.offline_sale_reviews(store_id,actor_id,operation_id);
CREATE FUNCTION public.tg_protect_offline_review() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'IMMUTABLE_LEDGER_VIOLATION'; END IF;
 IF OLD.status<>'OPEN' OR
  (to_jsonb(OLD)-ARRAY['status','resolved_by','resolved_at','resolution_operation_id','resolution_reason','cash_refunded','result'])
   IS DISTINCT FROM
  (to_jsonb(NEW)-ARRAY['status','resolved_by','resolved_at','resolution_operation_id','resolution_reason','cash_refunded','result']) THEN
  RAISE EXCEPTION 'IMMUTABLE_LEDGER_VIOLATION'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER protect_offline_review BEFORE UPDATE OR DELETE ON public.offline_sale_reviews
 FOR EACH ROW EXECUTE FUNCTION public.tg_protect_offline_review();

-- Same immutable fingerprint used by rpc_sync_offline_sale's finance receipt.
CREATE FUNCTION public.offline_review_finance_payload(r jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp AS $$
 SELECT jsonb_build_object('kind','offline_sale','channel',r->'p_channel','position',r->'p_position_id',
  'items',r->'p_items','customer',r->'p_customer','expected_total',r->'p_expected_total',
  'shift',r->'p_shift_id','payment_operation',r->'p_payment_operation_id','received',r->'p_received_amount');
$$;
CREATE FUNCTION public.offline_review_request(r jsonb) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path=public,pg_temp AS $$
DECLARE expected numeric; received numeric;
BEGIN
 IF r IS NULL OR jsonb_typeof(r)<>'object' OR length(r::text)>131072 OR
  jsonb_typeof(r->'p_items') IS DISTINCT FROM 'array' OR
  jsonb_typeof(r->'p_customer') IS DISTINCT FROM 'object' OR
  jsonb_typeof(r->'p_expected_total') IS DISTINCT FROM 'number' THEN
  RAISE EXCEPTION 'INVALID_OFFLINE_SALE' USING ERRCODE='22023'; END IF;
 IF jsonb_array_length(r->'p_items') NOT BETWEEN 1 AND 100 OR
  r->>'p_channel' IS NULL OR r->>'p_channel' NOT IN ('DINE_IN','TAKEAWAY','DELIVERY') OR
  ((r->>'p_channel'='DINE_IN') IS DISTINCT FROM (r->>'p_position_id' IS NOT NULL)) THEN
  RAISE EXCEPTION 'INVALID_OFFLINE_SALE' USING ERRCODE='22023'; END IF;
 PERFORM (r->>'p_position_id')::uuid;
 expected:=(r->>'p_expected_total')::numeric;
 IF expected<0 OR expected>1000000000000 OR expected<>trunc(expected) THEN RAISE EXCEPTION 'INVALID_OFFLINE_SALE'; END IF;
 IF r->>'p_received_amount' IS NOT NULL THEN
  IF jsonb_typeof(r->'p_received_amount')<>'number' OR r->>'p_shift_id' IS NULL OR r->>'p_payment_operation_id' IS NULL THEN
   RAISE EXCEPTION 'INVALID_OFFLINE_PAYMENT'; END IF;
  received:=(r->>'p_received_amount')::numeric;
  IF received<expected OR received>1000000000000 OR received<>trunc(received) THEN RAISE EXCEPTION 'INVALID_OFFLINE_PAYMENT'; END IF;
  PERFORM (r->>'p_shift_id')::uuid; PERFORM (r->>'p_payment_operation_id')::uuid;
 ELSIF r->>'p_shift_id' IS NOT NULL OR r->>'p_payment_operation_id' IS NOT NULL THEN RAISE EXCEPTION 'INVALID_OFFLINE_PAYMENT';
 END IF;
 RETURN jsonb_build_object('p_channel',r->'p_channel','p_position_id',r->'p_position_id','p_items',r->'p_items',
  'p_customer',r->'p_customer','p_expected_total',r->'p_expected_total','p_shift_id',r->'p_shift_id',
  'p_payment_operation_id',r->'p_payment_operation_id','p_received_amount',r->'p_received_amount');
END $$;
CREATE FUNCTION public.rpc_submit_offline_review(p_org_id uuid,p_store_id uuid,p_operation_id uuid,p_request jsonb,p_note text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE original jsonb; review public.offline_sale_reviews%ROWTYPE; previous public.finance_requests%ROWTYPE; sender text; labels jsonb;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.order.write','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'OPERATION_REQUIRED'; END IF;
 IF p_note IS NULL OR length(trim(p_note)) NOT BETWEEN 3 AND 500 THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
 original:=public.offline_review_request(p_request);
 IF original->>'p_received_amount' IS NOT NULL AND
  (NOT public.authorize_action(p_org_id,p_store_id,'pos.payment.collect','pos') OR (original->>'p_payment_operation_id')::uuid=p_operation_id) THEN
  RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF original->>'p_received_amount' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.cash_shifts WHERE id=(original->>'p_shift_id')::uuid AND organization_id=p_org_id AND store_id=p_store_id AND opened_by=auth.uid()) THEN
  RAISE EXCEPTION 'SHIFT_NOT_FOUND'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO review FROM public.offline_sale_reviews WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF review.actor_id<>auth.uid() OR review.request_payload<>original THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED'; END IF;
  RETURN jsonb_build_object('review_id',review.id,'operation_id',p_operation_id,'status',review.status,'result',review.result);
 END IF;
 SELECT * INTO previous FROM public.finance_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF previous.actor_id<>auth.uid() OR previous.payload<>public.offline_review_finance_payload(original) THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED'; END IF;
  RETURN jsonb_build_object('operation_id',p_operation_id,'status','SYNCED','result',previous.result);
 END IF;
 IF EXISTS(SELECT 1 FROM public.order_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id) THEN
  RAISE EXCEPTION 'ONLINE_ORDER_EXISTS'; END IF;
 SELECT COALESCE(NULLIF(full_name,''),'Nhân viên') INTO sender FROM public.profiles WHERE id=auth.uid();
 SELECT COALESCE(jsonb_agg(jsonb_build_object('name',COALESCE(p.name||' / '||v.name,item->>'variant_id')) ORDER BY ordinal),'[]'::jsonb) INTO labels
  FROM jsonb_array_elements(original->'p_items') WITH ORDINALITY AS x(item,ordinal)
  LEFT JOIN public.product_variants v ON v.id=(item->>'variant_id')::uuid AND v.organization_id=p_org_id AND v.store_id=p_store_id
  LEFT JOIN public.products p ON p.id=v.product_id;
 INSERT INTO public.offline_sale_reviews(organization_id,store_id,operation_id,actor_id,sender_name,request_payload,item_labels,note)
  VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),sender,original,labels,trim(p_note)) RETURNING * INTO review;
 INSERT INTO public.order_requests(organization_id,store_id,operation_id,actor_id,request_payload,response_payload)
  VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),
   jsonb_build_object('channel',original->'p_channel','position_id',original->'p_position_id','items',original->'p_items',
    'customer',original->'p_customer','order_id',NULL,'revision',NULL),
   jsonb_build_object('operation_id',p_operation_id,'review_id',review.id,'status','REVIEW_REQUIRED'));
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,reason,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.offline.review_submitted','offline_review',review.id::text,trim(p_note),jsonb_build_object('operation_id',p_operation_id));
 RETURN jsonb_build_object('review_id',review.id,'operation_id',p_operation_id,'status','OPEN');
END $$;
CREATE FUNCTION public.rpc_cancel_offline_review(p_org_id uuid,p_store_id uuid,p_review_id uuid,p_operation_id uuid,p_reason text,p_cash_refunded boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE review public.offline_sale_reviews%ROWTYPE; receipt jsonb; original jsonb;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.offline.resolve','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'OPERATION_REQUIRED'; END IF;
 IF p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 3 AND 500 THEN RAISE EXCEPTION 'REASON_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO review FROM public.offline_sale_reviews WHERE id=p_review_id AND organization_id=p_org_id AND store_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'REVIEW_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF review.status='CANCELLED' THEN
  IF review.resolution_operation_id=p_operation_id AND review.resolved_by=auth.uid() AND review.resolution_reason=trim(p_reason) AND review.cash_refunded IS NOT DISTINCT FROM p_cash_refunded THEN RETURN review.result; END IF;
  RAISE EXCEPTION 'REVIEW_ALREADY_RESOLVED';
 END IF;
 IF review.status<>'OPEN' THEN RAISE EXCEPTION 'OFFLINE_SALE_ALREADY_COMMITTED'; END IF;
 original:=review.request_payload;
 IF original->>'p_received_amount' IS NOT NULL AND p_cash_refunded IS NOT TRUE THEN RAISE EXCEPTION 'CASH_REFUND_CONFIRMATION_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM public.finance_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=review.operation_id) OR
    EXISTS(SELECT 1 FROM public.order_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=review.operation_id AND
     (actor_id<>review.actor_id OR response_payload->>'status'<>'REVIEW_REQUIRED' OR response_payload->>'review_id' IS DISTINCT FROM review.id::text)) THEN
  RAISE EXCEPTION 'OFFLINE_SALE_ALREADY_COMMITTED'; END IF;
 receipt:=jsonb_build_object('operation_id',review.operation_id,'review_id',review.id,'status','CANCELLED',
  'reason',trim(p_reason),'resolved_by',auth.uid(),'resolved_at',now(),
  'cash_refund_amount',CASE WHEN original->>'p_received_amount' IS NOT NULL THEN (original->>'p_expected_total')::bigint ELSE 0 END);
 -- Permanent receipts reserve the original ID in both entry points. No order,
 -- payment or server refund is created for a sale that never reached the ledger.
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result)
  VALUES(p_org_id,p_store_id,review.operation_id,review.actor_id,public.offline_review_finance_payload(original),receipt);
 UPDATE public.order_requests SET response_payload=receipt
  WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=review.operation_id
   AND response_payload->>'review_id'=review.id::text AND response_payload->>'status'='REVIEW_REQUIRED';
 IF NOT FOUND THEN RAISE EXCEPTION 'REVIEW_RESERVATION_MISSING'; END IF;
 UPDATE public.offline_sale_reviews SET status='CANCELLED',resolved_by=auth.uid(),resolved_at=now(),
  resolution_operation_id=p_operation_id,resolution_reason=trim(p_reason),cash_refunded=p_cash_refunded,result=receipt WHERE id=review.id;
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,reason,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.offline.review_cancelled','offline_review',review.id::text,trim(p_reason),receipt);
 RETURN receipt;
END $$;
CREATE OR REPLACE FUNCTION public.rpc_sync_offline_sale(
 p_org_id uuid,p_store_id uuid,p_operation_id uuid,p_channel text,p_position_id uuid,
 p_items jsonb,p_customer jsonb,p_expected_total bigint,
 p_shift_id uuid DEFAULT NULL,p_payment_operation_id uuid DEFAULT NULL,p_received_amount bigint DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE review public.offline_sale_reviews%ROWTYPE; req jsonb; previous public.finance_requests%ROWTYPE; saved jsonb; payment jsonb; sync_result jsonb;
BEGIN
 IF NOT public.has_store_access(p_org_id,p_store_id) THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 req:=jsonb_build_object('kind','offline_sale','channel',p_channel,'position',p_position_id,'items',p_items,'customer',p_customer,
  'expected_total',p_expected_total,'shift',p_shift_id,'payment_operation',p_payment_operation_id,'received',p_received_amount);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO review FROM public.offline_sale_reviews WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF review.actor_id<>auth.uid() OR public.offline_review_finance_payload(review.request_payload)<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED'; END IF;
  IF review.status='CANCELLED' THEN RETURN review.result||jsonb_build_object('replayed',true); END IF;
  RAISE EXCEPTION 'OFFLINE_REVIEW_REQUIRED';
 END IF;
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.order.write','pos') THEN
  RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL OR p_expected_total IS NULL OR p_expected_total<0 THEN
  RAISE EXCEPTION 'INVALID_OFFLINE_SALE' USING ERRCODE='22023'; END IF;
 IF p_received_amount IS NOT NULL THEN
  IF NOT public.authorize_action(p_org_id,p_store_id,'pos.payment.collect','pos') THEN
   RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
  IF p_payment_operation_id IS NULL OR p_payment_operation_id=p_operation_id OR p_shift_id IS NULL THEN
   RAISE EXCEPTION 'INVALID_OFFLINE_PAYMENT' USING ERRCODE='22023'; END IF;
 ELSIF p_payment_operation_id IS NOT NULL OR p_shift_id IS NOT NULL THEN
  RAISE EXCEPTION 'INVALID_OFFLINE_PAYMENT' USING ERRCODE='22023';
 END IF;
 req:=jsonb_build_object('kind','offline_sale','channel',p_channel,'position',p_position_id,'items',p_items,'customer',p_customer,
  'expected_total',p_expected_total,'shift',p_shift_id,'payment_operation',p_payment_operation_id,'received',p_received_amount);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO previous FROM public.finance_requests
  WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF previous.actor_id<>auth.uid() OR previous.payload<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
  RETURN previous.result||jsonb_build_object('replayed',true);
 END IF;
 saved:=public.rpc_save_order(p_org_id,p_store_id,p_operation_id,p_channel,p_position_id,p_items,p_customer,NULL,NULL);
 IF (saved->>'total_amount')::bigint<>p_expected_total THEN
  RAISE EXCEPTION 'OFFLINE_PRICE_CONFLICT' USING ERRCODE='40001';
 END IF;
 IF p_received_amount IS NOT NULL THEN
  payment:=public.rpc_collect_payment(p_org_id,p_store_id,(saved->>'order_id')::uuid,p_shift_id,p_payment_operation_id,
   (saved->>'revision')::integer,'CASH',p_received_amount,false);
 END IF;
 sync_result:=saved||jsonb_build_object('operation_id',p_operation_id,'payment',payment,
  'status',CASE WHEN payment IS NULL THEN 'OPEN' ELSE 'PAID' END);
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result)
  VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,sync_result);
 RETURN sync_result;
END $$;
CREATE OR REPLACE FUNCTION public.rpc_store_context(p_org_id uuid,p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT public.has_store_access(p_org_id,p_store_id) THEN RAISE EXCEPTION 'STORE_ACCESS_DENIED' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('can_manage_catalog',public.authorize_action(p_org_id,p_store_id,'catalog.manage','catalog'),
  'can_sell',public.authorize_action(p_org_id,p_store_id,'pos.order.write','pos'),
  'can_manage_shift',public.authorize_action(p_org_id,p_store_id,'pos.shift.manage','pos'),
  'can_collect',public.authorize_action(p_org_id,p_store_id,'pos.payment.collect','pos'),
  'can_void',public.authorize_action(p_org_id,p_store_id,'pos.order.void','pos'),
  'can_refund',public.authorize_action(p_org_id,p_store_id,'pos.order.refund','pos'),
  'can_report',public.authorize_action(p_org_id,p_store_id,'pos.report.read','pos'),
  'can_review_offline',public.authorize_action(p_org_id,p_store_id,'pos.offline.resolve','pos'));
END $$;

REVOKE ALL ON FUNCTION public.tg_protect_offline_review(),public.offline_review_request(jsonb),public.offline_review_finance_payload(jsonb),
 public.rpc_submit_offline_review(uuid,uuid,uuid,jsonb,text),public.rpc_cancel_offline_review(uuid,uuid,uuid,uuid,text,boolean)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_submit_offline_review(uuid,uuid,uuid,jsonb,text),public.rpc_cancel_offline_review(uuid,uuid,uuid,uuid,text,boolean) TO authenticated;
COMMIT;
