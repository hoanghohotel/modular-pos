import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';

async function fixture() {
 const state={outage:0,user:'user-a',version:'v1',breakInstall:false,htmlError:false,sync:[]};
 const root=path.resolve('public');
 const server=createServer(async(req,res)=>{
  const pathname=new URL(req.url,'http://local').pathname;
  const json=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
  if(pathname.startsWith('/backend/')){
   let body='';for await(const chunk of req)body+=chunk;
   body=body?JSON.parse(body):{};
   if(pathname.includes('/token'))return json({access_token:'secret-session-token',user:{id:state.user,email:'owner@example.test'}});
   if(pathname.endsWith('/logout'))return json({});
   if(req.headers.authorization!=='Bearer secret-session-token')return json({message:'AUTH_REQUIRED'},401);
   if(pathname.endsWith('/organizations'))return json([{id:'org',name:'Cafe'}]);
   if(pathname.endsWith('/stores'))return json([{id:'store',organization_id:'org',name:'Cafe',code:'MAIN'}]);
   if(pathname.endsWith('/rpc_store_context'))return json({can_sell:true,can_manage_catalog:true,can_manage_shift:true,can_collect:true});
   if(state.outage&&state.htmlError){res.writeHead(state.outage,{'Content-Type':'text/html'}).end('<h1>Gateway unavailable</h1>');return;}
   if(state.outage)return json({code:'PGRST000',message:state.outage===403?'PERMISSION_DENIED':'Unavailable'},state.outage);
   if(pathname.endsWith('/products'))return json([{id:'coffee',name:'Cà phê',category:'Nước',active:true}]);
   if(pathname.endsWith('/product_variants'))return json([{id:'coffee-m',product_id:'coffee',name:'M',price:35000,active:true}]);
   if(pathname.endsWith('/rpc_sync_offline_sale')){state.sync.push(body);return json({order_id:'synced-order',operation_id:body.p_operation_id});}
   return json([]);
  }
  if(pathname==='/app-config.js'){
   res.setHeader('Content-Type','application/javascript');
   res.end(`window.MODULAR_POS_CONFIG=${JSON.stringify({url:`http://127.0.0.1:${server.address().port}/backend`,key:'public-key'})};`);return;
  }
  if(pathname==='/account.html'&&!state.breakInstall){res.writeHead(308,{Location:'/account'}).end();return;}
  const pages=['/','/pos','/admin','/account','/login','/account.html'];
  const file=path.resolve(root,'.'+(pages.includes(pathname)?'/account.html':pathname));
  if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return;}
  // Cache installation must fail as a whole if any shell asset cannot be fetched.
  if(state.breakInstall&&pathname==='/account.html'&&req.headers['sec-fetch-dest']!=='document'){res.writeHead(503).end();return;}
  try{
   let data=await readFile(file);
   if(pathname==='/sw.js')data=Buffer.from(data.toString().replace(/modular-pos-shell-[a-f0-9]+/,'modular-pos-shell-'+state.version));
   if(pages.includes(pathname))data=Buffer.from(data.toString().replace('<title>Tài khoản','<title>'+state.version+' Tài khoản'));
   res.setHeader('Content-Type',file.endsWith('.mjs')||file.endsWith('.js')?'application/javascript':'text/html');
   res.setHeader('Cache-Control','no-store');res.end(data);
  }catch{res.writeHead(404).end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch();
 const context=await browser.newContext({viewport:{width:390,height:844}});
 const page=await context.newPage();
 const origin=`http://127.0.0.1:${server.address().port}`;
 const login=async()=>{
  await page.locator('#email').fill('owner@example.test');
  await page.locator('#password').fill('correct-password');
  await page.locator('#loginForm button[type=submit]').click();
 };
 return {state,browser,context,page,origin,login,close:async()=>{await browser.close();await new Promise(r=>server.close(r));}};
}

test('cached shell reloads offline; catalog fallback is scoped and cannot bypass denied access',{timeout:90000},async()=>{
 const f=await fixture();const {page,context,state,origin,login}=f;
 const errors=[];page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(origin+'/pos');
  await page.waitForFunction(()=>navigator.serviceWorker.controller);
  await login();await page.locator('#salesPanel').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.getElementById('catalogStatus').textContent.startsWith('Đã tải menu'));
  // A fresh Auth/store-context check succeeds, but menu APIs fail during startup.
  state.outage=503;state.htmlError=true;
  await page.reload();await login();
  await page.locator('#salesPanel').waitFor({state:'visible'});
  assert.match(await page.locator('#catalogStatus').textContent(),/dữ liệu lưu tại máy/);
  assert.match(await page.locator('#productChoice').textContent(),/Cà phê/);
  assert.equal(await page.locator('#financeArea').isVisible(),false);
  await page.locator('#addItem').click();await page.locator('#queueOrder').click();
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('1 đơn'));
  await page.locator('#outboxList summary').click();
  assert.match(await page.locator('#outboxList').textContent(),/Cà phê \/ M × 1/);
  const snapshots=await page.evaluate(async()=>{
   const {OfflineStore}=await import('/assets/offline-store.mjs');
   const q=new OfflineStore({url:location.origin+'/backend',userId:'user-a',organizationId:'org',storeId:'store'});
   return {snapshot:await q.cached(),records:await q.list()};
  });
  assert.equal(snapshots.snapshot.products[0].id,'coffee');
  assert.equal(JSON.stringify(snapshots).includes('secret-session-token'),false);
  const localId=snapshots.records[0].operationId;
  const cachedUrls=await page.evaluate(async()=>{
   const result=[];for(const key of await caches.keys())for(const request of await (await caches.open(key)).keys())result.push(request.url);return result;
  });
  assert.equal(cachedUrls.some(url=>url.includes('/backend/')),false,'API/Auth/customer responses never enter the shell cache');
  await context.setOffline(true);await page.reload();
  await page.locator('#loginPanel').waitFor({state:'visible'});
  assert.equal(await page.locator('#salesPanel').isVisible(),false,'Offline reload does not restore an authenticated session');
  assert.match(await page.locator('#connectionStatus').textContent(),/Đang mất mạng/);
  assert.match(await page.title(),/v1/);
  await context.setOffline(false);state.outage=403;state.htmlError=false;
  await login();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('chưa được cấp quyền'));
  assert.equal(await page.locator('#salesPanel').isVisible(),false,'Denied access cannot fall back to a cached catalog');
  // Reload starts a fresh online session; replay retains the original queued ID.
  state.outage=0;await page.reload();await login();
  await page.locator('#salesPanel').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('1 đơn'));
  await page.locator('#syncOutbox').click();
  await page.waitForFunction(()=>document.getElementById('outboxSummary').textContent.startsWith('0 đơn'));
  assert.equal(state.sync.length,1);assert.equal(state.sync[0].p_operation_id,localId);
  assert.equal(state.sync[0].display,undefined,'Display snapshots are not sent to the RPC');
  await page.locator('#logout').click();await page.locator('#loginPanel').waitFor({state:'visible'});
  state.user='user-b';state.outage=503;await login();
  await page.waitForFunction(()=>document.getElementById('salesStatus').textContent.includes('Chưa xác nhận'));
  assert.equal(await page.locator('#salesPanel').isVisible(),false,'Another user cannot recover the previous user catalog');
  assert.deepEqual(errors,[]);
 }finally{await f.close();}
});

