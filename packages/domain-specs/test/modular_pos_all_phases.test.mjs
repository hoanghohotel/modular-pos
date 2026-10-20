import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateModuleStatusValue, resolveEffectiveModuleConfig } from '../src/core_security.mjs';
import { provisionDefaultStorePositions } from '../src/catalog_admin_domain.mjs';
import { generateVietQrPayload } from '../src/pos_online_domain.mjs';
import { calculateMovingAverageCost } from '../src/inventory_recipe_domain.mjs';
import { configureDeliveryOrderPayment } from '../src/advanced_operations_domain.mjs';
import { generateEscPosReceiptBytes } from '../src/flutter_pos_domain.mjs';
import { executeTenantOnboarding } from '../src/saas_production_domain.mjs';

test('SUITE 01 (Phase 2): Core Security, Module Status & 4-Layer Config Inheritance', () => {
  assert.equal(evaluateModuleStatusValue({ moduleKey: 'core', isCore: true, orgStatus: 'DISABLED' }), true);
  assert.equal(evaluateModuleStatusValue({ moduleKey: 'loyalty', isCore: false, orgStatus: 'DISABLED', storeStatus: 'ENABLED' }), false);
  const cfg = resolveEffectiveModuleConfig({
    moduleDefaultConfig: { paper_size: 'K80', copies: 1 },
    orgModuleConfig: { copies: 2 },
    storeModuleConfig: { footer: 'Da Nang' },
    deviceModuleConfig: { paper_size: 'K58' },
  });
  assert.equal(cfg.paper_size, 'K58');
  assert.equal(cfg.copies, 2);
});

test('SUITE 02 (Phase 3): Default 40 Service Positions (20 Dine-In + 10 Takeaway + 10 Delivery)', () => {
  const { areas, positions } = provisionDefaultStorePositions({ organizationId: 'org-1', storeId: 'store-dn' });
  assert.equal(areas.length, 3);
  assert.equal(positions.length, 40);
  assert.equal(positions.filter(p => p.position_type === 'DINE_IN').length, 20);
  assert.equal(positions.filter(p => p.position_type === 'TAKEAWAY_SLOT').length, 10);
  assert.equal(positions.filter(p => p.position_type === 'DELIVERY_SLOT').length, 10);
});

test('SUITE 03 (Phase 4): Provisional Bill Dynamic VietQR (EMVCo CRC16-CCITT)', () => {
  const qr = generateVietQrPayload({ bankBin: '970436', accountNo: '0041000999888', amount: 75600, memo: 'TT DN01-0088' });
  assert.equal(qr.isDynamic, true);
  assert.equal(qr.amount, 75600);
  assert.match(qr.qrPayload, /^000201010212/);
});

test('SUITE 04 (Phase 6 & 7): Moving Average Cost & Delivery COD vs Configured Payment Method', () => {
  const ma = calculateMovingAverageCost({ currentOnHandQty: 10000, currentUnitCost: 250, incomingQty: 15000, incomingUnitCost: 300 });
  assert.equal(ma.newUnitCost, 280);
  const delVietQr = configureDeliveryOrderPayment({
    order: { id: 'o1', total_amount: 120000 },
    paymentMethod: { id: 'pm-qr', code: 'VIETQR', method_category: 'VIETQR' },
    isPrepaid: true,
    shippingFee: 15000,
  });
  assert.equal(delVietQr.isPrepaid, true);
  assert.equal(delVietQr.codAmount, 0);
});

test('SUITE 05 (Phase 8 & 9): Flutter ESC/POS Hardware Bytes & Zero-Touch SaaS Tenant Onboarding', () => {
  const bytes = generateEscPosReceiptBytes({ receipt: { total_amount: 70000 }, store: { name: 'DN01' }, isCash: true, openDrawer: true });
  assert.equal(bytes[0], 0x1B);
  const onboard = executeTenantOnboarding({ operationId: 'op-1', ownerUserId: 'u-1', orgCode: 'ORG-HA', orgSlug: 'hoian', firstStoreCode: 'CN01' });
  assert.equal(onboard.provisionedPositionsCount, 40);
});
