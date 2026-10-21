import { PGlite } from '@electric-sql/pglite';
import { readFile,readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';

test('offline review cancellation protects cash, idempotency and tenant boundaries',async t=>{
 const db=new PGlite(),owner=randomUUID(),cashier=randomUUID(),other=randomUUID();
 try{
  await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE SCHEMA auth;
   CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,email_confirmed_at timestamptz);
   CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
   GRANT USAGE ON SCHEMA auth TO authenticated; GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;`);
  for(const name of (await readdir('supabase/migrations')).filter(f=>f.endsWith('.sql')).sort())await db.exec((await readFile('supabase/migrations/'+name,'utf8')).replace(/CREATE EXTENSION IF NOT EXISTS "pgcrypto";/,''));
  await db.query('INSERT INTO auth.users VALUES($1,$2,now()),($3,$4,now())',[owner,'manager@example.test',other,'other@example.test']);
  const actor=async id=>{await db.exec('RESET ROLE');await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id]);await db.exec('SET ROLE authenticated');};
  const boot=async(id,name)=>{await actor(id);return(await db.query('SELECT public.rpc_bootstrap_workspace($1,$2,$3,$4) AS data',[name,name,'Main','Test street'])).rows[0].data;};
  const store=await boot(owner,'review-cafe');await boot(other,'other-cafe');
  await db.exec('RESET ROLE');
  await db.query('INSERT INTO public.profiles(id,email,full_name) VALUES($1,$2,$3)',[cashier,'cashier@example.test','Thu ngân']);
  const membership=(await db.query("INSERT INTO public.memberships(organization_id,user_id,scope_type) VALUES($1,$2,'ORG_WIDE') RETURNING id",[store.organization_id,cashier])).rows[0].id;
  const role=(await db.query("INSERT INTO public.roles(organization_id,code,name,scope_level) VALUES($1,'CASHIER_TEST','Cashier','ORG_WIDE') RETURNING id",[store.organization_id])).rows[0].id;
  await db.query('INSERT INTO public.user_roles(organization_id,membership_id,role_id,assigned_by) VALUES($1,$2,$3,$4)',[store.organization_id,membership,role,owner]);
  await db.query("INSERT INTO public.role_permissions(organization_id,role_id,permission_id) SELECT $1,$2,id FROM public.permissions WHERE permission_key IN ('pos.order.write','pos.payment.collect','pos.shift.manage')",[store.organization_id,role]);
  await actor(owner);
  const product=(await db.query('SELECT public.rpc_create_product($1,$2,$3) AS id',[store.organization_id,store.store_id,{name:'Cà phê',variants:[{name:'M',price:35000}]}])).rows[0].id;
  const variant=(await db.query('SELECT id FROM public.product_variants WHERE product_id=$1',[product])).rows[0].id;
  await actor(cashier);
  const cashShift=(await db.query('SELECT public.rpc_open_shift($1,$2,$3,$4) AS data',[store.organization_id,store.store_id,randomUUID(),100000])).rows[0].data.id;
  await db.query('SELECT public.rpc_close_shift($1,$2,$3,$4,$5)',[store.organization_id,store.store_id,cashShift,randomUUID(),100000]);
  await actor(owner);
  const payload=(cash=false)=>({p_channel:'TAKEAWAY',p_position_id:null,p_items:[{variant_id:variant,quantity:2}],p_customer:{name:'Khách'},p_expected_total:70000,
   p_shift_id:cash?cashShift:null,p_payment_operation_id:cash?randomUUID():null,p_received_amount:cash?100000:null});
  const rpc=async(name,args)=>{
   const placeholders=args.map((_,i)=>'$'+(i+3)).join(',');
   return(await db.query('SELECT public.'+name+'($1,$2,'+placeholders+') AS data',[store.organization_id,store.store_id,...args])).rows[0].data;
  };
  const submit=(op,request)=>rpc('rpc_submit_offline_review',[op,request,'Giá thay đổi, khách hủy đơn']);
  const sync=(op,r)=>rpc('rpc_sync_offline_sale',[op,r.p_channel,r.p_position_id,r.p_items,r.p_customer,r.p_expected_total,r.p_shift_id,r.p_payment_operation_id,r.p_received_amount]);
  const cancel=(id,op=randomUUID(),confirmed=false,reason='Khách đã nhận lại tiền')=>rpc('rpc_cancel_offline_review',[id,op,reason,confirmed]);
  const operation=randomUUID(),original=payload(true);let review,receipt;
  await t.test('cashier submits immutable request; submission retries keep one review',async()=>{
   await actor(cashier);review=await submit(operation,original);
   assert.equal((await submit(operation,original)).review_id,review.review_id);
   await assert.rejects(submit(operation,{...original,p_expected_total:1}),/IDEMPOTENCY_KEY_REUSED/);
   assert.equal((await db.query('SELECT * FROM public.offline_sale_reviews')).rows.length,1);
   const row=(await db.query('SELECT * FROM public.offline_sale_reviews')).rows[0];assert.equal(row.sender_name,'Thu ngân');assert.equal(row.item_labels[0].name,'Cà phê / M');
   await assert.rejects(db.query("UPDATE public.offline_sale_reviews SET status='CANCELLED'"),/permission denied/);
   await assert.rejects(cancel(review.review_id,randomUUID(),true),/PERMISSION_DENIED/);
  });
  await t.test('other tenant cannot inspect or resolve the review',async()=>{
   await actor(other);assert.equal((await db.query('SELECT * FROM public.offline_sale_reviews')).rows.length,0);
   await assert.rejects(cancel(review.review_id,randomUUID(),true),/PERMISSION_DENIED/);
  });
  const resolution=randomUUID();
  await t.test('manager must confirm net refund, not the gross customer tender',async()=>{
   await actor(owner);
   await assert.rejects(cancel(review.review_id,resolution,false),/CASH_REFUND_CONFIRMATION_REQUIRED/);
   receipt=await cancel(review.review_id,resolution,true);
   assert.equal(receipt.status,'CANCELLED');assert.equal(Number(receipt.cash_refund_amount),70000);
   assert.equal((await cancel(review.review_id,resolution,true)).review_id,review.review_id);
   await assert.rejects(cancel(review.review_id,randomUUID(),true),/REVIEW_ALREADY_RESOLVED/);
   for(const table of ['orders','payments','refunds'])assert.equal((await db.query('SELECT * FROM public.'+table)).rows.length,0);
  });
  await t.test('both sync and online-save retries cannot resurrect a cancelled operation',async()=>{
   await actor(cashier);assert.equal((await sync(operation,original)).status,'CANCELLED');
   const saved=await rpc('rpc_save_order',[operation,original.p_channel,null,original.p_items,original.p_customer,null,null]);
   assert.equal(saved.status,'CANCELLED');assert.equal((await db.query('SELECT * FROM public.orders')).rows.length,0);
   await assert.rejects(sync(operation,{...original,p_expected_total:1}),/IDEMPOTENCY_KEY_REUSED/);
   await db.exec('RESET ROLE');
   await db.query('DELETE FROM public.role_permissions WHERE role_id=$1',[role]);
   await actor(cashier);
   assert.equal((await sync(operation,original)).status,'CANCELLED','Original actor can receive cancellation after sales permission is revoked');
  });
  await t.test('review history and source payload remain immutable',async()=>{
   await db.exec('RESET ROLE');
   await assert.rejects(db.query("UPDATE public.offline_sale_reviews SET note='changed' WHERE id=$1",[review.review_id]),/IMMUTABLE_LEDGER/);
   await assert.rejects(db.query('DELETE FROM public.offline_sale_reviews WHERE id=$1',[review.review_id]),/IMMUTABLE_LEDGER/);
   await actor(owner);
   assert.equal((await db.query("SELECT * FROM public.audit_logs WHERE action_key='pos.offline.review_cancelled'")).rows.length,1);
  });
  await t.test('review submission freezes both entry points before any physical refund',async()=>{
   const op=randomUUID(),request=payload();const opened=await submit(op,request);
   await assert.rejects(sync(op,request),/OFFLINE_REVIEW_REQUIRED/);
   const held=await rpc('rpc_save_order',[op,request.p_channel,null,request.p_items,request.p_customer,null,null]);
   assert.equal(held.status,'REVIEW_REQUIRED');assert.equal(held.review_id,opened.review_id);
   assert.equal((await db.query('SELECT * FROM public.orders')).rows.length,0);
   await cancel(opened.review_id);
  });
  await t.test('already committed original sync returns its receipt without allowing cancellation',async()=>{
   const op=randomUUID(),request=payload();const synced=await sync(op,request);
   const completed=await submit(op,request);
   assert.equal(completed.status,'SYNCED');assert.equal(completed.result.order_id,synced.order_id);
   assert.equal((await db.query('SELECT * FROM public.offline_sale_reviews WHERE operation_id=$1',[op])).rows.length,0);
  });
  await t.test('a lost online response is detected instead of cancelling an existing order',async()=>{
   const op=randomUUID(),request=payload();
   await rpc('rpc_save_order',[op,request.p_channel,null,request.p_items,request.p_customer,null,null]);
   await assert.rejects(submit(op,request),/ONLINE_ORDER_EXISTS/);
  });
  await t.test('unpaid request cancellation needs a reason and retains a zero-refund receipt',async()=>{
   const op=randomUUID(),request=payload();const opened=await submit(op,request);
   await assert.rejects(cancel(opened.review_id,randomUUID(),false,''),/REASON_REQUIRED/);
   assert.equal(Number((await cancel(opened.review_id)).cash_refund_amount),0);
  });
 }finally{await db.close();}
});
