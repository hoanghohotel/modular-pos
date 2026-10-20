export class WebPosOnlineService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async printProvisionalBill(params: { operationId: string; organizationId: string; storeId: string; orderId: string; deviceId?: string | null }) {
    const { data, error } = await this.supabase.rpc('rpc_pos_print_provisional_bill', {
      p_operation_id: params.operationId,
      p_org_id: params.organizationId,
      p_store_id: params.storeId,
      p_order_id: params.orderId,
      p_device_id: params.deviceId ?? null,
    });
    if (error) throw error;
    return data;
  }
}
