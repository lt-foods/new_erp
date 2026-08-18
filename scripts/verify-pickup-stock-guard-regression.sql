-- 取貨閘門「門市實體庫存」守衛（20260818000010）的**反向**檢查 —— 有沒有誤擋
--
-- CLAUDE.md 記過「false negative（貨在店裡卻不給發）比 false positive 難收拾」——
-- 店員發不出貨只能改走轉單，那會開一張新單、原單永遠留在原狀態，就是重複單災情。
--
-- 先講一個結構性保證，省得每次都全站掃：守衛是在既有條件後面 AND 上一句
-- 「累計承諾 ≤ on_hand」，所以 **cum ≤ on_hand 的行閘門值完全不變**。
-- 也就是說「新增的誤擋」只可能落在 cum > on_hand 的行裡 —— 本查詢就只看那些。
--
-- 用法：
--   node .claude-scripts/apply_via_mgmt_api.cjs scripts/verify-pickup-stock-guard-regression.sql
--
-- 怎麼判讀：
--   nobody_ahead      前面沒有別人排隊，卻還是超過 on_hand ＝ 這張單自己就要得比
--                     店裡有的多（例：要 2 件、on_hand 1）。擋掉是對的。
--   on_hand <= 0      店裡帳上根本沒貨。擋掉是對的。
--   on_hand > 0 且
--   有人排在前面       貨不夠分，最早下單的先拿。擋掉是對的。
--
-- 真正要人工處理的只有一種：**店員確認貨就在架上、但 on_hand 是 0 或負數**。
-- 正解是到「庫存總覽」對該商品新增庫存（或盤點）把帳補正 —— 補正後守衛自己會放行。
-- 不要改開庫存減抵單：rpc_create_inventory_deduction 本來就要求 on_hand 先夠，
-- 它不是「帳沒入」的補救手段（20260818000010 的檔頭有完整說明）。

-- ⚠⚠ 這支回的是**常態盤點清單，不是本次改動的 delta**。務必看懂再下結論：
--
--   它列出「所有 cum > on_hand 的 ready/partially_completed 行」，其中絕大多數
--   **在守衛上線之前就已經 gate=false**（貨根本沒到那一團，Path B/C 不成立），
--   只是單頭被某條路徑推成了 ready —— 那是既有的單頭/品項不一致，與本守衛無關。
--
--   2026-08-18 上線當天實測：本支回 中和店 queued_behind_others 433 筆，
--   但當天真正因為新守衛而從「可取」變「不可取」的**全站只有 78 筆**
--   （110 件 / 71 張單 / 10 家店），中和店 ready 只佔其中 2 筆。
--   下面那道「到貨路徑成立」的前提濾不掉這些 —— recv 只問「這家店收過這個 SKU 沒有」，
--   對常態品幾乎恆真。要量 delta 請在**套用前**跑
--   scripts/verify-pickup-stock-guard-impact.sql，那支才是 delta。
--
--   本支的用途是：店家回報「明明有貨卻不給發」時，拿它定位是哪一類。

WITH recv AS MATERIALIZED (
  SELECT DISTINCT st.id AS store_id, ti.sku_id
    FROM transfers t
    JOIN stores st ON st.location_id = t.dest_location AND st.tenant_id = t.tenant_id
    JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.qty_received > 0
   WHERE t.transfer_type = 'hq_to_store' AND t.status IN ('received','closed')
),
lines AS (
  SELECT co.tenant_id, co.pickup_store_id, coi.sku_id, coi.id AS item_id, coi.qty,
         co.created_at, co.order_no, co.status AS ord_status,
         co.id AS order_id, co.campaign_id,
         (co.status IN ('ready','partially_completed','shipping')) AS is_promised
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    LEFT JOIN members m ON m.id = co.member_id
   WHERE coi.status IN ('pending','reserved','ready')
     AND coi.qty > 0
     AND coi.backorder_at IS NULL
     -- 誤擋只有在「店員今天真的會去發」的單上才算災情
     AND co.status IN ('ready','partially_completed')
     AND COALESCE(m.member_type, '')       <> 'store_internal'
     AND COALESCE(co.order_kind, 'normal') <> 'offset'
),
ranked AS (
  SELECT l.*,
         SUM(CASE WHEN l.is_promised THEN l.qty ELSE 0 END)
           OVER (PARTITION BY l.tenant_id, l.pickup_store_id, l.sku_id
                 ORDER BY l.created_at, l.order_no, l.item_id
                 ROWS UNBOUNDED PRECEDING) AS promised_prefix
    FROM lines l
),
blocked AS MATERIALIZED (
  SELECT r.*,
         r.promised_prefix + CASE WHEN r.is_promised THEN 0 ELSE r.qty END AS cum,
         COALESCE(sb.on_hand, 0) AS on_hand
    FROM ranked r
    JOIN stores st ON st.id = r.pickup_store_id AND st.location_id IS NOT NULL
    LEFT JOIN stock_balances sb
           ON sb.tenant_id   = st.tenant_id
          AND sb.location_id = st.location_id
          AND sb.sku_id      = r.sku_id
   WHERE r.promised_prefix + CASE WHEN r.is_promised THEN 0 ELSE r.qty END
         > COALESCE(sb.on_hand, 0)
),
arrived AS MATERIALIZED (
  -- 到貨路徑（Path A~D'）成立的才算「店員看得到、會想發」的單
  SELECT b.* FROM blocked b
   WHERE EXISTS (SELECT 1 FROM recv WHERE recv.store_id = b.pickup_store_id AND recv.sku_id = b.sku_id)
      OR EXISTS (SELECT 1 FROM transfers t
                  WHERE t.customer_order_id = b.order_id AND t.tenant_id = b.tenant_id
                    AND t.status IN ('received','closed'))
      OR EXISTS (SELECT 1 FROM inventory_deduction_notes n
                  WHERE n.tenant_id = b.tenant_id AND n.campaign_id = b.campaign_id
                    AND n.store_id = b.pickup_store_id AND n.sku_id = b.sku_id
                    AND n.cancelled_at IS NULL)
      OR EXISTS (SELECT 1 FROM customer_orders oo
                   JOIN customer_order_items oi ON oi.order_id = oo.id AND oi.sku_id = b.sku_id
                    AND oi.qty < 0 AND oi.status NOT IN ('cancelled','expired')
                  WHERE oo.tenant_id = b.tenant_id AND oo.campaign_id = b.campaign_id
                    AND oo.pickup_store_id = b.pickup_store_id AND oo.order_kind = 'offset'
                    AND oo.status NOT IN ('cancelled','expired','transferred_out'))
)
SELECT st.name AS store,
       CASE WHEN b.on_hand <= 0            THEN 'no_stock_on_book'
            WHEN b.cum - b.qty <= 0        THEN 'nobody_ahead_wants_more_than_stock'
            ELSE 'queued_behind_others' END AS why_blocked,
       count(*)      AS blocked_lines,
       SUM(b.qty)    AS blocked_qty,
       MIN(b.on_hand) AS min_on_hand
  FROM arrived b
  JOIN stores st ON st.id = b.pickup_store_id
 GROUP BY 1, 2
 ORDER BY blocked_lines DESC;
