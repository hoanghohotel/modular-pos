import { provisionDefaultStorePositions } from './catalog_admin_domain.mjs';

export function executeTenantOnboarding({ operationId, ownerUserId, orgCode, orgSlug, firstStoreCode, planCode = 'GROWTH' }) {
  const orgId = `org-${orgSlug}`;
  const firstStoreId = `store-${orgSlug}-${firstStoreCode.toLowerCase()}`;
  const { areas, positions } = provisionDefaultStorePositions({ organizationId: orgId, storeId: firstStoreId, dineInCount: 20, takeawayCount: 10, deliveryCount: 10 });
  return {
    ok: true,
    organization: { id: orgId, code: orgCode, owner_user_id: ownerUserId, status: 'ACTIVE' },
    firstStore: { id: firstStoreId, code: firstStoreCode, status: 'ACTIVE' },
    provisionedAreas: areas,
    provisionedPositions: positions,
    provisionedPositionsCount: positions.length,
    planCode,
  };
}
