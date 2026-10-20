export function createLocalPosDatabase({ organizationId, storeId, deviceId, deviceCode = 'POS1', storeCode = 'DN01' }) {
  return {
    meta: { organization_id: organizationId, store_id: storeId, store_code: storeCode, device_id: deviceId, device_code: deviceCode, is_online: true, is_syncing: false, outbox_seq: 0 },
    sync_outbox: [],
    local_orders: new Map(),
  };
}
