BEGIN;
INSERT INTO public.permissions(permission_key,module_key,name,description) VALUES
 ('pos.shift.manage','pos','Quản lý ca của mình','Mở và đóng ca thu ngân'),
 ('pos.payment.collect','pos','Thu tiền','Ghi nhận thanh toán đủ tiền'),
 ('pos.order.void','pos','Hủy đơn','Hủy đơn chưa thanh toán với lý do'),
 ('pos.order.refund','pos','Hoàn tiền','Hoàn toàn bộ thanh toán với lý do'),
 ('pos.report.read','pos','Báo cáo doanh thu','Đọc đối soát và báo cáo cửa hàng')
ON CONFLICT(permission_key) DO NOTHING;
ALTER TABLE public.orders DROP CONSTRAINT orders_order_status_check;
ALTER TABLE public.orders ADD CHECK(order_status IN ('OPEN','PAID','VOID','REFUNDED'));
CREATE TABLE public.cash_shifts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),organization_id uuid NOT NULL,store_id uuid NOT NULL,
 opened_by uuid NOT NULL REFERENCES public.profiles(id),opening_amount bigint NOT NULL CHECK(opening_amount BETWEEN 0 AND 1000000000),
 opened_at timestamptz NOT NULL DEFAULT now(),closed_at timestamptz,expected_cash bigint,counted_cash bigint CHECK(counted_cash>=0),difference bigint,
 open_operation_id uuid NOT NULL,close_operation_id uuid,
 UNIQUE(organization_id,store_id,id),UNIQUE(organization_id,store_id,open_operation_id),UNIQUE(organization_id,store_id,close_operation_id),
 FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id)
);
CREATE UNIQUE INDEX cash_shifts_one_open_per_cashier ON public.cash_shifts(store_id,opened_by) WHERE closed_at IS NULL;
CREATE TABLE public.payments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),organization_id uuid NOT NULL,store_id uuid NOT NULL,
 order_id uuid NOT NULL UNIQUE,shift_id uuid NOT NULL,method text NOT NULL CHECK(method IN ('CASH','TRANSFER')),
 amount bigint NOT NULL CHECK(amount>=0),received_amount bigint NOT NULL CHECK(received_amount>=amount),change_amount bigint NOT NULL CHECK(change_amount=received_amount-amount),
 actor_id uuid NOT NULL REFERENCES public.profiles(id),created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(organization_id,store_id,id),FOREIGN KEY(organization_id,store_id,order_id) REFERENCES public.orders(organization_id,store_id,id),
 FOREIGN KEY(organization_id,store_id,shift_id) REFERENCES public.cash_shifts(organization_id,store_id,id)
);
CREATE TABLE public.refunds (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),organization_id uuid NOT NULL,store_id uuid NOT NULL,
 payment_id uuid NOT NULL UNIQUE,shift_id uuid NOT NULL,amount bigint NOT NULL CHECK(amount>=0),method text NOT NULL CHECK(method IN ('CASH','TRANSFER')),
 reason text NOT NULL CHECK(length(trim(reason)) BETWEEN 3 AND 500),actor_id uuid NOT NULL REFERENCES public.profiles(id),created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(organization_id,store_id,payment_id) REFERENCES public.payments(organization_id,store_id,id),
 FOREIGN KEY(organization_id,store_id,shift_id) REFERENCES public.cash_shifts(organization_id,store_id,id)
);
CREATE TABLE public.finance_requests (
 organization_id uuid NOT NULL,store_id uuid NOT NULL,operation_id uuid NOT NULL,actor_id uuid NOT NULL REFERENCES public.profiles(id),
 payload jsonb NOT NULL,result jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(organization_id,store_id,operation_id),
 FOREIGN KEY(organization_id,store_id) REFERENCES public.stores(organization_id,id)
);
CREATE TRIGGER payments_immutable BEFORE UPDATE OR DELETE ON public.payments FOR EACH ROW EXECUTE FUNCTION public.tg_enforce_append_only_ledger();
CREATE TRIGGER refunds_immutable BEFORE UPDATE OR DELETE ON public.refunds FOR EACH ROW EXECUTE FUNCTION public.tg_enforce_append_only_ledger();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['cash_shifts','payments','refunds','finance_requests'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated',t);
 END LOOP;
END $$;
CREATE POLICY read_shift ON public.cash_shifts FOR SELECT TO authenticated USING(public.has_store_access(organization_id,store_id) AND (opened_by=auth.uid() OR public.authorize_action(organization_id,store_id,'pos.report.read','pos')));
CREATE POLICY read_payments ON public.payments FOR SELECT TO authenticated USING(public.has_store_access(organization_id,store_id));
CREATE POLICY read_refunds ON public.refunds FOR SELECT TO authenticated USING(public.has_store_access(organization_id,store_id));
GRANT SELECT ON public.cash_shifts,public.payments,public.refunds TO authenticated;
CREATE FUNCTION public.rpc_open_shift(p_org_id uuid,p_store_id uuid,p_operation_id uuid,p_opening_amount bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE shift public.cash_shifts%ROWTYPE;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.shift.manage','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'OPERATION_REQUIRED' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO shift FROM public.cash_shifts WHERE organization_id=p_org_id AND store_id=p_store_id AND open_operation_id=p_operation_id;
 IF FOUND THEN
  IF shift.opened_by<>auth.uid() OR shift.opening_amount IS DISTINCT FROM p_opening_amount THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
  RETURN to_jsonb(shift);
 END IF;
 INSERT INTO public.cash_shifts(organization_id,store_id,opened_by,opening_amount,open_operation_id) VALUES(p_org_id,p_store_id,auth.uid(),p_opening_amount,p_operation_id) RETURNING * INTO shift;
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.shift.opened','shift',shift.id::text,to_jsonb(shift));
 RETURN to_jsonb(shift);
END $$;
CREATE FUNCTION public.shift_cash_balance(p_shift_id uuid) RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT s.opening_amount+COALESCE((SELECT sum(p.amount) FROM public.payments p WHERE p.shift_id=s.id AND p.method='CASH'),0)-COALESCE((SELECT sum(r.amount) FROM public.refunds r WHERE r.shift_id=s.id AND r.method='CASH'),0) FROM public.cash_shifts s WHERE s.id=p_shift_id;
$$;
CREATE FUNCTION public.rpc_close_shift(p_org_id uuid,p_store_id uuid,p_shift_id uuid,p_operation_id uuid,p_counted_cash bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE shift public.cash_shifts%ROWTYPE; expected bigint;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.shift.manage','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL THEN RAISE EXCEPTION 'OPERATION_REQUIRED' USING ERRCODE='22023'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO shift FROM public.cash_shifts WHERE id=p_shift_id AND organization_id=p_org_id AND store_id=p_store_id AND opened_by=auth.uid() FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'SHIFT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF shift.closed_at IS NOT NULL THEN
  IF shift.close_operation_id=p_operation_id AND shift.counted_cash=p_counted_cash THEN RETURN to_jsonb(shift); END IF;
  RAISE EXCEPTION 'SHIFT_CLOSED' USING ERRCODE='55000';
 END IF;
 IF p_counted_cash IS NULL OR p_counted_cash<0 OR p_counted_cash>1000000000000 THEN RAISE EXCEPTION 'INVALID_CASH_COUNT' USING ERRCODE='22023'; END IF;
 expected:=public.shift_cash_balance(shift.id);
 UPDATE public.cash_shifts SET closed_at=now(),close_operation_id=p_operation_id,expected_cash=expected,counted_cash=p_counted_cash,difference=p_counted_cash-expected WHERE id=shift.id RETURNING * INTO shift;
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.shift.closed','shift',shift.id::text,to_jsonb(shift));
 RETURN to_jsonb(shift);
END $$;
CREATE FUNCTION public.rpc_collect_payment(p_org_id uuid,p_store_id uuid,p_order_id uuid,p_shift_id uuid,p_operation_id uuid,p_expected_revision integer,p_method text,p_received_amount bigint,p_transfer_confirmed boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE req jsonb; prev public.finance_requests%ROWTYPE; ord public.orders%ROWTYPE; shift public.cash_shifts%ROWTYPE; pay public.payments%ROWTYPE; result jsonb;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.payment.collect','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL OR p_method IS NULL OR p_method NOT IN ('CASH','TRANSFER') THEN RAISE EXCEPTION 'INVALID_PAYMENT' USING ERRCODE='22023'; END IF;
 req:=jsonb_build_object('kind','payment','order',p_order_id,'shift',p_shift_id,'revision',p_expected_revision,'method',p_method,'received',p_received_amount,'confirmed',p_transfer_confirmed);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO prev FROM public.finance_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF prev.actor_id<>auth.uid() OR prev.payload<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
  RETURN prev.result||jsonb_build_object('replayed',true);
 END IF;
 SELECT * INTO shift FROM public.cash_shifts WHERE id=p_shift_id AND organization_id=p_org_id AND store_id=p_store_id AND opened_by=auth.uid() AND closed_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_SHIFT_REQUIRED' USING ERRCODE='55000'; END IF;
 SELECT * INTO ord FROM public.orders WHERE id=p_order_id AND organization_id=p_org_id AND store_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF ord.order_status<>'OPEN' THEN RAISE EXCEPTION 'ORDER_FINALIZED' USING ERRCODE='55000'; END IF;
 IF ord.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 IF p_received_amount IS NULL OR p_received_amount<ord.total_amount OR p_received_amount>1000000000000 THEN RAISE EXCEPTION 'INSUFFICIENT_PAYMENT' USING ERRCODE='22023'; END IF;
 IF p_method='TRANSFER' AND (p_transfer_confirmed IS NOT TRUE OR p_received_amount<>ord.total_amount) THEN RAISE EXCEPTION 'TRANSFER_CONFIRMATION_REQUIRED' USING ERRCODE='22023'; END IF;
 INSERT INTO public.payments(organization_id,store_id,order_id,shift_id,method,amount,received_amount,change_amount,actor_id)
  VALUES(p_org_id,p_store_id,ord.id,shift.id,p_method,ord.total_amount,p_received_amount,p_received_amount-ord.total_amount,auth.uid()) RETURNING * INTO pay;
 UPDATE public.orders SET order_status='PAID',revision=revision+1,updated_at=now() WHERE id=ord.id;
 result:=to_jsonb(pay);
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result) VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,result);
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.payment.collected','order',ord.id::text,result);
 RETURN result;
END $$;
CREATE FUNCTION public.rpc_void_order(p_org_id uuid,p_store_id uuid,p_order_id uuid,p_expected_revision integer,p_operation_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE req jsonb;prev public.finance_requests%ROWTYPE;ord public.orders%ROWTYPE;result jsonb;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.order.void','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL OR p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 3 AND 500 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
 req:=jsonb_build_object('kind','void','order',p_order_id,'revision',p_expected_revision,'reason',p_reason);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO prev FROM public.finance_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF prev.actor_id<>auth.uid() OR prev.payload<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
  RETURN prev.result||jsonb_build_object('replayed',true);
 END IF;
 SELECT * INTO ord FROM public.orders WHERE id=p_order_id AND organization_id=p_org_id AND store_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF ord.order_status<>'OPEN' THEN RAISE EXCEPTION 'ORDER_FINALIZED' USING ERRCODE='55000'; END IF;
 IF ord.revision IS DISTINCT FROM p_expected_revision THEN RAISE EXCEPTION 'VERSION_CONFLICT' USING ERRCODE='40001'; END IF;
 UPDATE public.orders SET order_status='VOID',revision=revision+1,updated_at=now() WHERE id=ord.id RETURNING to_jsonb(orders) INTO result;
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result) VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,result);
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,reason,before_state,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.order.voided','order',ord.id::text,trim(p_reason),to_jsonb(ord),result);
 RETURN result;
END $$;
CREATE FUNCTION public.rpc_refund_payment(p_org_id uuid,p_store_id uuid,p_payment_id uuid,p_shift_id uuid,p_operation_id uuid,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE req jsonb;prev public.finance_requests%ROWTYPE;pay public.payments%ROWTYPE;shift public.cash_shifts%ROWTYPE;ref public.refunds%ROWTYPE;result jsonb;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.order.refund','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_operation_id IS NULL OR p_reason IS NULL OR length(trim(p_reason)) NOT BETWEEN 3 AND 500 THEN RAISE EXCEPTION 'REASON_REQUIRED' USING ERRCODE='22023'; END IF;
 req:=jsonb_build_object('kind','refund','payment',p_payment_id,'shift',p_shift_id,'reason',p_reason);
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text,1));
 SELECT * INTO prev FROM public.finance_requests WHERE organization_id=p_org_id AND store_id=p_store_id AND operation_id=p_operation_id;
 IF FOUND THEN
  IF prev.actor_id<>auth.uid() OR prev.payload<>req THEN RAISE EXCEPTION 'IDEMPOTENCY_KEY_REUSED' USING ERRCODE='22023'; END IF;
  RETURN prev.result||jsonb_build_object('replayed',true);
 END IF;
 SELECT * INTO shift FROM public.cash_shifts WHERE id=p_shift_id AND organization_id=p_org_id AND store_id=p_store_id AND opened_by=auth.uid() AND closed_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'OPEN_SHIFT_REQUIRED' USING ERRCODE='55000'; END IF;
 SELECT * INTO pay FROM public.payments WHERE id=p_payment_id AND organization_id=p_org_id AND store_id=p_store_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND' USING ERRCODE='P0002'; END IF;
 IF (SELECT order_status FROM public.orders WHERE id=pay.order_id)<>'PAID' THEN RAISE EXCEPTION 'ORDER_FINALIZED' USING ERRCODE='55000'; END IF;
 IF pay.method='CASH' AND public.shift_cash_balance(shift.id)<pay.amount THEN RAISE EXCEPTION 'CASH_INSUFFICIENT' USING ERRCODE='22023'; END IF;
 INSERT INTO public.refunds(organization_id,store_id,payment_id,shift_id,amount,method,reason,actor_id)
  VALUES(p_org_id,p_store_id,pay.id,shift.id,pay.amount,pay.method,trim(p_reason),auth.uid()) RETURNING * INTO ref;
 UPDATE public.orders SET order_status='REFUNDED',revision=revision+1,updated_at=now() WHERE id=pay.order_id;
 result:=to_jsonb(ref);
 INSERT INTO public.finance_requests(organization_id,store_id,operation_id,actor_id,payload,result) VALUES(p_org_id,p_store_id,p_operation_id,auth.uid(),req,result);
 INSERT INTO public.audit_logs(organization_id,store_id,actor_user_id,module_key,action_key,entity_type,entity_id,reason,after_state)
  VALUES(p_org_id,p_store_id,auth.uid(),'pos','pos.payment.refunded','payment',pay.id::text,trim(p_reason),result);
 RETURN result;
