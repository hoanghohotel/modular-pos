import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { AuthClient } from '../../public/assets/auth-client.mjs';

// Only ephemeral local Supabase. Credentials stay in memory and are never logged.
test('real Supabase Auth + PostgREST sales transaction', {timeout:90000}, async()=>{
 let config;
 try{config=JSON.parse(execFileSync('supabase',['status','-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe']}));}
 catch{throw new Error('Local Supabase status unavailable');}
 const url=config.API_URL??config.api_url;
 const key=config.ANON_KEY??config.anon_key;
 const service=config.SERVICE_ROLE_KEY??config.service_role_key;
 assert.ok(url&&key&&service,'Local Supabase test credentials are available');
 assert.ok(['localhost','127.0.0.1'].includes(new URL(url).hostname),'Refuse to seed a remote Supabase project');
 const makeClient=async()=>{
  const suffix=randomUUID().slice(0,8),email=`smoke-${suffix}@example.test`,password=randomUUID();
  const response=await fetch(`${url}/auth/v1/admin/users`,{method:'POST',headers:{apikey:service,Authorization:`Bearer ${service}`,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true})});
  assert.ok(response.ok,`Create local Auth fixture: HTTP ${response.status}`);
  const client=new AuthClient({url,key});await client.signIn(email,password);
  const workspace=await client.bootstrap({name:`Test ${suffix}`,slug:`test-${suffix}`,storeName:'Main',address:'123 Local Test'});
  return {client,workspace};
 };
 const {client:a,workspace:w}=await makeClient();
 const {client:b}=await makeClient();
 assert.equal((await a.organizations()).length,1);
 assert.equal((await b.organizations()).length,1);
 assert.equal((await a.stores())[0].id,w.store_id);
 const rpc=(name,args={})=>a.request(`/rest/v1/rpc/${name}`,{method:'POST',body:{p_org_id:w.organization_id,p_store_id:w.store_id,...args}});
 const productId=await rpc('rpc_create_product',{p_product:{name:'Cà phê API',variants:[{name:'M',price:35000}],modifiers:[]}});
 const variants=await a.request(`/rest/v1/product_variants?select=id&product_id=eq.${productId}`);
 assert.equal(variants.length,1);
 const saveArgs={p_operation_id:randomUUID(),p_channel:'TAKEAWAY',p_position_id:null,p_items:[{variant_id:variants[0].id,quantity:2,price:1}],p_customer:{},p_order_id:null,p_expected_revision:null};
 const order=await rpc('rpc_save_order',saveArgs);assert.equal(Number(order.total_amount),70000);
 const replay=await rpc('rpc_save_order',saveArgs);assert.equal(replay.order_id,order.order_id);
 assert.equal((await b.request(`/rest/v1/orders?select=id&id=eq.${order.order_id}`)).length,0);
 await assert.rejects(b.request('/rest/v1/rpc/rpc_save_order',{method:'POST',body:{p_org_id:w.organization_id,p_store_id:w.store_id,...saveArgs,p_operation_id:randomUUID()}}),/PERMISSION_DENIED/);
 const shift=await rpc('rpc_open_shift',{p_operation_id:randomUUID(),p_opening_amount:100000});
 const paymentArgs={p_order_id:order.order_id,p_shift_id:shift.id,p_operation_id:randomUUID(),p_expected_revision:order.revision,p_method:'CASH',p_received_amount:100000,p_transfer_confirmed:false};
 // Real concurrent HTTP requests must serialize to one payment and one replay.
 const [first,second]=await Promise.all([rpc('rpc_collect_payment',paymentArgs),rpc('rpc_collect_payment',paymentArgs)]);
 assert.equal(first.id,second.id);assert.equal(Number(first.change_amount),30000);
 const payments=await a.request(`/rest/v1/payments?select=id&order_id=eq.${order.order_id}`);assert.equal(payments.length,1);
 await assert.rejects(rpc('rpc_collect_payment',{...paymentArgs,p_operation_id:randomUUID()}),/ORDER_FINALIZED/);
 await rpc('rpc_refund_payment',{p_payment_id:first.id,p_shift_id:shift.id,p_operation_id:randomUUID(),p_reason:'Local integration refund'});
 // Offline import is atomic and safe under concurrent retries.
 const offline={p_operation_id:randomUUID(),p_channel:'TAKEAWAY',p_position_id:null,
  p_items:[{variant_id:variants[0].id,quantity:2}],p_customer:{},p_expected_total:70000,
  p_shift_id:shift.id,p_payment_operation_id:randomUUID(),p_received_amount:100000};
 const [imported,retried]=await Promise.all([rpc('rpc_sync_offline_sale',offline),rpc('rpc_sync_offline_sale',offline)]);
 assert.equal(imported.order_id,retried.order_id);
 assert.equal(imported.payment.id,retried.payment.id);
 assert.equal(imported.operation_id,offline.p_operation_id);
 assert.equal(imported.status,'PAID');
 assert.equal((await a.request(`/rest/v1/payments?select=id&order_id=eq.${imported.order_id}`)).length,1);
 await assert.rejects(rpc('rpc_sync_offline_sale',{...offline,p_expected_total:1}),/IDEMPOTENCY_KEY_REUSED/);
 await assert.rejects(b.request('/rest/v1/rpc/rpc_sync_offline_sale',{method:'POST',body:{...offline,p_org_id:w.organization_id,p_store_id:w.store_id}}),/PERMISSION_DENIED/);
 const countOrders=async()=>(await a.request(`/rest/v1/orders?select=id&store_id=eq.${w.store_id}`)).length;
 // Simulate a committed online save whose response was lost: importing the
 // same intent must acknowledge the existing order instead of creating another.
 const lost={...offline,p_operation_id:randomUUID(),p_shift_id:null,p_payment_operation_id:null,p_received_amount:null};
 const committed=await rpc('rpc_save_order',{p_operation_id:lost.p_operation_id,p_channel:lost.p_channel,p_position_id:null,p_items:lost.p_items,p_customer:lost.p_customer,p_order_id:null,p_expected_revision:null});
 const beforeRecovery=await countOrders();
 const recovered=await rpc('rpc_sync_offline_sale',lost);
 assert.equal(recovered.order_id,committed.order_id);
 assert.equal(await countOrders(),beforeRecovery);
 const count=await countOrders();
 const mismatch={...offline,p_operation_id:randomUUID(),p_payment_operation_id:randomUUID(),p_expected_total:1};
 await assert.rejects(rpc('rpc_sync_offline_sale',mismatch),/OFFLINE_PRICE_CONFLICT/);
 assert.equal(await countOrders(),count,'Price conflict rolls back the complete order');
 // Failed attempts leave no idempotency receipt behind: the same ID can succeed
 // after correcting a request that was never committed.
 await rpc('rpc_update_variant',{p_variant_id:variants[0].id,p_price:40000,p_active:true});
 await assert.rejects(rpc('rpc_sync_offline_sale',{...offline,p_operation_id:randomUUID(),p_payment_operation_id:randomUUID()}),/OFFLINE_PRICE_CONFLICT/);
 assert.equal(await countOrders(),count,'Changed catalog price leaves no partial order');
 await rpc('rpc_update_variant',{p_variant_id:variants[0].id,p_price:35000,p_active:true});
 const corrected=await rpc('rpc_sync_offline_sale',{...mismatch,p_expected_total:70000,p_shift_id:null,p_payment_operation_id:null,p_received_amount:null});
 assert.equal(corrected.status,'OPEN');
 await rpc('rpc_refund_payment',{p_payment_id:imported.payment.id,p_shift_id:shift.id,p_operation_id:randomUUID(),p_reason:'Offline test cash refund'});
 const closed=await rpc('rpc_close_shift',{p_shift_id:shift.id,p_operation_id:randomUUID(),p_counted_cash:100000});
 assert.equal(Number(closed.expected_cash),100000);assert.equal(Number(closed.difference),0);
 const replayClosed=await rpc('rpc_sync_offline_sale',offline);
 assert.equal(replayClosed.order_id,imported.order_id,'Committed replay survives shift closure');
 const afterClose=await countOrders();
 await assert.rejects(rpc('rpc_sync_offline_sale',{...offline,p_operation_id:randomUUID(),p_payment_operation_id:randomUUID()}),/OPEN_SHIFT_REQUIRED/);
 assert.equal(await countOrders(),afterClose,'Closed shift leaves no partial unpaid order');
 // A proposal freezes the original intent before any customer cash is returned.
 const reviewRequest={...offline,p_operation_id:undefined,p_expected_total:70000,p_payment_operation_id:randomUUID()};
 delete reviewRequest.p_operation_id;
 const reviewOperation=randomUUID();
 const reviewArgs={p_operation_id:reviewOperation,p_request:reviewRequest,p_note:'Khách hủy sau khi đối soát tiền mặt'};
 const review=await rpc('rpc_submit_offline_review',reviewArgs);
 assert.equal((await rpc('rpc_submit_offline_review',reviewArgs)).review_id,review.review_id);
 assert.equal((await b.request('/rest/v1/offline_sale_reviews?select=id')).length,0);
 await assert.rejects(b.request('/rest/v1/rpc/rpc_cancel_offline_review',{method:'POST',body:{p_org_id:w.organization_id,p_store_id:w.store_id,p_review_id:review.review_id,p_operation_id:randomUUID(),p_reason:'Other tenant cancellation',p_cash_refunded:true}}),/PERMISSION_DENIED/);
 await assert.rejects(rpc('rpc_sync_offline_sale',{...reviewRequest,p_operation_id:reviewOperation}),/OFFLINE_REVIEW_REQUIRED/);
 const held=await rpc('rpc_save_order',{p_operation_id:reviewOperation,p_channel:reviewRequest.p_channel,p_position_id:null,p_items:reviewRequest.p_items,p_customer:reviewRequest.p_customer,p_order_id:null,p_expected_revision:null});
 assert.equal(held.status,'REVIEW_REQUIRED');
 const cancelArgs={p_review_id:review.review_id,p_operation_id:randomUUID(),p_reason:'Khách đã nhận lại đủ tiền đơn',p_cash_refunded:true};
 await assert.rejects(rpc('rpc_cancel_offline_review',{...cancelArgs,p_cash_refunded:false}),/CASH_REFUND_CONFIRMATION_REQUIRED/);
 const beforeCancel=await countOrders();
 const [cancelled,cancelReplay]=await Promise.all([rpc('rpc_cancel_offline_review',cancelArgs),rpc('rpc_cancel_offline_review',cancelArgs)]);
 assert.equal(cancelled.review_id,cancelReplay.review_id);assert.equal(Number(cancelled.cash_refund_amount),70000);
 assert.equal((await rpc('rpc_sync_offline_sale',{...reviewRequest,p_operation_id:reviewOperation})).status,'CANCELLED');
 assert.equal((await rpc('rpc_save_order',{p_operation_id:reviewOperation,p_channel:reviewRequest.p_channel,p_position_id:null,p_items:reviewRequest.p_items,p_customer:reviewRequest.p_customer,p_order_id:null,p_expected_revision:null})).status,'CANCELLED');
 assert.equal(await countOrders(),beforeCancel,'Cancelling an unposted sale creates no phantom order');
 const audit=await a.request('/rest/v1/audit_logs?select=id&action_key=eq.pos.offline.review_cancelled&entity_id=eq.'+review.review_id);
 assert.equal(audit.length,1);
 // Racing a proposal against an unpaid sync either commits once or freezes once.
 const raceOperation=randomUUID(),raceRequest={...reviewRequest,p_shift_id:null,p_payment_operation_id:null,p_received_amount:null};
 const beforeRace=await countOrders();
 const [proposal,attempt]=await Promise.allSettled([
  rpc('rpc_submit_offline_review',{p_operation_id:raceOperation,p_request:raceRequest,p_note:'Concurrent cancellation proposal'}),
  rpc('rpc_sync_offline_sale',{...raceRequest,p_operation_id:raceOperation})
 ]);
 assert.equal(proposal.status,'fulfilled');
 if(proposal.value.status==='OPEN'){
  assert.equal(attempt.status,'rejected');assert.match(attempt.reason.message,/OFFLINE_REVIEW_REQUIRED/);
  assert.equal(await countOrders(),beforeRace);
 }else{
  assert.equal(proposal.value.status,'SYNCED');assert.equal(attempt.status,'fulfilled');
  assert.equal(proposal.value.result.order_id,attempt.value.order_id);assert.equal(await countOrders(),beforeRace+1);
 }
 await Promise.all([a.signOut(),b.signOut()]);
});
