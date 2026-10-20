export class WebPosKdsOperationsService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async reconcileDeliveryCod(params: { organizationId: string; storeId: string; orderId: string; shiftId?: string | null; paymentMethodId?: string | null; notes?: string }) {
    const { data, error } = await this.supabase.rpc('rpc_delivery_reconcile_cod', {
      p_org_id: params.organizationId,
      p_store_id: params.storeId,
      p_order_id: params.orderId,
      p_shift_id: params.shiftId ?? null,
      p_payment_method_id: params.paymentMethodId ?? null,
      p_notes: params.notes ?? null,
    });
    if (error) throw error;
    return data;
  }
}
