#!/usr/bin/env bash
# ============================================================================
# MODULAR POS — KỊCH BẢN TỰ ĐỘNG CHUẨN HÓA MONOREPO, COMMIT GIT & ĐẨY LÊN GITHUB
# Mặc định đã cấu hình theo xác nhận:
#   - Tên Repository: modular-pos
#   - Chế độ: Private (--private)
#   - Nhánh mặc định: main
#   - Phạm vi: Trọn bộ Giai đoạn 1 -> Giai đoạn 9 (Supabase SQL + Next.js TS + Flutter Dart)
#
# Cách chạy trên máy của bạn (Terminal / Git Bash / WSL):
#   chmod +x push_to_github.sh
#   ./push_to_github.sh
# Hoặc truyền trực tiếp URL repo GitHub:
#   ./push_to_github.sh https://github.com/<username>/modular-pos.git
# ============================================================================

set -euo pipefail

REMOTE_ARG="${1:-}"
REPO_NAME="${2:-modular-pos}"
REPO_VISIBILITY="${REPO_VISIBILITY:---private}"

echo "======================================================================"
echo "1. Đang chuẩn hóa cấu trúc thư mục Monorepo ($REPO_NAME)..."
echo "======================================================================"

mkdir -p supabase/migrations
mkdir -p supabase/tests
mkdir -p packages/shared-types/src
mkdir -p packages/domain-specs/src
mkdir -p packages/domain-specs/test
mkdir -p apps/web-admin/src/modules/catalog-admin
mkdir -p apps/web-admin/src/modules/inventory-admin
mkdir -p apps/web-admin/src/modules/saas-platform
mkdir -p apps/web-pos/src/modules/pos-online
mkdir -p apps/web-pos/src/modules/kds-operations
mkdir -p apps/web-pos/src/sync-engine
mkdir -p apps/flutter-pos/lib/local_db
mkdir -p apps/flutter-pos/lib/sync_engine
mkdir -p apps/flutter-pos/lib/core/printing
mkdir -p apps/flutter-pos/lib/domain
mkdir -p apps/flutter-pos/test
mkdir -p docs/architecture
mkdir -p .github/workflows

# 1.1. Tạo file .gitignore chuẩn cho Monorepo (Node.js + Next.js + Flutter + Supabase)
cat << 'EOF' > .gitignore
# Dependencies
node_modules/
.pnpm-store/

# Next.js / Turbo build outputs
.next/
out/
dist/
build/
.turbo/

# Environment variables & Secrets (Tuyệt đối không commit secret thật)
.env
.env.local
.env.*.local

# Supabase local development
supabase/.branches
supabase/.temp

# Flutter / Dart build artifacts
.dart_tool/
.flutter-plugins
.flutter-plugins-dependencies
.packages
pubspec.lock

# Database dumps & OS files
*.dump
*.sql.gz
.DS_Store
Thumbs.db
EOF

# 1.2. Tạo package.json gốc
cat << 'EOF' > package.json
{
  "name": "modular-pos-monorepo",
  "version": "2.0.0-production",
  "private": true,
  "type": "module",
  "description": "Hệ thống POS đa ngành, đa chi nhánh, kiến trúc Offline-first (PostgreSQL/Supabase + Next.js Web Admin/POS + Flutter POS)",
  "scripts": {
    "test": "node --test *.test.mjs",
    "test:monorepo": "node --test packages/domain-specs/test/*.test.mjs",
    "db:reset": "supabase db reset",
    "db:test": "supabase test db"
  },
  "engines": {
    "node": ">=18.18.0"
  }
}
EOF

# 1.3. Tạo pnpm-workspace.yaml, turbo.json, tsconfig.base.json & .env.example
cat << 'EOF' > pnpm-workspace.yaml
packages:
  - "apps/web-admin"
  - "apps/web-pos"
  - "packages/*"
EOF

cat << 'EOF' > turbo.json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "outputs": [".next/**", "!.next/cache/**", "dist/**"]
    },
    "lint": {
      "dependsOn": ["^lint"]
    },
    "test": {
      "dependsOn": ["^build"],
      "outputs": []
    }
  }
}
EOF

cat << 'EOF' > tsconfig.base.json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "strict": true,
    "noImplicitAny": true,
    "strictNullChecks": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "isolatedModules": true
  }
}
EOF

