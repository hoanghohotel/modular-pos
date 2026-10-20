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
