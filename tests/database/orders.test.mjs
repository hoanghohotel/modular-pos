import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';

test('online orders use persisted catalog, tenant authorization and idempotency',async t=>{
 const db=new PGlite();
 const uid=randomUUID(),otherUid=randomUUID(),cashier=randomUUID();
 try {
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
   CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);
   CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;`);
  for(const f of (await readdir('supabase/migrations')).filter(f=>f.endsWith('.sql')).sort())await db.exec((await readFile(`supabase/migrations/${f}`,'utf8')).replace(/CREATE EXTENSION IF NOT EXISTS "pgcrypto";/,''));
  await db.query('INSERT INTO auth.users VALUES($1,$2,now()),($3,$4,now())',[uid,'owner@example.test',otherUid,'other@example.test']);
  const actor=async id=>{await db.exec('RESET ROLE');await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('SET ROLE authenticated');};
  const boot=async(id,slug)=>{await actor(id);return(await db.query('SELECT public.rpc_bootstrap_workspace($1,$2,$3,$4) AS data',[slug,slug,'Main','Test address'])).rows[0].data;};
  const a=await boot(uid,'cafe-a'), b=await boot(otherUid,'cafe-b');
  await actor(uid);
  const product={name:'Cà phê sữa',category:'Cà phê',variants:[{name:'M',price:35000},{name:'L',price:45000}],modifiers:[{name:'Thêm sữa',price:5000}]};
  const pid=(await db.query('SELECT public.rpc_create_product($1,$2,$3) AS id',[a.organization_id,a.store_id,product])).rows[0].id;
  const variants=(await db.query('SELECT * FROM public.product_variants ORDER BY price')).rows;
  const modifier=(await db.query('SELECT * FROM public.product_modifiers')).rows[0];
  const position=(await db.query("SELECT public.rpc_create_position($1,$2,'Bàn 01') AS id",[a.organization_id,a.store_id])).rows[0].id;
  const save=async({operation=randomUUID(),items=[{variant_id:variants[0].id,quantity:2,modifier_ids:[modifier.id]}],channel='TAKEAWAY',table=null,customer={},order=null,revision=null}={})=>(await db.query('SELECT public.rpc_save_order($1,$2,$3,$4,$5,$6,$7,$8,$9) AS data',[a.organization_id,a.store_id,operation,channel,table,items,customer,order,revision])).rows[0].data;
  let created;
  const operation=randomUUID();
  await t.test('server ignores forged prices and persists a correct snapshot',async()=>{
   created=await save({operation,items:[{variant_id:variants[0].id,quantity:2,modifier_ids:[modifier.id],price:1,total_amount:1}]});
   assert.equal(Number(created.total_amount),80000);
   const line=(await db.query('SELECT * FROM public.order_items WHERE order_id=$1',[created.order_id])).rows[0];
   assert.equal(Number(line.unit_amount),40000);assert.equal(line.product_name,product.name);assert.equal(line.modifier_snapshot[0].name,'Thêm sữa');
  });
  await t.test('identical retry returns the same order; changed payload is rejected',async()=>{
   const replay=await save({operation,items:[{variant_id:variants[0].id,quantity:2,modifier_ids:[modifier.id],price:1,total_amount:1}]});
   assert.equal(replay.order_id,created.order_id);assert.equal(replay.replayed,true);
   await assert.rejects(save({operation}),/IDEMPOTENCY_KEY_REUSED/);
   assert.equal((await db.query('SELECT id FROM public.orders')).rows.length,1);
  });
  await t.test('one table has at most one open order',async()=>{
   await save({channel:'DINE_IN',table:position});
   await assert.rejects(save({channel:'DINE_IN',table:position}),/unique constraint/);
  });
  await t.test('stale order edits cannot overwrite a newer version',async()=>{
   const updated=await save({order:created.order_id,revision:1,items:[{variant_id:variants[0].id,quantity:1}]});
   assert.equal(updated.revision,2);
   await assert.rejects(save({order:created.order_id,revision:1}),/VERSION_CONFLICT/);
  });
  await t.test('invalid line rolls back replacement of an existing order',async()=>{
   await assert.rejects(save({order:created.order_id,revision:2,items:[{variant_id:variants[0].id,quantity:0}]}),/INVALID_QUANTITY/);
   const row=(await db.query('SELECT revision,total_amount FROM public.orders WHERE id=$1',[created.order_id])).rows[0];
   assert.equal(row.revision,2);assert.equal(Number(row.total_amount),35000);
   assert.equal((await db.query('SELECT id FROM public.order_items WHERE order_id=$1',[created.order_id])).rows.length,1);
  });
  await t.test('duplicate and foreign-product modifiers are rejected',async()=>{
   await assert.rejects(save({items:[{variant_id:variants[0].id,quantity:1,modifier_ids:[modifier.id,modifier.id]}]}),/DUPLICATE_MODIFIER/);
   const other=(await db.query('SELECT public.rpc_create_product($1,$2,$3) AS id',[a.organization_id,a.store_id,{name:'Trà',variants:[{name:'M',price:25000}],modifiers:[{name:'Trân châu',price:6000}]}])).rows[0].id;
   const bad=(await db.query('SELECT id FROM public.product_modifiers WHERE product_id=$1',[other])).rows[0].id;
   await assert.rejects(save({items:[{variant_id:variants[0].id,quantity:1,modifier_ids:[bad]}]}),/MODIFIER_UNAVAILABLE/);
  });
  await t.test('delivery requires contact/address; prices must be integer VND',async()=>{
   await assert.rejects(save({channel:'DELIVERY'}),/DELIVERY_DETAILS_REQUIRED/);
   await save({channel:'DELIVERY',customer:{phone:'0901234567',address:'123 Test Street'}});
   await assert.rejects(db.query('SELECT public.rpc_create_product($1,$2,$3)',[a.organization_id,a.store_id,{name:'Invalid',variants:[{name:'M',price:0.5}]}]),/INVALID_PRICE/);
  });
  await t.test('price changes never rewrite already-saved line snapshots',async()=>{
   await db.query('SELECT public.rpc_update_variant($1,$2,$3,$4,$5)',[a.organization_id,a.store_id,variants[0].id,39000,true]);
   assert.equal(Number((await db.query('SELECT unit_amount FROM public.order_items WHERE order_id=$1',[created.order_id])).rows[0].unit_amount),35000);
  });
  await t.test('unavailable variants and nonexistent tables cannot be ordered',async()=>{
   await db.query('SELECT public.rpc_update_variant($1,$2,$3,$4,$5)',[a.organization_id,a.store_id,variants[0].id,39000,false]);
   await assert.rejects(save(),/VARIANT_UNAVAILABLE/);
   await assert.rejects(save({channel:'DINE_IN',table:randomUUID()}),/POSITION_NOT_FOUND/);
  });
  await t.test('other tenant cannot read or mutate this store',async()=>{
   await actor(otherUid);
   assert.equal((await db.query('SELECT id FROM public.orders')).rows.length,0);
   assert.equal((await db.query('SELECT id FROM public.products WHERE id=$1',[pid])).rows.length,0);
   await assert.rejects(save(),/PERMISSION_DENIED/);
   await assert.rejects(db.query('SELECT public.rpc_create_product($1,$2,$3)',[a.organization_id,a.store_id,product]),/PERMISSION_DENIED/);
   await actor(uid);
   await assert.rejects(db.query('SELECT public.rpc_create_position($1,$2,$3)',[b.organization_id,b.store_id,'Bad']),/PERMISSION_DENIED/);
  });
  await t.test('store access alone does not permit catalog changes or sales',async()=>{
   await db.exec('RESET ROLE');
   await db.query('INSERT INTO public.profiles(id,email,full_name) VALUES($1,$2,$3)',[cashier,'viewer@example.test','Viewer']);
   await db.query("INSERT INTO public.memberships(organization_id,user_id,scope_type) VALUES($1,$2,'ORG_WIDE')",[a.organization_id,cashier]);
   await actor(cashier);
   const context=(await db.query('SELECT public.rpc_store_context($1,$2) AS data',[a.organization_id,a.store_id])).rows[0].data;
   assert.equal(context.can_sell,false);assert.equal(context.can_manage_catalog,false);
   await assert.rejects(save(),/PERMISSION_DENIED/);
  });

  await actor(uid);
  await db.query('SELECT public.rpc_update_variant($1,$2,$3,$4,$5)',[a.organization_id,a.store_id,variants[0].id,35000,true]);
  let shift,payment,paidOrder;
  const pay=(order,shiftId,operation=randomUUID(),method='CASH',received=100000,confirmed=false)=>db.query('SELECT public.rpc_collect_payment($1,$2,$3,$4,$5,$6,$7,$8,$9) AS data',[a.organization_id,a.store_id,order.order_id,shiftId,operation,order.revision,method,received,confirmed]).then(r=>r.rows[0].data);
  await t.test('collecting requires an open cashier shift',async()=>{
   paidOrder=await save({channel:'DINE_IN',table:(await db.query("SELECT public.rpc_create_position($1,$2,'Bàn 02') AS id",[a.organization_id,a.store_id])).rows[0].id});
   await assert.rejects(pay(paidOrder,randomUUID()),/OPEN_SHIFT_REQUIRED/);
  });
  const shiftOp=randomUUID();
  await t.test('opening shift is idempotent and only one can be open per cashier',async()=>{
   const args=[a.organization_id,a.store_id,shiftOp,100000];
   shift=(await db.query('SELECT public.rpc_open_shift($1,$2,$3,$4) AS data',args)).rows[0].data;
   assert.equal((await db.query('SELECT public.rpc_open_shift($1,$2,$3,$4) AS data',args)).rows[0].data.id,shift.id);
   await assert.rejects(db.query('SELECT public.rpc_open_shift($1,$2,$3,$4)',[a.organization_id,a.store_id,randomUUID(),0]),/unique constraint/);
  });
  await t.test('underpayment and unconfirmed transfer cannot finalize orders',async()=>{
   await assert.rejects(pay(paidOrder,shift.id,randomUUID(),'CASH',1),/INSUFFICIENT_PAYMENT/);
   await assert.rejects(pay(paidOrder,shift.id,randomUUID(),'TRANSFER',80000,false),/TRANSFER_CONFIRMATION_REQUIRED/);
   assert.equal((await db.query('SELECT order_status FROM public.orders WHERE id=$1',[paidOrder.order_id])).rows[0].order_status,'OPEN');
  });
  const paymentOp=randomUUID();
  await t.test('cash collection records change, finalizes once and releases table',async()=>{
   payment=await pay(paidOrder,shift.id,paymentOp);
   assert.equal(Number(payment.amount),80000);assert.equal(Number(payment.change_amount),20000);
   const replay=await pay(paidOrder,shift.id,paymentOp);assert.equal(replay.id,payment.id);
   await assert.rejects(pay(paidOrder,shift.id),/ORDER_FINALIZED/);
   await assert.rejects(save({order:paidOrder.order_id,revision:1}),/ORDER_FINALIZED/);
   const table=(await db.query('SELECT position_id FROM public.orders WHERE id=$1',[paidOrder.order_id])).rows[0].position_id;
   await save({channel:'DINE_IN',table});
  });
  await t.test('payment records are immutable, including for database owner',async()=>{
   await db.exec('RESET ROLE');
   await assert.rejects(db.query('UPDATE public.payments SET amount=1 WHERE id=$1',[payment.id]),/IMMUTABLE_LEDGER_VIOLATION/);
   await actor(uid);
  });
  await t.test('full refund requires a reason, is idempotent and does not delete payment',async()=>{
   const op=randomUUID();
   await assert.rejects(db.query('SELECT public.rpc_refund_payment($1,$2,$3,$4,$5,$6)',[a.organization_id,a.store_id,payment.id,shift.id,op,'']),/REASON_REQUIRED/);
   const args=[a.organization_id,a.store_id,payment.id,shift.id,op,'Khách trả toàn bộ đơn'];
   const refunded=(await db.query('SELECT public.rpc_refund_payment($1,$2,$3,$4,$5,$6) AS data',args)).rows[0].data;
   assert.equal(Number(refunded.amount),80000);
   assert.equal((await db.query('SELECT public.rpc_refund_payment($1,$2,$3,$4,$5,$6) AS data',args)).rows[0].data.id,refunded.id);
   await assert.rejects(db.query('SELECT public.rpc_refund_payment($1,$2,$3,$4,$5,$6)',[a.organization_id,a.store_id,payment.id,shift.id,randomUUID(),'Hoàn lại lần hai']),/ORDER_FINALIZED/);
   assert.equal((await db.query('SELECT id FROM public.payments WHERE id=$1',[payment.id])).rows.length,1);
  });
  await t.test('voiding a saved open order requires reason and revision',async()=>{
   const o=await save();const op=randomUUID();
   await assert.rejects(db.query('SELECT public.rpc_void_order($1,$2,$3,$4,$5,$6)',[a.organization_id,a.store_id,o.order_id,0,op,'Khách hủy đơn']),/VERSION_CONFLICT/);
   const args=[a.organization_id,a.store_id,o.order_id,o.revision,op,'Khách hủy đơn'];
   const result=(await db.query('SELECT public.rpc_void_order($1,$2,$3,$4,$5,$6) AS data',args)).rows[0].data;
   assert.equal(result.order_status,'VOID');
   assert.equal((await db.query('SELECT public.rpc_void_order($1,$2,$3,$4,$5,$6) AS data',args)).rows[0].data.id,result.id);
  });
  await t.test('closing shift persists expected/count/difference and blocks further collection',async()=>{
   const op=randomUUID();
   await assert.rejects(db.query('SELECT public.rpc_close_shift($1,$2,$3,$4,$5)',[a.organization_id,a.store_id,shift.id,op,null]),/INVALID_CASH_COUNT/);
   const args=[a.organization_id,a.store_id,shift.id,op,99000];
   const closed=(await db.query('SELECT public.rpc_close_shift($1,$2,$3,$4,$5) AS data',args)).rows[0].data;
   assert.equal(Number(closed.expected_cash),100000);assert.equal(Number(closed.difference),-1000);
   assert.equal((await db.query('SELECT public.rpc_close_shift($1,$2,$3,$4,$5) AS data',args)).rows[0].data.id,shift.id);
   await assert.rejects(pay(await save(),shift.id),/OPEN_SHIFT_REQUIRED/);
  });
  await t.test('daily report uses store timezone and distinguishes gross/refunds',async()=>{
   const report=(await db.query("SELECT public.rpc_daily_report($1,$2,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) AS data",[a.organization_id,a.store_id])).rows[0].data;
   assert.equal(Number(report.gross),80000);assert.equal(Number(report.refunds),80000);assert.equal(Number(report.paid_orders),1);assert.equal(report.timezone,'Asia/Ho_Chi_Minh');
   await actor(otherUid);
   await assert.rejects(db.query('SELECT public.rpc_daily_report($1,$2,current_date)',[a.organization_id,a.store_id]),/PERMISSION_DENIED/);
  });
 } finally{await db.close();}
});
