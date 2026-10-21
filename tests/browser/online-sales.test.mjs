import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

for(const width of [390,1280]) test(`online sales UI at ${width}px`,{timeout:90000},async()=>{
 const root=path.resolve('public');
 const server=createServer(async(req,res)=>{
  const file=path.resolve(root,'.'+new URL(req.url,'http://local').pathname);
  if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}
  try{const data=await readFile(file);res.setHeader('Content-Type',file.endsWith('.mjs')||file.endsWith('.js')?'application/javascript':file.endsWith('.html')?'text/html':'application/octet-stream');res.end(data);}catch{res.writeHead(404).end();}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true});
 try{
  const page=await browser.newPage({viewport:{width,height:900}});
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  page.on('console',m=>{if(m.type()==='error')console.error('browser console:',m.text());});
  page.on('requestfailed',r=>console.error('request failed:',r.url(),r.failure()?.errorText));
  const user='11111111-1111-4111-8111-111111111111',org='22222222-2222-4222-8222-222222222222',store='33333333-3333-4333-8333-333333333333';
  const product={id:'44444444-4444-4444-8444-444444444444',name:'Cà phê sữa',category:'Cà phê',active:true};
  const variant={id:'55555555-5555-4555-8555-555555555555',product_id:product.id,name:'M',price:35000,active:true};
  let orders=[],lines=[],shifts=[],payments=[],refunds=[];let paymentCalls=0,offlineCalls=0,failSave=false;
  await page.route('**/app-config.js',r=>r.fulfill({contentType:'application/javascript',body:"window.MODULAR_POS_CONFIG={url:'https://test.supabase.co',key:'public-key'};"}));
  await page.route('https://test.supabase.co/**',async route=>{
   const request=route.request(),url=new URL(request.url());
   const headers={'access-control-allow-origin':'*','access-control-allow-headers':'authorization,apikey,content-type','access-control-allow-methods':'GET,POST,OPTIONS'};
   if(request.method()==='OPTIONS'){await route.fulfill({status:204,headers});return;}
   const body=request.postDataJSON();let data=[];
   if(url.pathname.includes('/token'))data={access_token:'test-token',user:{id:user,email:'owner@example.test'}};
   else if(url.pathname.endsWith('/organizations'))data=[{id:org,name:'Cafe'}];
   else if(url.pathname.endsWith('/stores'))data=[{id:store,organization_id:org,name:'Quán kiểm thử',code:'MAIN',timezone:'Asia/Ho_Chi_Minh'}];
   else if(url.pathname.endsWith('/rpc/rpc_store_context'))data={can_manage_catalog:true,can_sell:true,can_manage_shift:true,can_collect:true,can_void:true,can_refund:true,can_report:true};
   else if(url.pathname.endsWith('/rpc/rpc_open_shift')){shifts=[{id:'66666666-6666-4666-8666-666666666666',opened_by:user,opening_amount:body.p_opening_amount,closed_at:null}];data=shifts[0];}
   else if(url.pathname.endsWith('/rpc/rpc_save_order')){
    if(failSave==='server'){await route.fulfill({status:500,contentType:'application/json',headers,body:JSON.stringify({message:'Temporary failure'})});return;}
    if(failSave){await route.abort('internetdisconnected');return;}
    assert.equal(body.p_items[0].variant_id,variant.id);
    assert.equal(body.p_items[0].price,undefined);
    const order={id:'77777777-7777-4777-8777-777777777777',revision:1,order_status:'OPEN',channel:body.p_channel,customer:body.p_customer,total_amount:70000};orders=[order];
    lines=[{order_id:order.id,variant_id:variant.id,product_name:product.name,variant_name:variant.name,quantity:2,unit_amount:35000,modifier_snapshot:[]}];
    data={order_id:order.id,revision:1,total_amount:70000,status:'OPEN'};
   }else if(url.pathname.endsWith('/rpc/rpc_sync_offline_sale')){
    offlineCalls++;assert.equal(body.p_expected_total,70000);
    data={order_id:'99999999-9999-4999-8999-999999999999',operation_id:body.p_operation_id,status:body.p_received_amount===null?'OPEN':'PAID'};
   }else if(url.pathname.endsWith('/rpc/rpc_collect_payment')){
    paymentCalls++;assert.equal(body.p_received_amount,100000);assert.equal(body.p_shift_id,shifts[0].id);
    data={id:'88888888-8888-4888-8888-888888888888',order_id:orders[0].id,method:'CASH',amount:70000,received_amount:100000,change_amount:30000};payments=[data];orders=[];
   }else if(url.pathname.endsWith('/products'))data=[product];
   else if(url.pathname.endsWith('/product_variants'))data=[variant];
   else if(url.pathname.endsWith('/product_modifiers'))data=[];
   else if(url.pathname.endsWith('/service_positions'))data=[];
   else if(url.pathname.endsWith('/orders'))data=orders;
   else if(url.pathname.endsWith('/order_items'))data=lines;
   else if(url.pathname.endsWith('/cash_shifts'))data=shifts;
   else if(url.pathname.endsWith('/payments'))data=payments;
   else if(url.pathname.endsWith('/refunds'))data=refunds;
   await route.fulfill({contentType:'application/json',headers,body:JSON.stringify(data)});
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/account.html`);
  await page.locator('#email').fill('owner@example.test');await page.locator('#password').fill('correct-password');
  await page.locator('#loginForm button[type=submit]').click();
  try { await page.locator('#salesPanel').waitFor({state:'visible',timeout:15000}); }
  catch(error){ throw new Error(JSON.stringify({phase:'workspace loading',errors,status:await page.locator('#status').textContent(),salesStatus:await page.locator('#salesStatus').textContent()})+' '+error.message); }
  await page.locator('#openingCash').fill('100000');await page.locator('#openShiftForm button').click();
  await page.waitForFunction(()=>document.getElementById('shiftSummary').textContent.includes('66666666'));
  await page.locator('#itemQuantity').fill('2');await page.locator('#addItem').click();
  await page.locator('#saveOrder').click();
  await page.locator('#paymentForm').waitFor({state:'visible'});
  // Unsaved cart edits must not be collected as if they were persisted.
  await page.locator('#customerName').fill('Khách A');
  assert.equal(await page.locator('#paymentForm').isVisible(),false);
  await page.locator('#customerName').fill('');
  await page.locator('#openOrders button').first().click();
  await page.locator('#paymentForm').waitFor({state:'visible'});
  await page.locator('#receivedAmount').fill('100000');await page.locator('#paymentForm button').click();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Đơn đã hoàn tất'));
  assert.equal(paymentCalls,1);
  assert.equal(await page.locator('#paymentForm').isVisible(),false);
  await page.locator('#offlineCashForm').waitFor({state:'visible'});
  // A lost save response is durably queued with the original request ID.
  failSave='server';
  await page.locator('#addItem').click();await page.locator('#saveOrder').click();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Chưa xác nhận'));
  await page.locator('#offlineReceived').fill('100000');
  await page.locator('#offlineCashForm input[type=checkbox]').check();
  await page.locator('#offlineCashForm button').click();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Lần lưu online trước chưa rõ'));
  assert.equal(await page.locator('#outboxList li').count(),0,'Uncertain online save must not become a second cash intent');
  failSave=true;
  await page.locator('#saveOrder').click();
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('1 đơn'));
  failSave=false;
  await page.reload();
  await page.locator('#email').fill('owner@example.test');await page.locator('#password').fill('correct-password');
  await page.locator('#loginForm button[type=submit]').click();
  await page.locator('#salesPanel').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('1 đơn'));
  await page.locator('#outboxList').evaluate(node=>node.closest('details').open=true);
  await page.locator('#syncOutbox').click();
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('0 đơn'));
  assert.equal(offlineCalls,1);
  await page.locator('#syncOutbox').click();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Đã đồng bộ toàn bộ'));
  assert.equal(offlineCalls,1,'Already acknowledged UI requests are not resent');
  await page.locator('#addItem').click();
  await page.locator('#offlineReceived').fill('100000');
  await page.locator('#offlineCashForm input[type=checkbox]').check();
  await page.locator('#offlineCashForm button').click();
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('1 đơn'));
  await page.locator('#countedCash').fill('100000');await page.locator('#closeShiftForm button').click();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Còn đơn thu tiền tại máy'));
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No horizontal overflow');
  assert.deepEqual(errors,[]);
  await page.locator('#logout').click();
  await page.locator('#loginPanel').waitFor({state:'visible'});
  assert.equal(await page.locator('#salesPanel').isVisible(),false);
 }finally{await browser.close();await new Promise(r=>server.close(r));}
});
