import test from 'node:test';
import assert from 'node:assert/strict';
import { AuthClient } from '../../public/assets/auth-client.mjs';
const response = (data, status=200) => ({ ok:status<400, status, json:async()=>data });
test('sign-in sends credentials to Auth and uses the returned token for database requests',async()=>{
  const calls=[];
  const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async(url,options)=>{calls.push({url,...options});return response(calls.length===1?{access_token:'server-token',user:{id:'user-id',email:'user@example.test'}}:[]);}});
  await assert.rejects(client.stores(),/AUTH_REQUIRED/);
  const user=await client.signIn('user@example.test','a-long-password');
  assert.equal(user.id,'user-id');
  assert.equal(calls[0].headers.Authorization,undefined);
  assert.deepEqual(JSON.parse(calls[0].body),{email:'user@example.test',password:'a-long-password'});
  await client.stores();
  assert.equal(calls[1].headers.Authorization,'Bearer server-token');
});
test('failed credentials do not grant a session',async()=>{
  const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>response({error_code:'invalid_credentials'},400)});
  await assert.rejects(client.signIn('owner@example.test','wrong-password'),/invalid_credentials/);
  assert.equal(client.signedIn,false);
});
test('logout clears local session even when server request fails',async()=>{
  let n=0;
  const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>++n===1?response({access_token:'token',user:{id:'u'}}):response({},503)});
  await client.signIn('a@example.test','password');
  await assert.rejects(client.signOut());
  assert.equal(client.signedIn,false);
});
test('an expired token is discarded and cannot be reused',async()=>{
  let n=0;
  const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>++n===1?response({access_token:'token',user:{id:'u'}}):response({},401)});
  await client.signIn('a@example.test','password');
  await assert.rejects(client.stores());
  assert.equal(client.signedIn,false);
});
test('remote connections require HTTPS',()=>{
  assert.throws(()=>new AuthClient({url:'http://example.com',key:'key'}),/HTTPS_REQUIRED/);
});

test('native fetch keeps its global receiver during sign-in',async()=>{
 const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async function(){
  assert.equal(this,globalThis);
  return response({access_token:'token',user:{id:'u'}});
 }});
 await client.signIn('a@example.test','password');
 assert.equal(client.signedIn,true);
});
test('PostgREST business errors remain actionable without trusting arbitrary text',async()=>{
 let n=0;
 const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>++n===1?response({access_token:'token',user:{id:'u'}}):response({code:'40001',message:'VERSION_CONFLICT'},409)});
 await client.signIn('a@example.test','password');
 await assert.rejects(client.stores(),/VERSION_CONFLICT/);
});
test('native fetch keeps its global receiver when called through the client',async()=>{
 const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async function(){
  assert.equal(this,globalThis);
  return response({access_token:'token',user:{id:'u'}});
 }});
 await client.signIn('a@example.test','password');
 assert.equal(client.userId,'u');
});

test('HTTP status distinguishes temporary outages from denied access',async()=>{
 let status=503,calls=0;
 const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>++calls===1?response({access_token:'token',user:{id:'u'}}):response({code:'PGRST000'},status)});
 await client.signIn('a@example.test','password');
 await assert.rejects(client.stores(),error=>error.status===503&&error.message==='PGRST000');
 status=403;
 await assert.rejects(client.stores(),error=>error.status===403);
});

test('non-JSON gateway errors retain status and a malformed 401 still clears the session',async()=>{
 let status=503,calls=0;
 const client=new AuthClient({url:'https://example.supabase.co',key:'public-key',fetcher:async()=>++calls===1?response({access_token:'token',user:{id:'u'}}):{ok:false,status,json:async()=>{throw new SyntaxError('HTML gateway error');}}});
 await client.signIn('a@example.test','password');
 await assert.rejects(client.stores(),error=>error.status===503&&error.message==='HTTP_503');
 status=403;await assert.rejects(client.stores(),error=>error.status===403);
 status=401;await assert.rejects(client.stores(),error=>error.status===401);
 assert.equal(client.signedIn,false);assert.equal(client.userId,null);
});
