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
 const closed=await rpc('rpc_close_shift',{p_shift_id:shift.id,p_operation_id:randomUUID(),p_counted_cash:100000});
 assert.equal(Number(closed.expected_cash),100000);assert.equal(Number(closed.difference),0);
 await Promise.all([a.signOut(),b.signOut()]);
});
