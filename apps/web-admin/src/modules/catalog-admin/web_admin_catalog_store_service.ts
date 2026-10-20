export class WebAdminCatalogAndStoreService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async resolveEffectiveStorePrice(params: { organizationId: string; storeId: string; productId: string; variantId?: string | null; channel?: string }) {
    const { data, error } = await this.supabase.rpc('rpc_resolve_effective_product_price', {
      p_org_id: params.organizationId,
      p_store_id: params.storeId,
      p_product_id: params.productId,
      p_variant_id: params.variantId ?? null,
      p_channel: params.channel ?? 'DINE_IN',
    });
    if (error) throw error;
    return Number(data);
  }
}
