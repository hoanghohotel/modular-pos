-- ============================================================================
-- SEED DATA: 41 MODULES, 25 PERMISSIONS, 2 TENANTS, 2 STORES, 8 ROLES,
-- NHÂN SỰ MẪU (OWNER, STORE_MANAGER, CASHIER) & THIẾT BỊ POS
-- ============================================================================
BEGIN;

INSERT INTO public.profiles (id, email, full_name, phone, status) VALUES
    ('11111111-1111-4111-8111-111111111101', 'owner@modularpos.vn', 'Nguyễn Văn Chủ Sở Hữu', '0901000001', 'ACTIVE'),
    ('11111111-1111-4111-8111-111111111102', 'manager.dn@modularpos.vn', 'Trần Thị Quản Lý Đà Nẵng', '0901000002', 'ACTIVE'),
    ('11111111-1111-4111-8111-111111111103', 'cashier.dn@modularpos.vn', 'Lê Văn Thu Ngân Đà Nẵng', '0901000003', 'ACTIVE'),
    ('11111111-1111-4111-8111-111111111104', 'cashier.hcm@modularpos.vn', 'Phạm Thị Thu Ngân Quận 7', '0901000004', 'ACTIVE'),
    ('22222222-2222-4222-8222-222222222201', 'owner@otherbrand.vn', 'Hoàng Văn Chủ Tenant B', '0902000001', 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.organizations (id, code, slug, name, brand_name, owner_user_id, tax_code, company_address, default_locale, default_currency, default_timezone) VALUES
    ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'ORG-MODULAR', 'modular-vn', 'Công ty TNHH Cà Phê & Bán Lẻ Modular Việt Nam', 'Modular Coffee & Mart', '11111111-1111-4111-8111-111111111101', '0401999888', '123 Nguyễn Văn Linh, Quận Hải Châu, Đà Nẵng', 'vi-VN', 'VND', 'Asia/Ho_Chi_Minh'),
    ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'ORG-OTHER', 'other-brand', 'Công ty Cổ phần Thương Mại Khác', 'Other Brand POS', '22222222-2222-4222-8222-222222222201', '0302888777', '456 Lê Lợi, Quận 1, TP. Hồ Chí Minh', 'vi-VN', 'VND', 'Asia/Ho_Chi_Minh')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.stores (id, organization_id, code, name, address, phone, is_headquarters, status) VALUES
    ('cccccccc-cccc-4ccc-8ccc-ccccccccccc1', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'CN-DN-01', 'Chi nhánh Trung Tâm Đà Nẵng', '123 Nguyễn Văn Linh, Hải Châu, Đà Nẵng', '02363888999', TRUE, 'ACTIVE'),
    ('cccccccc-cccc-4ccc-8ccc-ccccccccccc2', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'CN-HCM-02', 'Chi nhánh Quận 7 TP.HCM', '88 Nguyễn Đức Cảnh, Phú Mỹ Hưng, Quận 7, TP.HCM', '0283888999', FALSE, 'ACTIVE'),
    ('dddddddd-dddd-4ddd-8ddd-ddddddddddd1', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1', 'OTHER-01', 'Cửa hàng Tenant B Quận 1', '456 Lê Lợi, Quận 1, TP.HCM', '0283777666', TRUE, 'ACTIVE')
ON CONFLICT (id) DO NOTHING;

COMMIT;
