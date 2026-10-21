BEGIN;
-- Atomic import of a new offline sale. Never acknowledge before both order and
-- optional cash payment are committed; changes to price/shift become conflicts.
CREATE FUNCTION public.rpc_sync_offline_sale(
 p_org_id uuid,p_store_id uuid,p_operation_id uuid,p_channel text,p_position_id uuid,
 p_items jsonb,p_customer jsonb,p_expected_total bigint,
 p_shift_id uuid DEFAULT NULL,p_payment_operation_id uuid DEFAULT NULL,p_received_amount bigint DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE req jsonb; previous public.finance_requests%ROWTYPE; saved jsonb; payment jsonb; result jsonb;
BEGIN
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
 result:=saved||jsonb_build_object('operation_id',p_operation_id,'payment',payment,
  'status',CASE WHEN payment IS NULL THEN 'OPEN' ELSE 'PAID' END);
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result)
  VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,result);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.rpc_sync_offline_sale(uuid,uuid,uuid,text,uuid,jsonb,jsonb,bigint,uuid,uuid,bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_sync_offline_sale(uuid,uuid,uuid,text,uuid,jsonb,jsonb,bigint,uuid,uuid,bigint) TO authenticated;
COMMIT;
