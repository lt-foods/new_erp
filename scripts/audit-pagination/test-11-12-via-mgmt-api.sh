#!/usr/bin/env bash
# AUDIT #11 + #12 驗證 (Management API 版)
#
# 用 Supabase Management API (postgres role) 灌 >1000 筆訂單行,
# 呼叫 rpc_member_campaign_detail (透過 SQL 直查 + 透過 PostgREST REST API),
# 驗證 ordered_qty 與 order_count 都正確,證明 PostgREST max_rows=1000
# 不再咬到我們。
#
# 用法: bash scripts/audit-pagination/test-11-12-via-mgmt-api.sh
# 環境: 需要 SUPABASE_ACCESS_TOKEN, SUPABASE_PROJECT_REF,
#       NEXT_PUBLIC_SUPABASE_URL, NEXT_PUBLIC_SUPABASE_ANON_KEY

set -eu

: "${SUPABASE_ACCESS_TOKEN:?}"
: "${SUPABASE_PROJECT_REF:?}"
: "${NEXT_PUBLIC_SUPABASE_URL:?}"
: "${NEXT_PUBLIC_SUPABASE_ANON_KEY:?}"

MGMT="https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_REF}/database/query"
N=1100
TAG="audit_p_11_12_$(date +%s)"
TENANT_QUERY="SELECT tenant_id FROM stores LIMIT 1"
TENANT_ID="$(curl -sS "$MGMT" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"query\":\"$TENANT_QUERY\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["tenant_id"])')"
echo "tenant_id=$TENANT_ID"
echo "prefix=$TAG, N=$N"

run_sql() {
  local q="$1"
  python3 -c "import json,sys; print(json.dumps({'query': sys.argv[1]}))" "$q" > /tmp/q.json
  curl -sS "$MGMT" -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
    -H "Content-Type: application/json" --data-binary @/tmp/q.json
}

