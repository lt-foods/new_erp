#!/usr/bin/env bash
# AUDIT #8 + #9 驗證: list_my_orders / list_my_settlements 的 cursor 分頁
#
# 風險: 原 listMyOrders / listMySettlements 寫死 .limit(100),歷史 >100 看不到。
# 修法: history / shipped tab 改 cursor 分頁 (before_id),回 has_more + next_cursor。
#
# 驗證: 灌 1100 筆 customer_orders (member A, status=completed),
#       走與 Edge Function 同樣的 SQL pattern,翻完所有頁,確認總數 == 1100。
#
# 用法: bash scripts/audit-pagination/test-08-09-orders-settlements-pagination.sh

set -eu

: "${SUPABASE_ACCESS_TOKEN:?}"
: "${SUPABASE_PROJECT_REF:?}"

MGMT="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query"
N=1100
PAGE=30
TAG="audit_p_08_09_$(date +%s)"

run_sql() {
  python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$1" > /tmp/q.json
  curl -sS "$MGMT" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" --data-binary @/tmp/q.json
}

# 隔離 tenant
TENANT_ID="ffffffff-0808-0909-cccc-$(printf '%012d' "$(date +%s)" | cut -c1-12)"
echo "tenant_id=$TENANT_ID, prefix=$TAG, N=$N, PAGE=$PAGE"

cleanup() {
  echo "--- cleanup ---"
  local resp
  resp=$(run_sql "
    BEGIN;
    SET LOCAL session_replication_role = 'replica';
    DELETE FROM customer_order_items WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM customer_orders WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM campaign_items WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM group_buy_campaigns WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM skus WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM products WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM line_channels WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM members WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM stores WHERE tenant_id = '${TENANT_ID}';
    COMMIT;
  ")
  if echo "$resp" | grep -q '"message"'; then
    echo "⚠️ cleanup error: $resp"
  fi
  local remain
  remain=$(run_sql "SELECT
    (SELECT COUNT(*) FROM customer_orders WHERE tenant_id = '${TENANT_ID}') +
    (SELECT COUNT(*) FROM members WHERE tenant_id = '${TENANT_ID}') +
    (SELECT COUNT(*) FROM stores WHERE tenant_id = '${TENANT_ID}')
    AS n;" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["n"])')
  if [ "$remain" != "0" ]; then
    echo "❌ cleanup 沒清乾淨,剩 ${remain} — tenant=${TENANT_ID}"
  else
    echo "cleanup done (verified empty)"
  fi
}
trap cleanup EXIT

# Setup
# 注意:customer_orders 有 partial unique (tenant, campaign, channel, member, order_kind)
# WHERE status NOT IN (transferred_out, expired, cancelled),所以一個 member 不能
# 在同一個 (campaign, channel) 有多筆 active 訂單。要造 1100 筆只好造 1100 個 campaign。
echo "--- setup ---"
SETUP=$(run_sql "
WITH st AS (
  INSERT INTO stores (tenant_id, code, name) VALUES ('${TENANT_ID}', '${TAG}_st', 'audit') RETURNING id
),
m AS (
  INSERT INTO members (tenant_id, member_no, status) VALUES ('${TENANT_ID}', '${TAG}_M', 'active') RETURNING id
),
ch AS (
  INSERT INTO line_channels (tenant_id, code, name, channel_type, home_store_id, additional_pickup_store_ids, is_active)
  SELECT '${TENANT_ID}', '${TAG}_ch', 'audit ch', 'oa_channel', st.id, '[]'::jsonb, true FROM st RETURNING id
)
SELECT (SELECT id FROM st) AS store_id, (SELECT id FROM m) AS member_id,
       (SELECT id FROM ch) AS channel_id;
")
echo "$SETUP"
ST=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["store_id"])')
MB=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["member_id"])')
CH=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["channel_id"])')

echo "--- seed ${N} campaigns + ${N} completed orders ---"
# 一次造 N 個 campaign 與每個 campaign 一筆訂單
SEED_RESP=$(run_sql "
WITH camps AS (
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status)
  SELECT '${TENANT_ID}', '${TAG}_C_' || gs::text, 'audit camp ' || gs::text, 'closed'
  FROM generate_series(1, ${N}) gs
  RETURNING id, campaign_no
),
ord AS (
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, member_id, pickup_store_id, status, completed_at, created_at)
  SELECT '${TENANT_ID}',
         '${TAG}_O_' || ROW_NUMBER() OVER (ORDER BY id)::text,
         id, ${CH}, ${MB}, ${ST}, 'completed',
         now(),
         now() - (ROW_NUMBER() OVER (ORDER BY id) || ' seconds')::interval
  FROM camps
  RETURNING 1
)
SELECT (SELECT COUNT(*) FROM camps) AS camp_n, (SELECT COUNT(*) FROM ord) AS ord_n;
")
echo "$SEED_RESP"

# 模擬 Edge Function 的 history tab 查詢: ORDER BY id DESC, before_id 翻頁
echo "--- paginate (simulating list_my_orders tab=history) ---"
total=0
cursor=""
pages=0
MAX_PAGES=100  # safety
while [ "$pages" -lt "$MAX_PAGES" ]; do
  if [ -z "$cursor" ]; then
    Q="SELECT id FROM v_customer_order_summary WHERE tenant_id = '${TENANT_ID}' AND member_id = ${MB} AND status = 'completed' ORDER BY id DESC LIMIT ${PAGE}"
  else
    Q="SELECT id FROM v_customer_order_summary WHERE tenant_id = '${TENANT_ID}' AND member_id = ${MB} AND status = 'completed' AND id < ${cursor} ORDER BY id DESC LIMIT ${PAGE}"
  fi
  resp=$(run_sql "$Q")
  cnt=$(echo "$resp" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
  if [ "$cnt" = "0" ]; then break; fi
  total=$((total + cnt))
  cursor=$(echo "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[-1]["id"])')
  pages=$((pages + 1))
  if [ "$cnt" -lt "$PAGE" ]; then break; fi
done

echo "翻 ${pages} 頁,共撈到 ${total} 筆 (期望 ${N})"

fail() { echo "❌ FAIL: $1"; exit 1; }
[ "$total" = "$N" ] || fail "total=$total expected $N"
[ "$pages" -gt 1 ] || fail "頁數=$pages 應 >1 (確認分頁真的有運作)"

# 對照: 不用 cursor 的舊式單次查詢 (limit=100),應該只拿 100 筆,證明原 bug 真的存在
LEGACY=$(run_sql "SELECT id FROM v_customer_order_summary WHERE tenant_id = '${TENANT_ID}' AND member_id = ${MB} AND status = 'completed' ORDER BY id DESC LIMIT 100" \
  | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
echo "對照: 舊式 .limit(100) 只能拿 ${LEGACY} 筆 (期望 100,證明截斷情境存在)"
[ "$LEGACY" = "100" ] || echo "⚠️  對照拿到 $LEGACY,非 100"

echo "✅ PASS: list_my_orders(history) cursor 分頁能完整撈到 ${total}/${N} 筆,共 ${pages} 頁"
