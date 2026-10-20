export class AuthClient {
  #token = null;
  constructor({ url, key, fetcher = globalThis.fetch }) {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(parsed.hostname))) throw new Error('SUPABASE_HTTPS_REQUIRED');
    if (!key || key.includes('your-')) throw new Error('SUPABASE_NOT_CONFIGURED');
    this.url = parsed.href.replace(/\/$/, '');
    this.key = key;
    this.fetcher = fetcher;
  }
  get signedIn() { return this.#token !== null; }
  async request(path, { method = 'GET', body, authenticated = true } = {}) {
    if (authenticated && !this.#token) throw new Error('AUTH_REQUIRED');
    const response = await this.fetcher(`${this.url}${path}`, {
      method,
      headers: { apikey: this.key, 'Content-Type': 'application/json', ...(authenticated ? { Authorization: `Bearer ${this.#token}` } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    const data = response.status === 204 ? null : await response.json();
    if (!response.ok) {
      if (response.status === 401 && authenticated) this.#token = null;
      const businessCode = typeof data?.message === 'string' ? data.message.match(/^([A-Z][A-Z_]+)(?::|$)/)?.[1] : null;
      throw new Error(data?.error_code || businessCode || data?.code || `HTTP_${response.status}`);
    }
    return data;
  }
  async signIn(email, password) {
    this.#token = null;
    const result = await this.request('/auth/v1/token?grant_type=password', { method: 'POST', authenticated: false, body: { email, password } });
    if (!result.access_token || !result.user?.id) throw new Error('INVALID_AUTH_RESPONSE');
    this.#token = result.access_token;
    return { id: result.user.id, email: result.user.email };
  }
  signUp(email, password) {
    return this.request('/auth/v1/signup', { method: 'POST', authenticated: false, body: { email, password } });
  }
  async signOut() {
    try { if (this.#token) await this.request('/auth/v1/logout', { method: 'POST' }); }
    finally { this.#token = null; }
  }
  organizations() { return this.request('/rest/v1/organizations?select=id,name,slug&order=name'); }
  stores() { return this.request('/rest/v1/stores?select=id,organization_id,name,code&order=name'); }
  bootstrap({ name, slug, storeName, address }) {
    return this.request('/rest/v1/rpc/rpc_bootstrap_workspace', { method: 'POST', body: { p_name: name, p_slug: slug, p_store_name: storeName, p_store_address: address } });
  }
}