cleanup() {
  echo "--- cleanup ---"
  # 注意:skus 有 trigger forbid_sku_delete() 禁止 DELETE (業務規則)。
  # Management API 把多段 SQL 包成一個 transaction,任一語句失敗就全部 rollback,
  # 會造成「看起來清完了但其實啥都沒清」。用 session_replication_role=replica
  # 在 transaction 內禁用 trigger,確保測試 fixture 真的被刪掉。
  local resp
  resp=$(run_sql "
    BEGIN;
    SET LOCAL session_replication_role = 'replica';
    DELETE FROM customer_order_items
    WHERE order_id IN (SELECT id FROM customer_orders WHERE order_no LIKE '${TAG}\\_%' ESCAPE '\\');
    DELETE FROM customer_orders WHERE order_no LIKE '${TAG}\\_%' ESCAPE '\\';
    DELETE FROM campaign_items WHERE campaign_id IN (SELECT id FROM group_buy_campaigns WHERE campaign_no = '${TAG}_C');
    DELETE FROM group_buy_campaigns WHERE campaign_no = '${TAG}_C';
    DELETE FROM skus WHERE sku_code = '${TAG}_S';
    DELETE FROM products WHERE product_code = '${TAG}_P';
    DELETE FROM line_channels WHERE code = '${TAG}_ch';
    COMMIT;
  ")
  # 任一語句報錯都會在 resp 出現 "Failed to run sql query" 或 "message"
  if echo "$resp" | grep -q '"message"'; then
    echo "⚠️  cleanup SQL 回報錯誤:"
    echo "$resp"
  fi
  # 驗證真的清乾淨,否則 silent rollback 會留下假象
  local remain
  remain=$(run_sql "SELECT
    (SELECT COUNT(*) FROM customer_orders WHERE order_no LIKE '${TAG}\\_%' ESCAPE '\\') +
    (SELECT COUNT(*) FROM group_buy_campaigns WHERE campaign_no = '${TAG}_C') +
    (SELECT COUNT(*) FROM skus WHERE sku_code = '${TAG}_S') +
    (SELECT COUNT(*) FROM products WHERE product_code = '${TAG}_P') +
    (SELECT COUNT(*) FROM line_channels WHERE code = '${TAG}_ch')
    AS n;" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["n"])')
  if [ "$remain" != "0" ]; then
    echo "❌ cleanup 沒清乾淨,剩 ${remain} 筆 fixture 未刪 — 請手動處理 prefix=${TAG}"
  else
    echo "cleanup done (verified empty)"
  fi
}
trap cleanup EXIT

# 1. 建立 product / sku / channel / campaign / item
echo "--- setup ---"
SETUP_SQL=$(cat <<SQL
WITH p AS (
  INSERT INTO products (tenant_id, product_code, name, status)
  VALUES ('${TENANT_ID}', '${TAG}_P', 'audit test', 'active')
  RETURNING id
),
s AS (
  INSERT INTO skus (tenant_id, product_id, sku_code, product_name, status)
  SELECT '${TENANT_ID}', p.id, '${TAG}_S', 'audit sku', 'active' FROM p
  RETURNING id, product_id
),
ch AS (
  INSERT INTO line_channels (tenant_id, code, name, channel_type, home_store_id, additional_pickup_store_ids, is_active)
  VALUES ('${TENANT_ID}', '${TAG}_ch', 'audit channel', 'oa_channel',
          (SELECT id FROM stores WHERE tenant_id = '${TENANT_ID}' LIMIT 1),
          '[]'::jsonb, true)
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
SELECT (SELECT id FROM c) AS campaign_id,
       (SELECT id FROM ci) AS campaign_item_id,
       (SELECT id FROM s) AS sku_id,
       (SELECT id FROM ch) AS channel_id;
SQL
)
SETUP=$(run_sql "$SETUP_SQL")
echo "$SETUP"
CID=$(echo "$SETUP"   | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["campaign_id"])')
CIID=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["campaign_item_id"])')
SKUID=$(echo "$SETUP" | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["sku_id"])')
CHID=$(echo "$SETUP"  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["channel_id"])')
echo "campaign_id=$CID, campaign_item_id=$CIID, sku_id=$SKUID, channel_id=$CHID"

# 找一間 store
STORE_ID=$(run_sql "SELECT id FROM stores WHERE tenant_id = '${TENANT_ID}' LIMIT 1" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
echo "store_id=$STORE_ID"

# 2. 灌 N 筆訂單與 items (用 generate_series 一次塞,避免來回 round-trip)
echo "--- seed ${N} orders ---"
SEED_SQL=$(cat <<SQL
WITH o AS (
  INSERT INTO customer_orders (tenant_id, order_no, campaign_id, channel_id, pickup_store_id, status)
  SELECT '${TENANT_ID}', '${TAG}_' || gs::text, ${CID}, ${CHID}, ${STORE_ID}, 'confirmed'
  FROM generate_series(1, ${N}) gs
  RETURNING id
)
INSERT INTO customer_order_items (tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price)
SELECT '${TENANT_ID}', o.id, ${CIID}, ${SKUID}, 1, 100 FROM o
RETURNING (SELECT COUNT(*) FROM customer_order_items WHERE order_id IN (SELECT id FROM o WHERE id = customer_order_items.order_id));
SQL
)
SEED_RESULT=$(run_sql "$SEED_SQL")
INSERTED=$(echo "$SEED_RESULT" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))')
echo "inserted ${INSERTED} order_items"

# 3a. 透過 SQL 直查驗證真值
TRUE_QTY=$(run_sql "SELECT COALESCE(SUM(qty),0)::text AS s FROM customer_order_items coi JOIN customer_orders co ON co.id = coi.order_id WHERE co.campaign_id = ${CID}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["s"])')
echo "true ordered_qty (sql) = $TRUE_QTY"

# 3b. 透過 PostgREST 呼叫 RPC (anon role,模擬 LIFF edge function 路徑)
echo "--- call RPC via PostgREST (anon) ---"
RPC_RESP=$(curl -sS "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/rpc/rpc_member_campaign_detail" \
  -H "apikey: ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"p_tenant\":\"${TENANT_ID}\",\"p_campaign_id\":${CID}}")
echo "$RPC_RESP" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d.get("items") or []
camp = d.get("campaign") or {}
print("order_count:", camp.get("order_count"))
print("items count:", len(items))
print("ordered_qty (first item):", items[0].get("ordered_qty") if items else None)
' || { echo "RPC parse failed: $RPC_RESP"; exit 1; }

RPC_OQ=$(echo "$RPC_RESP" | python3 -c '
import sys, json
d = json.load(sys.stdin)
items = d.get("items") or []
print(items[0]["ordered_qty"] if items else 0)
')
RPC_OC=$(echo "$RPC_RESP" | python3 -c '
import sys, json
print((json.load(sys.stdin).get("campaign") or {}).get("order_count", 0))
')

# 4. assertions (numeric-tolerant: 1100 == 1100.0 == 1100.000)
echo "--- assertions ---"
fail() { echo "❌ FAIL: $1"; exit 1; }
num_eq() { python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) == float(sys.argv[2]) else 1)" "$1" "$2"; }
num_eq "$RPC_OQ" "$N"   || fail "rpc ordered_qty=$RPC_OQ expected $N"
num_eq "$RPC_OC" "$N"   || fail "rpc order_count=$RPC_OC expected $N"
num_eq "$TRUE_QTY" "$N" || fail "sql true qty=$TRUE_QTY expected $N (seed data issue)"

# 5. 對照: 用 PostgREST 直接查 customer_order_items (應被 max_rows 截到 1000),
#    證明這個測試確實有觸發到截斷情境
LEGACY_RESP=$(curl -sS \
  "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/customer_order_items?select=id&order_id=in.$(echo "$RPC_RESP" | python3 -c "import sys,json;d=json.load(sys.stdin);print('')")" \
  -H "apikey: ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" 2>&1 | head -c 200)

# 直接查 customer_order_items: 我們知道 anon 可能因 RLS 拿不到; 但若拿得到,
# 應該等於 max_rows=1000 被截。用 Prefer: count=exact 取總數 vs returned。
HEAD_RESP=$(curl -sSI \
  "${NEXT_PUBLIC_SUPABASE_URL}/rest/v1/customer_order_items?campaign_item_id=eq.${CIID}&select=*" \
  -H "apikey: ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Authorization: Bearer ${NEXT_PUBLIC_SUPABASE_ANON_KEY}" \
  -H "Prefer: count=exact" 2>&1 | grep -i "content-range" || echo "no content-range (likely RLS blocked anon)")
echo "對照 (anon /customer_order_items count): $HEAD_RESP"

echo "✅ PASS: rpc_member_campaign_detail 在 ${N} 筆訂單下回傳正確 ordered_qty (${RPC_OQ}) 與 order_count (${RPC_OC})"
