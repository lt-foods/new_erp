#!/usr/bin/env bash
# 套用一支 migration 到線上 DB（走 Supabase Management API）。
# 用法：scripts/apply-migration.sh supabase/migrations/<檔名>.sql
#
# 為什麼不是 psql / supabase db push：pooler 的 5432/6543 TCP 在開發環境
# 被擋，只有 Management API 走得通（見 CLAUDE.md）。
set -euo pipefail

f="${1:?usage: apply-migration.sh <path-to.sql>}"
[ -f "$f" ] || { echo "找不到檔案：$f" >&2; exit 1; }
: "${SUPABASE_PROJECT_REF:?SUPABASE_PROJECT_REF 未設}"
: "${SUPABASE_ACCESS_TOKEN:?SUPABASE_ACCESS_TOKEN 未設}"

echo "→ 套用 $f 到專案 $SUPABASE_PROJECT_REF"
resp=$(jq -Rn --rawfile q "$f" '{query:$q}' | curl -sS \
  --cacert /root/.ccr/ca-bundle.crt \
  -X POST "https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @-)

if echo "$resp" | jq -e 'type == "object" and has("message")' >/dev/null 2>&1; then
  echo "✗ 失敗：" >&2
  echo "$resp" | jq . >&2
  exit 1
fi
echo "✓ 完成"
echo "$resp" | head -c 400