END $$;
CREATE FUNCTION public.rpc_daily_report(p_org_id uuid,p_store_id uuid,p_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE zone text;start_at timestamptz;end_at timestamptz;
BEGIN
 IF NOT public.authorize_action(p_org_id,p_store_id,'pos.report.read','pos') THEN RAISE EXCEPTION 'PERMISSION_DENIED' USING ERRCODE='42501'; END IF;
 IF p_date IS NULL THEN RAISE EXCEPTION 'DATE_REQUIRED' USING ERRCODE='22023'; END IF;
 SELECT timezone INTO zone FROM public.stores WHERE id=p_store_id;
 start_at:=p_date::timestamp AT TIME ZONE zone;end_at:=(p_date+1)::timestamp AT TIME ZONE zone;
 RETURN jsonb_build_object('date',p_date,'timezone',zone,
  'gross',COALESCE((SELECT sum(amount) FROM public.payments WHERE store_id=p_store_id AND created_at>=start_at AND created_at<end_at),0),
  'refunds',COALESCE((SELECT sum(amount) FROM public.refunds WHERE store_id=p_store_id AND created_at>=start_at AND created_at<end_at),0),
  'paid_orders',(SELECT count(*) FROM public.payments WHERE store_id=p_store_id AND created_at>=start_at AND created_at<end_at));
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
  'can_report',public.authorize_action(p_org_id,p_store_id,'pos.report.read','pos'));
END $$;
REVOKE ALL ON FUNCTION public.shift_cash_balance(uuid),public.rpc_open_shift(uuid,uuid,uuid,bigint),public.rpc_close_shift(uuid,uuid,uuid,uuid,bigint),public.rpc_collect_payment(uuid,uuid,uuid,uuid,uuid,integer,text,bigint,boolean),public.rpc_void_order(uuid,uuid,uuid,integer,uuid,text),public.rpc_refund_payment(uuid,uuid,uuid,uuid,uuid,text),public.rpc_daily_report(uuid,uuid,date) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_open_shift(uuid,uuid,uuid,bigint),public.rpc_close_shift(uuid,uuid,uuid,uuid,bigint),public.rpc_collect_payment(uuid,uuid,uuid,uuid,uuid,integer,text,bigint,boolean),public.rpc_void_order(uuid,uuid,uuid,integer,uuid,text),public.rpc_refund_payment(uuid,uuid,uuid,uuid,uuid,text),public.rpc_daily_report(uuid,uuid,date) TO authenticated;
COMMIT;
