export class WebAdminInventoryService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async deductOrderRecipe(params: { organizationId: string; storeId: string; locationId: string; orderId: string }) {
    const { data, error } = await this.supabase.rpc('rpc_inv_deduct_order_recipe', {
      p_org_id: params.organizationId,
      p_store_id: params.storeId,
      p_location_id: params.locationId,
      p_order_id: params.orderId,
    });
    if (error) throw error;
    return data;
  }
}
