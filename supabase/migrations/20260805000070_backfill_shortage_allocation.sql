-- ============================================================
-- 一次性資料治理：既有已收貨的缺口，依訂單時間回頭配貨
--
-- 20260805000060 讓「少發配貨」從今以後在收貨當下就做，但線上已經累積了一批
-- 到貨量 < 未取訂單量、卻全部顯示「可取貨」的組合。這支把它們依訂單時間
-- （created_at, order_no）補配一次，配不到的標成待補貨。
--
-- 只跑「帳目自洽」的組合 —— supplied > 0 且 picked <= supplied。實測 130 個
-- 缺口組合裡：
--   31 個 supplied = 0（收貨時該品項實收 0）→ 本來就被 Path B 的 qty_received > 0
--      擋著，標了反而多一道要手動解除的關卡，不碰。
--   11 個 picked > supplied（領走的比這團到貨的還多）→ 店裡的貨是跨團／跨批
--      流用的，用單一團的帳去推誰該待補會冤枉人，不碰，留給店家用配貨視窗處理。
--   88 個自洽 → 本檔處理，共 185 件。這 88 個另外用實體庫存交叉驗證過
--      （stock_balances.on_hand < 未取需求）88/88 成立，兩套獨立算法一致。
--
-- 配法與彈窗的「依訂單時間自動配」同規則：由早到晚，裝得下就配、裝不下就跳過
-- 繼續試後面的（不拆行）。剩下的標 backorder_at。
--
-- 冪等：重跑會依當下資料重算，已被店家手動調過的配貨結果會被覆蓋回自動配的
-- 結果，所以這支只該跑一次（migration 本來就只跑一次）。
--
-- rollback: UPDATE customer_order_items SET backorder_at = NULL, backorder_by = NULL
--             WHERE backorder_by = '00000000-0000-0000-0000-000000000000';
-- ============================================================

DO $$
DECLARE
  c RECORD;
  r RECORD;
  v_left    NUMERIC;
  v_blocked INT := 0;
  v_combos  INT := 0;
BEGIN
  FOR c IN
    WITH pw AS (
      SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id,
             SUM(ti.qty_received) AS supplied
        FROM picking_wave_items pwi
        JOIN transfers t       ON t.id = pwi.generated_transfer_id
                              AND t.status IN ('received', 'closed')
        JOIN transfer_items ti ON ti.transfer_id = t.id AND ti.sku_id = pwi.sku_id
       WHERE pwi.campaign_id IS NOT NULL
       GROUP BY 1, 2, 3, 4
    )
    SELECT pw.*, d.demand, d.picked
      FROM pw
      CROSS JOIN LATERAL (
        SELECT COALESCE(SUM(coi.qty) FILTER (WHERE coi.status IN ('pending','reserved','ready')), 0) AS demand,
               COALESCE(SUM(coi.qty) FILTER (WHERE coi.status IN ('picked_up','partially_picked_up')), 0) AS picked
          FROM customer_orders co
          JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = pw.sku_id
         WHERE co.tenant_id       = pw.tenant_id
           AND co.campaign_id     = pw.campaign_id
           AND co.pickup_store_id = pw.store_id
           AND co.status NOT IN ('cancelled','expired','transferred_out')
           AND co.transferred_from_order_id IS NULL
           AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
           AND coi.status NOT IN ('cancelled','expired')
      ) d
     WHERE d.demand > GREATEST(pw.supplied - d.picked, 0)
       AND pw.supplied > 0            -- 排除「實收 0」：本來就被 Path B 擋著
       AND d.picked <= pw.supplied    -- 排除「領走的比到貨多」：跨團流用，帳推不準
  LOOP
    v_combos := v_combos + 1;
    v_left := GREATEST(c.supplied - c.picked, 0);
    FOR r IN
      SELECT coi.id AS item_id, coi.qty
        FROM customer_orders co
        JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = c.sku_id
       WHERE co.tenant_id       = c.tenant_id
         AND co.campaign_id     = c.campaign_id
         AND co.pickup_store_id = c.store_id
         AND co.status NOT IN ('cancelled','expired','transferred_out')
         AND co.transferred_from_order_id IS NULL
         AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
         AND coi.status IN ('pending','reserved','ready')
       ORDER BY co.created_at, co.order_no     -- ＝「依訂單時間」，同時間用單號決勝
    LOOP
      IF r.qty <= v_left THEN
        v_left := v_left - r.qty;
      ELSE
        UPDATE customer_order_items
           SET backorder_at = NOW(),
               -- 全 0 的 uuid = 系統回頭配貨，好跟店家手動配的區分／回滾
               backorder_by = '00000000-0000-0000-0000-000000000000'::uuid,
               updated_at   = NOW()
         WHERE id = r.item_id AND backorder_at IS NULL;
        v_blocked := v_blocked + 1;
      END IF;
    END LOOP;
  END LOOP;

  RAISE NOTICE '回頭配貨：% 個組合、% 個品項行標為待補貨', v_combos, v_blocked;
END $$;
