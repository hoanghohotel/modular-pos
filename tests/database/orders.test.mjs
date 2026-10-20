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
 } finally{await db.close();}
});