test('shell update waits for open tabs and failed installs leave no partial cache',{timeout:90000},async()=>{
 const f=await fixture();const {page,state,origin,context}=f;
 try{
  state.breakInstall=true;await page.goto(origin+'/pos');
  await page.waitForFunction(()=>document.getElementById('offlineReady').textContent.includes('Chưa lưu được'));
  assert.equal(await page.evaluate(async()=>(await caches.keys()).filter(key=>key.startsWith('modular-pos-shell-')).length),0);
  state.breakInstall=false;
  await page.reload();
  // Reload retries registration after the failed installation.
  await page.waitForFunction(()=>navigator.serviceWorker.controller);
  state.version='v2';
  await page.evaluate(async()=>{const registration=await navigator.serviceWorker.getRegistration();await registration.update();});
  await page.waitForFunction(async()=>Boolean((await navigator.serviceWorker.getRegistration()).waiting));
  assert.match(await page.title(),/v1/);
  await page.reload();assert.match(await page.title(),/v1/,'Existing tabs retain a consistent shell version');
  await page.close();
  const next=await context.newPage();await next.goto(origin+'/pos');
  await next.waitForFunction(()=>navigator.serviceWorker.controller);
  await next.reload();assert.match(await next.title(),/v2/);
  const keys=await next.evaluate(()=>caches.keys());
  assert.deepEqual(keys.filter(key=>key.startsWith('modular-pos-shell-')),['modular-pos-shell-v2']);
 }finally{await f.close();}
});
