import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { chromium } from 'playwright';

test('IndexedDB outbox persists, isolates users and requires matching acknowledgement',{timeout:90000},async()=>{
 const server=createServer(async(req,res)=>{
  if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><title>Offline test</title>');return;}
  if(req.url!=='/offline-store.mjs'){res.writeHead(404).end();return;}
  res.setHeader('Content-Type','application/javascript');
  res.end(await readFile('public/assets/offline-store.mjs'));
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch();
 try{
  const page=await browser.newPage();
  await page.goto('http://127.0.0.1:'+server.address().port+'/');
  const setup=async()=>page.evaluate(async()=>{
   const {OfflineStore}=await import('/offline-store.mjs');
   window.queue=new OfflineStore({url:'https://example.test',userId:'a',organizationId:'org',storeId:'store'});
   window.OtherStore=OfflineStore;
  });
  await setup();
  await page.evaluate(()=>queue.enqueue({total:70000},'stable-id'));
  await page.reload();await setup();
  assert.equal(await page.evaluate(async()=>(await queue.list()).length),1);
  assert.equal(await page.evaluate(async()=>(await new OtherStore({url:'https://example.test',userId:'b',organizationId:'org',storeId:'store'}).list()).length),0);
  assert.equal(await page.evaluate(async()=>{
   try{await queue.enqueue({total:1},'stable-id');return false;}catch{return true;}
  }),true,'An operation cannot silently change its payload');
  await page.evaluate(()=>queue.flush(async()=>{throw new TypeError('Failed to fetch');}));
  assert.equal(await page.evaluate(async()=>(await queue.list())[0].status),'PENDING');
  await page.evaluate(()=>queue.flush(async()=>({order_id:'order',operation_id:'wrong-id'})));
  assert.equal(await page.evaluate(async()=>(await queue.list())[0].status),'PENDING');
  await page.evaluate(()=>queue.flush(async()=>{throw new Error('OFFLINE_PRICE_CONFLICT');}));
  assert.equal(await page.evaluate(async()=>(await queue.list())[0].status),'CONFLICT');
  assert.equal(await page.evaluate(async()=>{
   let calls=0;await queue.flush(async()=>{calls++;});return calls;
  }),0,'Conflicts require explicit retry');
  await page.evaluate(()=>queue.flush(async(payload,id)=>({order_id:'order',operation_id:id}),{retryConflicts:true}));
  assert.equal(await page.evaluate(async()=>(await queue.list())[0].status),'ACKNOWLEDGED');
  assert.equal(await page.evaluate(async()=>(await queue.enqueue({total:70000},'stable-id')).status),'ACKNOWLEDGED','Re-enqueue preserves committed state');
  assert.equal(await page.evaluate(async()=>{
   let calls=0;await queue.flush(async()=>{calls++;});return calls;
  }),0,'Acknowledged operations are not sent again');
  await page.evaluate(async()=>queue.update((await queue.list())[0],{status:'PENDING'}));
  assert.equal(await page.evaluate(async()=>(await queue.list())[0].status),'ACKNOWLEDGED');
 }finally{await browser.close();await new Promise(r=>server.close(r));}
});
