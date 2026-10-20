export class WebAdminSaasPlatformService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async onboardNewTenant(req: Record<string, unknown>) {
    const { data, error } = await this.supabase.rpc('rpc_saas_onboard_tenant', req);
    if (error) throw error;
    return data;
  }
}
