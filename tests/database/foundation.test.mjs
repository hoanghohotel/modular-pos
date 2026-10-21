import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';
import assert from 'node:assert/strict';

// PGlite executes PostgreSQL RLS/constraints. Auth is a minimal test shim;
// full Supabase integration is additionally exercised by the CI DB job.
test('MVP tenant foundation enforces PostgreSQL isolation', async (t) => {
  const db = new PGlite();
  const ids = { a: '11111111-1111-4111-8111-111111111111', b: '22222222-2222-4222-8222-222222222222', c: '33333333-3333-4333-8333-333333333333' };
  try {
    await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated;
      CREATE SCHEMA auth;
      CREATE TABLE auth.users(id uuid PRIMARY KEY, email text, email_confirmed_at timestamptz);
      CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
        SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
      $$;
      GRANT USAGE ON SCHEMA auth TO authenticated;
      GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;`);
    for (const name of (await readdir('supabase/migrations')).filter(n => n.endsWith('.sql')).sort()) {
      const sql = (await readFile(`supabase/migrations/${name}`, 'utf8')).replace(/CREATE EXTENSION IF NOT EXISTS "pgcrypto";/, '');
      await db.exec(sql);
    }
    await db.exec(`INSERT INTO auth.users VALUES ('${ids.a}','a@example.test',now()),('${ids.b}','b@example.test',now()),('${ids.c}','c@example.test',now());`);
    const actor = async (id) => {
      await db.exec('RESET ROLE');
      await db.query("SELECT set_config('request.jwt.claim.sub',$1,false)",[id]);
      await db.exec('SET ROLE authenticated');
    };
    const bootstrap = async (id,slug) => {
      await actor(id);
      return (await db.query('SELECT public.rpc_bootstrap_workspace($1,$2,$3,$4) AS workspace',[slug,slug,'Main','123 Test Street'])).rows[0].workspace;
    };
    const a = await bootstrap(ids.a,'tenant-a');
    const b = await bootstrap(ids.b,'tenant-b');
    await t.test('a user sees only their organization and stores',async()=>{
      await actor(ids.a);
      assert.equal((await db.query('SELECT id FROM public.organizations')).rows.length,1);
      assert.equal((await db.query('SELECT id FROM public.stores')).rows[0].id,a.store_id);
      assert.equal((await db.query('SELECT public.has_store_access($1,$2) AS ok',[b.organization_id,b.store_id])).rows[0].ok,false);
    });
    await t.test('tenant identifiers cannot be mixed in role assignments',async()=>{
      await db.exec('RESET ROLE');
      const role=(await db.query('SELECT id FROM public.roles WHERE organization_id=$1',[b.organization_id])).rows[0].id;
      const membership=(await db.query('SELECT id FROM public.memberships WHERE organization_id=$1',[a.organization_id])).rows[0].id;
      await assert.rejects(db.query('INSERT INTO public.user_roles(organization_id,membership_id,role_id) VALUES($1,$2,$3)',[a.organization_id,membership,role]),/foreign key/i);
    });
    await t.test('store-specific member without a role is denied',async()=>{
      await db.exec('RESET ROLE');
      await db.query('INSERT INTO public.profiles(id,email,full_name) VALUES($1,$2,$3)',[ids.c,'c@example.test','Cashier']);
      await db.query("INSERT INTO public.memberships(organization_id,user_id,scope_type,default_store_id) VALUES($1,$2,'STORE_SPECIFIC',$3)",[a.organization_id,ids.c,a.store_id]);
      await actor(ids.c);
      assert.equal((await db.query('SELECT public.has_store_access($1,$2) AS ok',[a.organization_id,a.store_id])).rows[0].ok,false);
    });
    await t.test('store-specific role permits only its assigned store',async()=>{
      await db.exec('RESET ROLE');
      const m=(await db.query('SELECT id FROM public.memberships WHERE user_id=$1',[ids.c])).rows[0].id;
      const r=(await db.query("INSERT INTO public.roles(organization_id,code,name) VALUES($1,'CASHIER','Cashier') RETURNING id",[a.organization_id])).rows[0].id;
      await db.query('INSERT INTO public.user_roles(organization_id,membership_id,role_id,store_id) VALUES($1,$2,$3,$4)',[a.organization_id,m,r,a.store_id]);
      const other=(await db.query("INSERT INTO public.stores(organization_id,code,name,address) VALUES($1,'OTHER','Other','Address') RETURNING id",[a.organization_id])).rows[0].id;
      await actor(ids.c);
      assert.equal((await db.query('SELECT public.has_store_access($1,$2) AS ok',[a.organization_id,a.store_id])).rows[0].ok,true);
      assert.equal((await db.query('SELECT public.has_store_access($1,$2) AS ok',[a.organization_id,other])).rows[0].ok,false);
    });
    await t.test('membership status revokes access immediately',async()=>{
      await db.exec('RESET ROLE');
      await db.query("UPDATE public.memberships SET status='SUSPENDED' WHERE user_id=$1",[ids.c]);
      await actor(ids.c);
      assert.equal((await db.query('SELECT id FROM public.stores')).rows.length,0);
    });
    await t.test('client cannot elevate itself or call unfinished sync',async()=>{
      await actor(ids.a);
      await assert.rejects(db.query("UPDATE public.memberships SET scope_type='ORG_WIDE'"),/permission denied|row-level security/i);
      await assert.rejects(db.query('SELECT public.rpc_process_sync_batch($1,$2,$3,$4)',[a.organization_id,a.store_id,ids.a,'[]']),/permission denied/i);
      await assert.rejects(db.query('SELECT * FROM public.v_store_sync_diagnostics_summary'),/permission denied/i);
    });
    await t.test('custom app actor setting cannot impersonate another user',async()=>{
      await actor(ids.a);
      await db.query("SELECT set_config('app.current_user_id',$1,false)",[ids.b]);
      assert.equal((await db.query('SELECT public.current_actor_id() AS id')).rows[0].id,ids.a);
    });
    await t.test('bootstrap is atomic and cannot create a second workspace',async()=>{
      await actor(ids.a);
      await assert.rejects(db.query("SELECT public.rpc_bootstrap_workspace('Again','again','Main','Address')"),/WORKSPACE_ALREADY_EXISTS/);
      await db.exec('RESET ROLE');
      assert.equal((await db.query('SELECT count(*)::int AS n FROM public.organizations')).rows[0].n,2);
    });
    await t.test('anonymous and unverified accounts cannot bootstrap',async()=>{
      await db.exec('RESET ROLE; SET ROLE anon');
      await assert.rejects(db.query("SELECT public.rpc_bootstrap_workspace('Bad','bad','Main','Address')"),/permission denied/);
      await db.exec('RESET ROLE');
      const id='44444444-4444-4444-8444-444444444444';
      await db.query('INSERT INTO auth.users VALUES($1,$2,NULL)',[id,'unverified@example.test']);
      await actor(id);
      await assert.rejects(db.query("SELECT public.rpc_bootstrap_workspace('Bad','bad','Main','Address')"),/VERIFIED_EMAIL_REQUIRED/);
    });
  } finally { await db.close(); }
});
