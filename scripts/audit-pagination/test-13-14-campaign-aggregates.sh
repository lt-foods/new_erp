#!/usr/bin/env bash
# AUDIT #13 + #14 驗證: rpc_member_campaign_aggregates
#
# 風險:
#  #13 舊 rpc_member_campaign_order_counts 是 RETURNS TABLE (SETOF),受
#      PostgREST max_rows=1000 限制,>1000 活動時計數失準。
#  #14 listActiveCampaigns 的 orderRows 查詢無 limit,>1000 訂單時被
#      截斷然後前端 reduce,ordered_qty 偏低 → 超賣。
#
# 驗證: 建一個 campaign + 灌 1100 筆訂單 (每筆 1 個 item, qty=1),呼叫
#       新 RPC,期望: order_count=1100, recent_order_count=1100, ordered_qty=1100。
#
# 用法: bash scripts/audit-pagination/test-13-14-campaign-aggregates.sh

set -eu

: "${SUPABASE_ACCESS_TOKEN:?}"
: "${SUPABASE_PROJECT_REF:?}"
: "${NEXT_PUBLIC_SUPABASE_URL:?}"
: "${NEXT_PUBLIC_SUPABASE_ANON_KEY:?}"

MGMT="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query"
N=1100
TAG="audit_p_13_14_$(date +%s)"

run_sql() {
  python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$1" > /tmp/q.json
  curl -sS "$MGMT" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" --data-binary @/tmp/q.json
}

# 用獨立的測試 tenant 避免污染現有資料的聚合
TENANT_ID="ffffffff-aaaa-bbbb-cccc-$(printf '%012d' "$(date +%s)" | cut -c1-12)"
echo "tenant_id=$TENANT_ID (隔離測試)"
echo "prefix=$TAG, N=$N"

cleanup() {
  echo "--- cleanup ---"
  run_sql "
    DELETE FROM customer_order_items WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM customer_orders WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM campaign_items WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM group_buy_campaigns WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM skus WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM products WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM line_channels WHERE tenant_id = '${TENANT_ID}';
    DELETE FROM stores WHERE tenant_id = '${TENANT_ID}';
  " > /dev/null
  echo "cleanup done"
}
trap cleanup EXIT

echo "--- setup ---"
SETUP=$(run_sql "
WITH st AS (
  INSERT INTO stores (tenant_id, code, name)
  VALUES ('${TENANT_ID}', '${TAG}_st', 'audit store')
  RETURNING id
),
p AS (
  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES ('${TENANT_ID}', '${TAG}_P', 'audit product', 'active')
  RETURNING id
),
s AS (
  INSERT INTO skus (tenant_id, product_id, sku_code, product_name, status)
  SELECT '${TENANT_ID}', p.id, '${TAG}_S', 'audit sku', 'active' FROM p
  RETURNING id
),
ch AS (
  INSERT INTO line_channels (tenant_id, code, name, channel_type, home_store_id, additional_pickup_store_ids, is_active)
  SELECT '${TENANT_ID}', '${TAG}_ch', 'audit channel', 'oa_channel', st.id, '[]'::jsonb, true FROM st
  RETURNING id
),
c AS (
  INSERT INTO group_buy_campaigns (tenant_id, campaign_no, name, status, end_at)
  VALUES ('${TENANT_ID}', '${TAG}_C', 'audit campaign', 'open', now() + interval '7 days')
  RETURNING id
),
ci AS (
  INSERT INTO campaign_items (tenant_id, campaign_id, sku_id, unit_price, sort_order)
  SELECT '${TENANT_ID}', c.id, s.id, 100, 0 FROM c, s
  RETURNING id
)
SELECT
  (SELECT id FROM c)  AS campaign_id,
  (SELECT id FROM ci) AS campaign_item_id,
  (SELECT id FROM s)  AS sku_id,
  (SELECT id FROM ch) AS channel_id,
  (SELECT id FROM st) AS store_id;
")
echo "$SETUP"
CID=$(echo "$SETUP"   | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["campaign_id"])')
CIID=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["campaign_item_id"])')
SKUID=$(echo "$SETUP" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["sku_id"])')
CHID=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["channel_id"])')
STID=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["store_id"])')

echo "--- seed ${N} orders ---"
run_sql "
WITH o AS (
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status, created_at)
  SELECT '${TENANT_ID}', '${TAG}_' || gs::text, ${CID}, ${CHID}, ${STID}, 'confirmed', now()
  FROM generate_series(1, ${N}) gs
  RETURNING id
)
INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price)
SELECT '${TENANT_ID}', o.id, ${CIID}, ${SKUID}, 1, 100 FROM o
RETURNING 1;
" | python3 -c 'import sys,json;print("inserted:", len(json.load(sys.stdin)))'

echo "--- call RPC via PostgREST (anon) ---"
RPC_RESP=$(curl -sS "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/rpc/rpc_member_campaign_aggregates" \
  -H "apikey: ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"p_tenant\":\"${TENANT_ID}\",\"p_recent_days\":7}")

echo "raw: ${RPC_RESP:0:300}..."

# 找出我們這個 campaign 的 row
ROW=$(echo "$RPC_RESP" | python3 -c "
import sys, json
arr = json.load(sys.stdin)
target = ${CID}
for r in arr or []:
    if int(r.get('campaign_id', -1)) == target:
        print(json.dumps(r))
        break
")
if [ -z "$ROW" ]; then
  echo "❌ FAIL: RPC 結果找不到 campaign_id=${CID}"
  exit 1
fi
echo "row: $ROW"

OQ=$(echo "$ROW" | python3 -c 'import sys,json;print(json.load(sys.stdin)["ordered_qty"])')
OC=$(echo "$ROW" | python3 -c 'import sys,json;print(json.load(sys.stdin)["order_count"])')
RC=$(echo "$ROW" | python3 -c 'import sys,json;print(json.load(sys.stdin)["recent_order_count"])')

echo "--- assertions ---"
fail() { echo "❌ FAIL: $1"; exit 1; }
num_eq() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) == float(sys.argv[2]) else 1)" "$1" "$2"; }
num_eq "$OQ" "$N" || fail "ordered_qty=$OQ expected $N"
num_eq "$OC" "$N" || fail "order_count=$OC expected $N"
num_eq "$RC" "$N" || fail "recent_order_count=$RC expected $N (created_at=now,應該全部都在近 7 天內)"

echo "✅ PASS: rpc_member_campaign_aggregates 在 ${N} 筆訂單下 ordered_qty=${OQ} order_count=${OC} recent=${RC}"