cat << 'EOF' > .env.example
# MODULAR POS — BIẾN MÔI TRƯỜNG MẪU (KHÔNG CHỨA SECRET THẬT)
NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-public-key-here
NEXT_PUBLIC_DEFAULT_LOCALE=vi-VN
NEXT_PUBLIC_DEFAULT_CURRENCY=VND
NEXT_PUBLIC_DEFAULT_TIMEZONE=Asia/Ho_Chi_Minh

# Server-Only Variables (Chỉ dùng trong Supabase Edge Functions / Server Migration)
SUPABASE_SERVICE_ROLE_KEY=your-server-only-service-role-key-here
PAYMENT_WEBHOOK_HMAC_SECRET=your-webhook-hmac-secret-here
EOF

# 1.4. Tạo GitHub Actions CI Workflow (.github/workflows/ci.yml) nếu chưa có
if [ -f github_ci_workflow.yml ]; then
  cp -f github_ci_workflow.yml .github/workflows/ci.yml
else
cat << 'EOF' > .github/workflows/ci.yml
name: Modular POS CI (Phase 1 - Phase 9)

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

jobs:
  domain-and-contract-tests:
    name: Run Domain & Offline Sync Tests (Node.js 20)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup Node.js 20
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Verify SQL Migrations & pgTAP Test Files Exist
        run: |
          ls -la supabase/migrations/
          ls -la supabase/tests/

      - name: Run Automated Test Suites (Phase 3 -> Phase 9)
        run: |
          if ls *.test.mjs >/dev/null 2>&1; then
            node --test *.test.mjs
          fi
EOF
fi

# 1.5. Sắp xếp các file từ thư mục gốc vào đúng phân khu Monorepo
for sql_mig in 2026102000*.sql; do
  [ -f "$sql_mig" ] && cp -f "$sql_mig" "supabase/migrations/$sql_mig"
done

for sql_test in 000*_phase*_tests.sql; do
  [ -f "$sql_test" ] && cp -f "$sql_test" "supabase/tests/$sql_test"
done

[ -f shared_types.ts ] && cp -f shared_types.ts packages/shared-types/src/index.ts

for mjs_domain in *_domain.mjs offline_sync_engine.mjs core_security.mjs; do
  [ -f "$mjs_domain" ] && cp -f "$mjs_domain" "packages/domain-specs/src/$mjs_domain"
done

for mjs_test in *.test.mjs; do
  [ -f "$mjs_test" ] && cp -f "$mjs_test" "packages/domain-specs/test/$mjs_test"
done

[ -f web_admin_catalog_store_service.ts ] && cp -f web_admin_catalog_store_service.ts apps/web-admin/src/modules/catalog-admin/
[ -f web_admin_inventory_service.ts ] && cp -f web_admin_inventory_service.ts apps/web-admin/src/modules/inventory-admin/
[ -f web_admin_saas_platform_service.ts ] && cp -f web_admin_saas_platform_service.ts apps/web-admin/src/modules/saas-platform/

[ -f web_pos_online_service.ts ] && cp -f web_pos_online_service.ts apps/web-pos/src/modules/pos-online/
[ -f web_pos_kds_operations_service.ts ] && cp -f web_pos_kds_operations_service.ts apps/web-pos/src/modules/kds-operations/
[ -f web_pos_offline_sync_service.ts ] && cp -f web_pos_offline_sync_service.ts apps/web-pos/src/sync-engine/

[ -f flutter_pos_drift_database.dart ] && cp -f flutter_pos_drift_database.dart apps/flutter-pos/lib/local_db/
[ -f flutter_pos_isolate_sync.dart ] && cp -f flutter_pos_isolate_sync.dart apps/flutter-pos/lib/sync_engine/
[ -f flutter_pos_hardware_printer.dart ] && cp -f flutter_pos_hardware_printer.dart apps/flutter-pos/lib/core/printing/
[ -f flutter_pos_domain.dart ] && cp -f flutter_pos_domain.dart apps/flutter-pos/lib/domain/
[ -f flutter_pos_test.dart ] && cp -f flutter_pos_test.dart apps/flutter-pos/test/

