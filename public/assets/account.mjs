import './sales.mjs';
import { AuthClient } from './auth-client.mjs';
const el = id => document.getElementById(id);
let client;
let stores = [];
const message = text => { el('status').textContent = text; };
function panels() {
  el('loginPanel').hidden = Boolean(client?.signedIn);
  el('workspacePanel').hidden = !client?.signedIn;
  if (!client?.signedIn) { el('bootstrapPanel').hidden = true; window.dispatchEvent(new CustomEvent('workspace:ready', { detail: null })); }
}
async function perform(action) {
  document.querySelectorAll('button').forEach(b => { b.disabled = true; });
  try { await action(); }
  catch (error) {
    const messages = {
      invalid_credentials: 'Email hoặc mật khẩu chưa đúng.',
      email_not_confirmed: 'Hãy xác nhận email trước khi đăng nhập.',
      WORKSPACE_ALREADY_EXISTS: 'Tài khoản đã có không gian làm việc.',
      '23505': 'Tài khoản đã có không gian làm việc hoặc mã thương hiệu đã được sử dụng.',
      AUTH_REQUIRED: 'Vui lòng đăng nhập lại.',
      SUPABASE_NOT_CONFIGURED: 'Chưa cấu hình kết nối Supabase cho môi trường này.',
    };
    message(messages[error.message] || 'Không thực hiện được. Kiểm tra kết nối và thử lại.');
  } finally {
    panels();
    document.querySelectorAll('button').forEach(b => { b.disabled = !client; });
  }
}
function selectedStore() {
  const store = stores.find(s => s.id === el('stores').value);
  el('storeSummary').textContent = store ? `${store.name} · ${store.code}` : 'Chưa có cửa hàng được cấp quyền.';
  window.dispatchEvent(new CustomEvent('workspace:ready', { detail: { client, store } }));
}
async function loadWorkspace() {
  const [organizations, accessibleStores] = await Promise.all([client.organizations(), client.stores()]);
  stores = accessibleStores;
  el('stores').replaceChildren(...stores.map(store => {
    const option = document.createElement('option'); option.value = store.id; option.textContent = store.name; return option;
  }));
  el('stores').disabled = stores.length === 0;
  el('bootstrapPanel').hidden = organizations.length !== 0;
  selectedStore();
}
try {
  client = new AuthClient(window.MODULAR_POS_CONFIG || {});
  message('Sẵn sàng đăng nhập.');
} catch {
  message('Chưa cấu hình Supabase. Cần SUPABASE_URL và SUPABASE_ANON_KEY khi build.');
  document.querySelectorAll('button').forEach(b => { b.disabled = true; });
}
el('loginForm').addEventListener('submit', event => {
  event.preventDefault();
  perform(async () => {
    const user = await client.signIn(el('email').value.trim(), el('password').value);
    el('password').value = '';
    el('identity').textContent = user.email;
    await loadWorkspace();
    message('Đã đăng nhập.');
  });
});
el('signup').addEventListener('click', () => {
  if (!el('loginForm').reportValidity()) return;
  perform(async () => {
    await client.signUp(el('email').value.trim(), el('password').value);
    el('password').value = '';
    message('Đã gửi yêu cầu tạo tài khoản. Kiểm tra email để xác nhận trước khi đăng nhập.');
  });
});
el('logout').addEventListener('click', () => perform(async () => {
  try { await client.signOut(); } finally { stores = []; el('stores').replaceChildren(); el('identity').textContent = ''; }
  message('Đã đăng xuất.');
}));
el('stores').addEventListener('change', selectedStore);
el('bootstrapForm').addEventListener('submit', event => {
  event.preventDefault();
  perform(async () => {
    await client.bootstrap({ name: el('brand').value.trim(), slug: el('slug').value.trim(), storeName: el('storeName').value.trim(), address: el('address').value.trim() });
    await loadWorkspace(); message('Đã tạo cửa hàng đầu tiên.');
  });
});
panels();
