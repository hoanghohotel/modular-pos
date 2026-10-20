export function provisionDefaultStorePositions({ organizationId, storeId, dineInCount = 20, takeawayCount = 10, deliveryCount = 10 }) {
  if (!organizationId || !storeId) throw new Error('MISSING_TENANT_OR_STORE_ID');
  const areas = [
    { id: `${storeId}-area-dine-in`, organization_id: organizationId, store_id: storeId, code: 'AREA-DINE-IN', name: 'Khu vực Phục vụ Tại chỗ', area_type: 'DINE_IN', display_order: 1, status: 'ACTIVE' },
    { id: `${storeId}-area-takeaway`, organization_id: organizationId, store_id: storeId, code: 'AREA-TAKEAWAY', name: 'Khu vực Đơn Mang về', area_type: 'TAKEAWAY_SLOT', display_order: 2, status: 'ACTIVE' },
    { id: `${storeId}-area-delivery`, organization_id: organizationId, store_id: storeId, code: 'AREA-DELIVERY', name: 'Khu vực Đơn Giao hàng', area_type: 'DELIVERY_SLOT', display_order: 3, status: 'ACTIVE' },
  ];
  const positions = [];
  for (let i = 1; i <= dineInCount; i++) {
    const num = String(i).padStart(2, '0');
    positions.push({ id: `${storeId}-pos-tb-${num}`, organization_id: organizationId, store_id: storeId, area_id: areas[0].id, position_type: 'DINE_IN', code: `TB-${num}`, name: `Bàn ${num}`, capacity: 4, display_order: i, status: 'AVAILABLE', active_order_id: null, version: 1 });
  }
  for (let i = 1; i <= takeawayCount; i++) {
    const num = String(i).padStart(2, '0');
    positions.push({ id: `${storeId}-pos-tw-${num}`, organization_id: organizationId, store_id: storeId, area_id: areas[1].id, position_type: 'TAKEAWAY_SLOT', code: `TW-${num}`, name: `Mang về ${num}`, capacity: 1, display_order: i, status: 'AVAILABLE', active_order_id: null, version: 1 });
  }
  for (let i = 1; i <= deliveryCount; i++) {
    const num = String(i).padStart(2, '0');
    positions.push({ id: `${storeId}-pos-dl-${num}`, organization_id: organizationId, store_id: storeId, area_id: areas[2].id, position_type: 'DELIVERY_SLOT', code: `DL-${num}`, name: `Giao hàng ${num}`, capacity: 1, display_order: i, status: 'AVAILABLE', active_order_id: null, version: 1 });
  }
  return { areas, positions };
}
