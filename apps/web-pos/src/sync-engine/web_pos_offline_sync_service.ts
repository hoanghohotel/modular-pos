export class WebPosOfflineSyncService {
  constructor(private readonly supabase: { rpc: (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: Error | null }> }) {}
  async pushOutboxBatch(params: { organizationId: string; storeId: string; deviceId: string; operations: unknown[] }) {
    const { data, error } = await this.supabase.rpc('rpc_process_sync_batch', {
      p_org_id: params.organizationId,
      p_store_id: params.storeId,
      p_device_id: params.deviceId,
      p_operations: params.operations,
    });
    if (error) throw error;
    return data;
  }
}
