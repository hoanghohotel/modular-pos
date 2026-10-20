# MODULAR POS — HỆ THỐNG POS ĐA NGÀNH, ĐA CHI NHÁNH, KIẾN TRÚC OFFLINE-FIRST (GIAI ĐOẠN 1 -> GIAI ĐOẠN 9)

Hệ thống POS toàn diện (PostgreSQL/Supabase + Next.js Web Admin & Web POS + Flutter POS Android/iOS) đã hoàn thành trọn vẹn **9/9 Giai đoạn** với **68+ bảng dữ liệu chuẩn hóa**, **41 Modules Registry (DAG)**, **100% Row Level Security (RLS)**, **35/35 Node.js Test Suites** và **96 kịch bản kiểm thử `pgTAP`**.

## 1. Cấu trúc Monorepo

- `supabase/migrations/`: 13 file SQL Migrations (`0001` -> `0013`) từ Core, RBAC, RLS, Catalog, POS Online, Offline Sync, Kho & BOM, KDS/CRM/Đối soát đến SaaS Multi-Tenant & Sao lưu PITR.
- `supabase/tests/`: 7 bộ kiểm thử bảo mật & nghiệp vụ `pgTAP` (`0001` -> `0007`, tổng cộng 96 kịch bản).
- `packages/shared-types/`: Hợp đồng kiểu dữ liệu TypeScript Strict Mode dùng chung toàn hệ thống.
- `packages/domain-specs/`: Logic nghiệp vụ lõi (`BigInt` scaled `10000` không sai số float, BOM explosion, Moving Average Cost, Offline Sync Outbox, SaaS Entitlements) và 35 bộ kiểm thử tự động (`node --test`).
- `apps/web-admin/`: Tầng dịch vụ quản trị Catalog, Sơ đồ bàn (20 Bàn + 10 Mang về + 10 Giao hàng), Kho & Định lượng BOM, và Quản trị SaaS Đa Tenant.
- `apps/web-pos/`: Tầng dịch vụ Bán hàng POS Online, In phiếu tạm tính kèm mã QR động VietQR (EMVCo), KDS/Loyalty/Đối soát COD, và Đồng bộ Offline-First (IndexedDB / Dexie.js).
- `apps/flutter-pos/`: Ứng dụng Flutter POS (Drift SQLite ORM + Background Isolate Sync + ESC/POS Thermal Printer Bridge cắt giấy & mở két tiền).
- `docs/architecture/`: Đặc tả Kiến trúc Giai đoạn 1 & Hồ sơ 10 Quyết định Kiến trúc (`ADR-01` -> `ADR-10`).

## 2. Hướng dẫn chạy kiểm thử & khởi tạo Database

```bash
# Chạy kiểm thử Domain & Offline Sync (Node.js >= 18)
node --test packages/domain-specs/test/*.test.mjs

# Khởi tạo Supabase cục bộ & chạy 96 kịch bản kiểm thử pgTAP
supabase start
supabase db reset
supabase test db
```

## Danh sách 13 File SQL Migrations (`supabase/migrations/0001` → `0013`)

| Thứ tự | Tên File Migration | Giai đoạn | Nội dung cốt lõi |
| :---: | :--- | :---: | :--- |
| `0001` | `20261020000100_extensions_and_types.sql` | Giai đoạn 2 | Extensions (`pgcrypto`), 6 Domain `ENUM`s, Trigger `version` & khóa bất biến `tg_enforce_append_only_ledger()` |
| `0002` | `20261020000200_platform_orgs_stores_rbac.sql` | Giai đoạn 2 | 16 bảng Nền tảng (`modules`, `permissions`, `profiles`, `organizations`, `stores`, `memberships`, `roles`, `devices`, `audit_logs`...) |
| `0003` | `20261020000300_rls_helpers_and_core_policies.sql` | Giai đoạn 2 | 6 hàm `SECURITY DEFINER`, `ENABLE/FORCE RLS` trên 16 bảng Core & 3 Transactional RPCs |
| `0004` | `20261020000400_catalog_pricing_and_tables.sql` | Giai đoạn 3 | 12 bảng Catalog, Bảng giá & Sơ đồ vị trí (20 Bàn + 10 Mang về + 10 Giao hàng mặc định) + RLS |
| `0005` | `20261020000500_orders_payments_receipts_and_shifts.sql` | Giai đoạn 4 | 15 bảng Đơn hàng 4 trục trạng thái, Thanh toán, Hóa đơn, Lệnh in, Ca thu ngân & `idempotency_keys` + RLS |
| `0006` | `20261020000600_inventory_recipes_and_transfers.sql` | Giai đoạn 6 | 17 bảng Kho, Quy đổi đơn vị 3 tầng, Công thức BOM có phiên bản, PO/GRN, Chuyển kho & Kiểm kê + RLS |
| `0007` | `20261020000700_sync_conflicts_and_offline_batch_rpc.sql` | Giai đoạn 5 | Bảng `device_sync_watermarks`, `sync_conflicts` & chính sách RLS cô lập theo chi nhánh |
| `0008` | `20261020000800_rpc_pos_orders_payments_and_shifts.sql` | Giai đoạn 4 | 10 Transactional RPCs cho Ca thu ngân, Đơn hàng, Chuyển/Gộp/Tách bàn, Thu tiền, In tạm tính VietQR & Hoàn tiền |
| `0009` | `20261020000900_rpc_inventory_recipes_and_transfers.sql` | Giai đoạn 6 | 6 Transactional RPCs cho Trừ kho BOM, Hoàn trả bù trừ, Nhập kho Moving Average, Chuyển kho In-Transit & Kiểm kê |
| `0010` | `20261020001000_rpc_offline_sync_batch_and_conflict_resolution.sql` | Giai đoạn 5 | 3 Transactional RPCs Đồng bộ Offline-First (`rpc_pull_store_offline_snapshot`, `rpc_process_sync_batch`, `rpc_resolve_sync_conflict`) & View chẩn đoán |
| `0011` | `20261020001100_operations_kds_crm_promotions_and_recon.sql` | Giai đoạn 7 | 6 bảng Vận hành nâng cao (`kitchen_stations`, `kitchen_tickets`, `customer_loyalty_transactions`, `expenses`, `reconciliation_records`) + RLS |
| `0012` | `20261020001200_rpc_operations_kds_crm_and_recon.sql` | Giai đoạn 7 | 7 Transactional RPCs cho Điều phối KDS, Tích/Tiêu điểm Loyalty, Chi phí két, Đối soát COD & Chốt doanh thu ngày |
| `0013` | `20261020001300_saas_subscriptions_entitlements_and_onboarding.sql` | Giai đoạn 9 | 5 bảng Quản trị SaaS & Sao lưu (`subscription_plans`, `organization_subscriptions`, `subscription_invoices`, `tenant_usage_metrics`, `backup_audit_logs`) + 4 RPCs |