[ -f modular_pos_phase1_architecture_spec.md ] && cp -f modular_pos_phase1_architecture_spec.md docs/architecture/
[ -f phase2_implementation_bundle.md ] && cp -f phase2_implementation_bundle.md docs/architecture/

echo "======================================================================"
echo "2. Đang khởi tạo Git Repository (nhánh main) và tạo Commit..."
echo "======================================================================"

if [ ! -d .git ]; then
  git init -b main
fi

# Đảm bảo git user.name và user.email đã được cấu hình để không bị lỗi khi commit
if [ -z "$(git config user.name || true)" ]; then
  git config user.name "Modular POS Developer"
fi
if [ -z "$(git config user.email || true)" ]; then
  git config user.email "dev@modularpos.vn"
fi

git add -A
if git diff --cached --quiet; then
  echo "Repository đã ở trạng thái commit mới nhất."
else
  git commit -m "feat: release Modular POS Phase 1-9 (Supabase RLS/RPC, Web Admin/POS, Flutter POS, SaaS & DR)"
fi
git branch -M main

echo "======================================================================"
echo "3. Đang kết nối Remote và đẩy lên GitHub ($REPO_NAME)..."
echo "======================================================================"

# Trường hợp 1: Người dùng truyền URL GitHub trực tiếp
if [[ "$REMOTE_ARG" == http* ]] || [[ "$REMOTE_ARG" == git@* ]]; then
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_ARG"
  else
    git remote add origin "$REMOTE_ARG"
  fi
  git push -u origin main
  echo "✅ Đã đẩy toàn bộ mã nguồn lên $REMOTE_ARG (nhánh main) thành công!"
  exit 0
fi

# Trường hợp 2: Đã có sẵn remote origin trong .git
if git remote get-url origin >/dev/null 2>&1 && [ "$REMOTE_ARG" != "--create-gh" ]; then
  EXISTING_ORIGIN="$(git remote get-url origin)"
  echo "Đang đẩy lên remote origin hiện có: $EXISTING_ORIGIN"
  git push -u origin main
  echo "✅ Đã đẩy toàn bộ mã nguồn lên $EXISTING_ORIGIN (nhánh main) thành công!"
  exit 0
fi

# Trường hợp 3: Tự động tạo repository Private 'modular-pos' và đẩy bằng GitHub CLI (gh)
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    echo "Phát hiện GitHub CLI (gh) đã đăng nhập. Đang tự động tạo repo '$REPO_NAME' ($REPO_VISIBILITY) và đẩy code..."
    gh repo create "$REPO_NAME" "$REPO_VISIBILITY" --source=. --remote=origin --push
    echo "✅ Đã khởi tạo repository '$REPO_NAME' và đẩy toàn bộ mã nguồn lên GitHub thành công!"
    exit 0
  else
    echo "GitHub CLI (gh) chưa đăng nhập. Hãy đăng nhập bằng lệnh: gh auth login"
  fi
fi

# Trường hợp 4: Nếu chạy trong terminal tương tác mà chưa có gh CLI, hỏi trực tiếp URL để push ngay
if [ -t 0 ]; then
  echo ""
  read -r -p "Nhập URL GitHub repository của bạn (ví dụ https://github.com/<username>/$REPO_NAME.git, hoặc nhấn Enter để bỏ qua): " USER_REPO_URL
  if [ -n "$USER_REPO_URL" ]; then
    if git remote get-url origin >/dev/null 2>&1; then
      git remote set-url origin "$USER_REPO_URL"
    else
      git remote add origin "$USER_REPO_URL"
    fi
    git push -u origin main
    echo "✅ Đã đẩy toàn bộ mã nguồn lên $USER_REPO_URL (nhánh main) thành công!"
    exit 0
  fi
fi

echo "----------------------------------------------------------------------"
echo "✔ Git repository cục bộ đã sẵn sàng tại nhánh 'main'."
echo "Để đẩy lên GitHub từ máy của bạn, chỉ cần chạy 1 trong 2 lệnh:"
echo "  1) Nếu dùng GitHub CLI:  ./push_to_github.sh --create-gh $REPO_NAME"
echo "  2) Nếu dùng Remote URL:  ./push_to_github.sh https://github.com/<username>/$REPO_NAME.git"
echo "----------------------------------------------------------------------"
