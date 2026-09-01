-- ============================================================
-- 2026-09-01: 月結「總倉→店家」改成派車入帳（老闆 2026-08-31 四項拍板）
--
-- 老闆拍板（《交給Alex_退貨大案_一頁版.md》v2）：
--   「錢在總倉派出去那一刻就算。」
--   口徑 = MAX(派出量, 實收量) × 分店價 —— 超收的店照實收計（不會少收），
--   未收／短收的照派出量計（店家不按收貨不再等於不用付錢）。
--   時程追溯：上線後 9/1 起整月用新制重算（9 月全是 draft，重產即可；
--   confirmed 以上的 gate 不受影響 —— 兩道：迴圈開頭「跳過已鎖定」那個 IF EXISTS，
--   與 upsert 的 WHERE store_monthly_settlements.status IN ('draft','sent','disputed')）。
--   8 月不進系統（老闆用系統外臨時帳收），系統裡 8 月草稿留 draft 不要送。
--
-- 改了什麼（只有這些，其餘逐字保留 20260825030000）：
--   0. **月份硬擋**：函式 BEGIN 之後第一件事，p_month 早於 2026-09-01 直接 RAISE
--      （grep "IF v_month_start < DATE" 找得到）。
--      ⚠️ 副作用是故意的：7/8 月從此不能重產；且會連帶讓
--      rpc_update_free_transfer_amount 對舊月份的估價修改整個失敗。理由寫在該段註解裡。
--   1. rpc_generate_hq_to_store_settlement v10 —— 只動 hq_inbound 一段：
--      a) 時窗   received_at → shipped_at（月界變數語意同步改）
--      b) 狀態   IN ('received','closed') → IN ('shipped','received','closed')
--         （照 20260825030000:82 的樣板，天然排除 cancelled ——
--           ⚠ 作廢單身上是帶著 shipped_at 的，靠白名單擋、不是靠時窗擋）
--      c) 數量   qty_received → GREATEST(qty_shipped, COALESCE(qty_received,0))
--      d) 分店價／明細列的時點一併改用 shipped_at
--      e) 張數／筆數統計的 hq_to_store 母體同步移到派出制（見該段註解）
--   2. _store_inbound_lines（每日進貨對帳的口徑來源）—— 追上 hq_inbound 新口徑，
--      並補上 20260825030000 之後就沒跟到的三處（Leg-2 排除／air 改吃 view／
--      free 排除 Leg-1），否則檔頭自承的「每日加總 = 該月月結 branch_amount」不成立。
--
-- ⛔ 一個字都沒動、也不准掉的（20260825030000 剛修好的「提供店白給、收貨店付兩次」）：
--
--   ⭐ 以下**刻意不寫絕對行號**：本檔頭前後已經因為自己被編輯而讓行號過期三次
--      （阿審連三輪都抓到同一條 P2）。改成寫「怎麼自己數」——這種寫法不會過期：
--
--      ⚠️ 一定要先把註解行濾掉再數，否則會數到這段說明文字本身：
--          grep -v "^\s*--" <本檔> | grep -c "<下面的字串>"
--
--        經總倉 Leg-2 排除     next_transfer_id = t.id       → 應為 4
--        free 排除 Leg-1       next_transfer_id IS NULL      → 應為 7
--        air 吃 view           v_store_aid_transfer_legs     → 應為 9
--        沒有重建 view         grep -c "^CREATE OR REPLACE VIEW" → 應為 0（這個不必濾註解）
--
--   - hq_inbound 的「經總倉 Leg-2 排除」NOT EXISTS：引擎彙總 / 張數統計 / 引擎明細
--     ＋ 每日對帳 helper，共 4 處，掉任何一處＝收貨店被收兩次錢
--   - air_in / air_out 吃 v_store_aid_transfer_legs
--   - free_in / free_out 的 next_transfer_id IS NULL（排除 Leg-1），共 7 處
--   - v_store_aid_transfer_legs 本身（本檔完全沒有重建它）
--
-- ⛔ 刻意維持收貨時點的（不是漏改）：
--   - F) return_to_hq 退貨沖帳 —— 那正是拍板 1「總倉同意才沖帳」的語意。
--   - free_in / free_out 自由轉貨 —— 20260825030000:29-33 說明的跨月資料問題未解，
--     且 rpc_update_free_transfer_amount 的月鎖判定仍依 received_at（見下）。
--
-- ⚠ 已知後果（老闆知情拍板）：
--   - 撤銷收貨（rpc_unreceive_transfer）從此不影響月結金額。
--   - 短收差額**由同批的 20260901000010 負責沖帳**（不是這一支做的）：
--     總倉「同意退回」兩顆鈕原本只寫一筆 transfer_cancel 庫存異動
--     （20260811020000:152-162／:194-204）、不建任何 return_to_hq 調撥單，
--     下面的 F 段因此接不到。20260901000010 補上「順手產一張純記帳 return_to_hq」，
--     F 段就接得住了。
--     ⛔⛔ 所以這一支**不可以單獨上線** —— 只貼這支＝短收照派出量跟店家收錢，
--       與老闆 2026-08-31 拍板 1 相反。三支要一起貼
--       （20260901000000 → 20260901000010 → 20260901000020）。
--
-- 基底：20260825030000_settlement_ship_time_matching.sql（v9，該檔為現行最新版；
--       8/25 之後無任何 migration 再動過本函式與該 view，已 grep 確認）。
--       本檔以 sed 逐段複製基底、再外科手術修改，改動範圍見施工回報的 diff。
-- Rollback：貼 `切片1_回滾SQL_貼了就回到8月25日版_2026-09-01.sql`
--       （內含 20260825030000 的引擎全文 ＋ 20260803000000/20260805000160 的
--         每日對帳三支全文，一貼即回到 8/25 狀態；無 schema 變動）。
--       回滾後需重跑 rpc_generate_hq_to_store_settlement 該月以重建 draft。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_generate_hq_to_store_settlement(
  p_month date,
  p_operator uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $fn$

DECLARE
  v_tenant         UUID;
  v_month_start    DATE := DATE_TRUNC('month', p_month)::DATE;
  v_month_end      DATE := (DATE_TRUNC('month', p_month) + INTERVAL '1 month')::DATE;
  -- 月界（台北時區）：[該月1號00:00, 次月1號00:00) Asia/Taipei。
  -- ⚠ 拿來比對的欄位**每一段不一樣**（2026-09-01 起）：
  --   hq_inbound      → shipped_at（總倉派車日；本次改動）
  --   air_in/air_out  → v_store_aid_transfer_legs.booked_at（＝轉出店 shipped_at，2026-08-25 起）
  --   free_*/return_* → received_at（維持收貨日，刻意沒動）
  v_range_start    TIMESTAMPTZ := v_month_start::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_range_end      TIMESTAMPTZ := v_month_end::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_store          RECORD;
  v_settlement_id  BIGINT;
  v_hq_inbound     NUMERIC(18,4);
  v_air_in         NUMERIC(18,4);
  v_air_out        NUMERIC(18,4);
  v_free_in        NUMERIC(18,4);
  v_free_out       NUMERIC(18,4);
  v_return_out     NUMERIC(18,4);
  v_hq_inbound_b   NUMERIC(18,4);  -- 分店價口徑
  v_air_in_b       NUMERIC(18,4);
  v_air_out_b      NUMERIC(18,4);
  v_return_out_b   NUMERIC(18,4);
  v_adjust         NUMERIC(18,4);  -- 人工調整（active 合計）
  v_cost_total     NUMERIC(18,4);
  v_branch_total   NUMERIC(18,4);
  v_payable        NUMERIC(18,4);
  v_xfer_count     INTEGER;
  v_item_count     INTEGER;
  v_total_stores   INTEGER := 0;
  v_total_amount   NUMERIC(18,4) := 0;
  v_total_cost     NUMERIC(18,4) := 0;
  v_total_branch   NUMERIC(18,4) := 0;
  v_total_adjust   NUMERIC(18,4) := 0;
BEGIN
  -- ⛔ 8 月以前一律擋在資料庫這一層（老闆 2026-08-31 裁示「8 月不進系統」）。
  --
  -- 為什麼要擋在這裡而不是只擋前端：這支是 SECURITY DEFINER RPC，
  -- 任何登入帳號都叫得動（下面有 GRANT ... TO authenticated），
  -- 前端月份選擇器擋不住直接打 API 的人，也擋不住下面那個內部呼叫者。
  --
  -- ⚠️ **這是故意的副作用，不是漏想**：從此 7 月、8 月**再也不能重產**。
  --   要動舊月份，先貼回滾檔回到 8/25 版，跑完再貼回來。
  -- ⚠️ **會連帶擋掉一條既有功能**：rpc_update_free_transfer_amount
  --   （最新版 20260807000000:517）改完估價會 PERFORM 這支重跑該月 ——
  --   若那筆自由轉貨是 8 月以前收貨的，**整個估價修改會失敗**（不是只跳過重算）。
  --   這是刻意選的方向：讓它「大聲失敗」，好過讓它把舊月份用新制重算掉。
  --   要改成「舊月份就跳過重算、估價照改」是另一支 migration 的事。
  IF v_month_start < DATE '2026-09-01' THEN
    RAISE EXCEPTION '月結從 2026 年 9 月起改用「派車就算錢」的新算法；% 月以及更早的月份已經凍結，不能再重新產生（老闆 2026-08-31 決定：8 月以前用系統外的對帳單處理）。真的要重算舊月份，請先請工程師把系統換回 8 月 25 日的版本。',
      to_char(v_month_start, 'YYYY-MM');
  END IF;

  SELECT tenant_id INTO v_tenant FROM stores LIMIT 1;
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'no stores found, cannot infer tenant_id';
  END IF;

  FOR v_store IN
    SELECT s.id, s.code, s.name, s.location_id
      FROM stores s
     WHERE s.tenant_id = v_tenant
       AND s.location_id IS NOT NULL
  LOOP
    -- 跳過已鎖定/結案/作廢（confirmed 起不再重算；cancelled 舊版會 NULL crash，一併跳過）
    IF EXISTS (
      SELECT 1 FROM store_monthly_settlements
       WHERE tenant_id = v_tenant
         AND settlement_month = v_month_start
         AND store_id = v_store.id
         AND status IN ('confirmed','settled','remitted','cancelled')
    ) THEN
      CONTINUE;
    END IF;

    -- A) hq_inbound: 總倉派給店家（成本口徑 + 分店價口徑）
    -- 記帳時點＝**總倉派車出貨當下**（老闆 2026-08-31：「錢在總倉派出去那一刻就算」）。
    -- 數量＝MAX(派出量, 實收量)：超收的店照實收收（不會少收）、
    -- 未收／短收的照派出量收（店家不按收貨不再等於不用付錢）。
    -- 狀態白名單加 'shipped'：照 20260825030000:82 的樣板 ——
    --   ⚠ 作廢單（cancelled）身上**是帶著 shipped_at 的**，靠這串白名單擋掉，
    --     不是靠時窗擋。⛔ 不可以改寫成 status <> 'draft' 之類的黑名單。
    SELECT
      COALESCE(SUM(GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.shipped_at), 0)), 0)
      INTO v_hq_inbound, v_hq_inbound_b
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('shipped','received','closed')
       AND t.dest_location = v_store.location_id
       AND t.shipped_at >= v_range_start
       AND t.shipped_at < v_range_end
       AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
       -- 經總倉互助的 Leg-2 不算 hq_inbound：那批貨是別家店給的，已經在
       -- Leg-1 出貨當下由 air_in/air_out 兩邊媒合入帳（20260825030000）
       AND NOT EXISTS (
             SELECT 1 FROM transfers t1
              WHERE t1.next_transfer_id = t.id
                AND t1.transfer_type = 'store_to_store'
                AND t1.status <> 'cancelled');

    -- B) air_in: 店↔店轉貨收進來（該店是收貨店）
    -- 記帳時點＝**轉出店出貨當下**（老闆 2026-08-25：「轉出店一轉出這筆帳就
    -- 成立，兩邊就媒合完成」）→ 走 v_store_aid_transfer_legs，它已把經總倉的
    -- Leg-1 對到 Leg-2 的收貨店，兩邊同一時點、同一金額。
    SELECT
      COALESCE(SUM(l.qty * l.unit_cost), 0),
      COALESCE(SUM(l.qty * COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0)), 0)
      INTO v_air_in, v_air_in_b
      FROM public.v_store_aid_transfer_legs l
     WHERE l.tenant_id = v_tenant
       AND l.dst_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- C) air_out: 店↔店轉貨送出去（該店是轉出店）—— 同 B 的時點與母體，只是
    -- 站在轉出店那一側（貸記）。經總倉的提供店以前掉進 free_out、用「估價」計價，
    -- 而真商品沒有估價 → 一律 0，兩邊的帳從來沒鏡像過。本次修正。
    SELECT
      COALESCE(SUM(l.qty * l.unit_cost), 0),
      COALESCE(SUM(l.qty * COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0)), 0)
      INTO v_air_out, v_air_out_b
      FROM public.v_store_aid_transfer_legs l
     WHERE l.tenant_id = v_tenant
       AND l.src_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- D) free_in: 自由轉貨收進來（估價入帳、兩口徑同額）
    SELECT
      COALESCE(SUM(COALESCE(ti.estimated_amount, 0)), 0)
      INTO v_free_in
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- E) free_out: 自由轉貨送出去（估價入帳、貸記、兩口徑同額）
    SELECT
      COALESCE(SUM(COALESCE(ti.estimated_amount, 0)), 0)
      INTO v_free_out
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- F) return_out: 退貨回總倉（成本沖回 + 分店價沖回）
    SELECT
      COALESCE(SUM(ti.qty_received * COALESCE(sm.unit_cost, 0)), 0),
      COALESCE(SUM(ti.qty_received * COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0)), 0)
      INTO v_return_out, v_return_out_b
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- G) 人工調整（active 合計；只進 payable，不動貨款兩口徑）
    SELECT COALESCE(SUM(a.amount), 0)
      INTO v_adjust
      FROM store_settlement_adjustments a
     WHERE a.tenant_id = v_tenant
       AND a.settlement_month = v_month_start
       AND a.store_id = v_store.id
       AND a.status = 'active';

    v_cost_total   := v_hq_inbound   + v_air_in   - v_air_out   + v_free_in - v_free_out - v_return_out;
    v_branch_total := v_hq_inbound_b + v_air_in_b - v_air_out_b + v_free_in - v_free_out - v_return_out_b;
    -- 賣斷制：總倉出給分店、跟分店收「分店價」；成本口徑僅供總倉毛利參考
    v_payable      := v_branch_total + v_adjust;

    -- 沒任何活動就 skip + 砍 draft（兩口徑皆 0 且無 active 調整才算無活動；
    -- 只砍 draft，sent/disputed 已進流程不自動刪）
    IF v_hq_inbound = 0 AND v_air_in = 0 AND v_air_out = 0
       AND v_free_in = 0 AND v_free_out = 0 AND v_return_out = 0
       AND v_hq_inbound_b = 0 AND v_air_in_b = 0 AND v_air_out_b = 0
       AND v_return_out_b = 0 AND v_adjust = 0 THEN
      DELETE FROM store_monthly_settlements
       WHERE tenant_id = v_tenant
         AND settlement_month = v_month_start
         AND store_id = v_store.id
         AND status = 'draft';
      CONTINUE;
    END IF;

    -- 計 transfer_count + item_count
    -- 張數／筆數要跟上面的分錄同母體。分錄現在有三種時點，所以這裡拆三段：
    --   1) hq_to_store           → 派車時點（2026-09-01 起，條件與 A 段逐條相同）
    --   2) 自由轉貨／退貨回總倉  → 收貨時點（未改）
    --   3) 店↔店訂單相關腿       → 轉出時點（20260825030000，未改）
    -- ⚠ 第 1 段是**跟著 A 段一起改的**，不是順手改的：
    --   不改的話，「派了但店家從沒按收貨」那批（正是本案要處理的主要對象）
    --   會算出 payable_amount 幾萬元、transfer_count 卻是 0，
    --   而下面的 A) items 明細又真的插了列 ⇒ 同一張對帳單自己打自己的臉。
    SELECT COUNT(DISTINCT x.tid), COUNT(*)
      INTO v_xfer_count, v_item_count
      FROM (
        -- 1) hq_to_store：派車時點
        SELECT t.id AS tid, ti.id AS iid
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.tenant_id = v_tenant
           AND t.transfer_type = 'hq_to_store'
           AND t.status IN ('shipped','received','closed')
           AND t.dest_location = v_store.location_id
           AND t.shipped_at >= v_range_start
           AND t.shipped_at < v_range_end
           AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
           AND NOT EXISTS (SELECT 1 FROM transfers t1
                            WHERE t1.next_transfer_id = t.id
                              AND t1.transfer_type = 'store_to_store'
                              AND t1.status <> 'cancelled')
        UNION ALL
        -- 2) 自由轉貨／退貨回總倉：收貨時點
        SELECT t.id AS tid, ti.id AS iid
          FROM transfers t
          JOIN transfer_items ti ON ti.transfer_id = t.id
         WHERE t.tenant_id = v_tenant
           AND t.status IN ('received','closed')
           AND t.received_at >= v_range_start
           AND t.received_at < v_range_end
           AND ti.qty_received > 0
           AND (
             (t.transfer_type = 'store_to_store' AND t.customer_order_id IS NULL
              AND t.next_transfer_id IS NULL
              AND (t.dest_location = v_store.location_id OR t.source_location = v_store.location_id))
             OR
             (t.transfer_type = 'return_to_hq' AND t.source_location = v_store.location_id)
           )
        UNION ALL
        -- 3) 店↔店訂單相關腿：轉出時點
        SELECT l.transfer_id, l.transfer_item_id
          FROM public.v_store_aid_transfer_legs l
         WHERE l.tenant_id = v_tenant
           AND (l.dst_location = v_store.location_id OR l.src_location = v_store.location_id)
           AND l.booked_at >= v_range_start
           AND l.booked_at < v_range_end
      ) x;

    -- upsert（鎖定前狀態 draft/sent/disputed 都重算；status 本身不動）
    INSERT INTO store_monthly_settlements (
      tenant_id, settlement_month, store_id,
      payable_amount, cost_amount, branch_amount, adjustment_amount,
      transfer_count, item_count,
      status, created_by, updated_by
    ) VALUES (
      v_tenant, v_month_start, v_store.id,
      v_payable, v_cost_total, v_branch_total, v_adjust,
      v_xfer_count, v_item_count,
      'draft', p_operator, p_operator
    )
    ON CONFLICT (tenant_id, settlement_month, store_id)
    DO UPDATE SET
      payable_amount    = EXCLUDED.payable_amount,
      cost_amount       = EXCLUDED.cost_amount,
      branch_amount     = EXCLUDED.branch_amount,
      adjustment_amount = EXCLUDED.adjustment_amount,
      transfer_count    = EXCLUDED.transfer_count,
      item_count        = EXCLUDED.item_count,
      updated_by        = p_operator,
      updated_at        = NOW()
    WHERE store_monthly_settlements.status IN ('draft','sent','disputed')
    RETURNING id INTO v_settlement_id;

    -- 重建 items
    DELETE FROM store_monthly_settlement_items WHERE settlement_id = v_settlement_id;

    -- A) hq_inbound items（雙口徑）
    -- ⚠ 欄位名沿用 qty_received / received_at 不改名（改名會連動前端 14 檔），
    --   但存進去的是「這筆帳的計價數量」＝MAX(派出量,實收量) 與
    --   「這筆帳成立的時間」＝總倉派車當下 —— 同 20260825030000:398 的處理慣例。
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)), COALESCE(sm.unit_cost, 0),
      GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * COALESCE(sm.unit_cost, 0),
      t.shipped_at, 'hq_inbound',
      bp.p, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.shipped_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'hq_to_store'
       AND t.status IN ('shipped','received','closed')
       AND t.dest_location = v_store.location_id
       AND t.shipped_at >= v_range_start
       AND t.shipped_at < v_range_end
       AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
       -- 經總倉互助的 Leg-2 不算 hq_inbound：那批貨是別家店給的，已經在
       -- Leg-1 出貨當下由 air_in/air_out 兩邊媒合入帳（20260825030000）
       AND NOT EXISTS (
             SELECT 1 FROM transfers t1
              WHERE t1.next_transfer_id = t.id
                AND t1.transfer_type = 'store_to_store'
                AND t1.status <> 'cancelled');

    -- B) air_in items（雙口徑）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, l.transfer_id, l.transfer_item_id,
      l.sku_id, l.qty, l.unit_cost,
      l.qty * l.unit_cost,
      -- received_at 欄位存的是**這筆帳成立的時間**＝轉出店出貨當下
      l.booked_at, 'air_in',
      bp.p, l.qty * bp.p
      FROM public.v_store_aid_transfer_legs l
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0) AS p
      ) bp
     WHERE l.tenant_id = v_tenant
       AND l.dst_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- C) air_out items（兩口徑皆負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, l.transfer_id, l.transfer_item_id,
      l.sku_id, l.qty, l.unit_cost,
      -1 * l.qty * l.unit_cost,  -- 負值
      l.booked_at, 'air_out',
      bp.p, -1 * l.qty * bp.p
      FROM public.v_store_aid_transfer_legs l
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, l.sku_id, l.booked_at), 0) AS p
      ) bp
     WHERE l.tenant_id = v_tenant
       AND l.src_location = v_store.location_id
       AND l.booked_at >= v_range_start
       AND l.booked_at < v_range_end;

    -- D) free_in items（估價入帳、兩口徑同額；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      COALESCE(ti.estimated_amount, 0),
      t.received_at, 'free_in', ti.description,
      0, COALESCE(ti.estimated_amount, 0)
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
       AND t.status IN ('received','closed')
       AND t.dest_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- E) free_out items（估價入帳、負值、兩口徑同額；帶描述）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type, description,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, 0,
      -1 * COALESCE(ti.estimated_amount, 0),  -- 負值
      t.received_at, 'free_out', ti.description,
      0, -1 * COALESCE(ti.estimated_amount, 0)
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'store_to_store'
       AND t.customer_order_id IS NULL
       -- 經總倉互助的 Leg-1 不是自由轉貨：它有真商品、沒有估價，留在這裡等於
       -- 計價 0（20260825030000 起改由 air_out 以成本／分店價入帳）
       AND t.next_transfer_id IS NULL
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    -- F) return_out items（沖回、兩口徑皆負值）
    INSERT INTO store_monthly_settlement_items (
      tenant_id, settlement_id, transfer_id, transfer_item_id,
      sku_id, qty_received, unit_cost, line_amount, received_at, entry_type,
      unit_branch_price, branch_amount
    )
    SELECT
      v_tenant, v_settlement_id, t.id, ti.id,
      ti.sku_id, ti.qty_received, COALESCE(sm.unit_cost, 0),
      -1 * ti.qty_received * COALESCE(sm.unit_cost, 0),  -- 負值
      t.received_at, 'return_out',
      bp.p, -1 * ti.qty_received * bp.p
      FROM transfers t
      JOIN transfer_items ti ON ti.transfer_id = t.id
      LEFT JOIN stock_movements sm ON sm.id = ti.out_movement_id
      CROSS JOIN LATERAL (
        SELECT COALESCE(public._branch_price_at(v_tenant, ti.sku_id, t.received_at), 0) AS p
      ) bp
     WHERE t.tenant_id = v_tenant
       AND t.transfer_type = 'return_to_hq'
       AND t.status IN ('received','closed')
       AND t.source_location = v_store.location_id
       AND t.received_at >= v_range_start
       AND t.received_at < v_range_end
       AND ti.qty_received > 0;

    v_total_stores := v_total_stores + 1;
    v_total_amount := v_total_amount + v_payable;
    v_total_cost   := v_total_cost + v_cost_total;
    v_total_branch := v_total_branch + v_branch_total;
    v_total_adjust := v_total_adjust + v_adjust;
  END LOOP;

  RETURN jsonb_build_object(
    'month',                to_char(v_month_start, 'YYYY-MM'),
    'stores_count',         v_total_stores,
    'total_amount',         v_total_amount,
    'total_cost_amount',    v_total_cost,
    'total_branch_amount',  v_total_branch,
    'total_adjustment',     v_total_adjust
  );
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.rpc_generate_hq_to_store_settlement(date, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_generate_hq_to_store_settlement(date, uuid) IS
  'HQ→店月結算。payable = hq_inbound + air_in − air_out + free_in − free_out − return_out + 人工調整（分店價口徑）。'
  'hq_inbound 以**總倉派車出貨當下**入帳（老闆 2026-08-31「錢在總倉派出去那一刻就算」），'
  '數量 = MAX(派出量, 實收量)，狀態白名單 shipped/received/closed（作廢單有 shipped_at，靠白名單擋）。'
  '店↔店訂單相關轉貨（空中轉／經總倉互助）以**轉出店出貨當下**入帳、兩邊鏡像同額'
  '（v_store_aid_transfer_legs）；經總倉 Leg-2 不重複計 hq_inbound、Leg-1 不再誤入 free_out。'
  '自由轉貨、return_to_hq 維持收貨時點（return_to_hq 是「總倉同意才沖帳」的語意，刻意不改）。'
  '短收差額由 20260901000010 產生的純記帳 return_to_hq 沖掉（restock_hq/redispatch 兩顆鈕都會產），'
  '⚠ 沖帳的分店價以「按鈕當下」計價，與原扣款的「派車當下」在改過價的商品上會有差額。'
  '已 confirmed/settled/remitted/cancelled 不重算。基底 20260825030000。';

-- ============================================================
-- 二、每日進貨對帳：口徑追上上面的生成器
--
-- 為什麼一定要一起改：20260803000000 檔頭第 :13-14 行自承
-- 「每日金額加總 = 該月月結的 branch_amount（不含人工調整）」——
-- 那是這三支函式存在的意義（店家當天就看得到要付多少）。
-- 上面 hq_inbound 換成派出制之後不跟著換，店家看到的每日金額
-- 會跟月底收到的帳單對不起來，而且是**每天都對不起來**。
--
-- ⚠ 順帶追上 20260825030000（8/25 起就沒跟到，本次一併補齊）：
--   這三支的基底是 20260801000000 版生成器（檔頭 :10-11 自己寫的），
--   而 8/25 生成器改了三處，這裡一處都沒跟：
--     (1) hq_inbound 少了「經總倉 Leg-2 排除」→ 收貨店被算兩次
--     (2) air_in/air_out 還在用 customer_order_id IS NOT NULL + 收貨時點
--         → 經總倉互助的提供店（Leg-1）在每日對帳裡完全看不到
--     (3) free_in/free_out 少了 next_transfer_id IS NULL → Leg-1 重複計入
--   ⇒ 只改 hq_inbound 的話，「每日加總 = 月結 branch_amount」還是不成立。
--
-- ⭐ 只動 _store_inbound_lines 一支：另外兩支 RPC
--   （rpc_store_inbound_daily_summary / rpc_store_inbound_day_items）
--   本身沒有任何口徑邏輯，只是把這支的輸出包成 JSON，
--   ⇒ 函式本體一個字都不動，只更新它們的 COMMENT 說明新口徑。
--   （重貼一份一模一樣的函式本體只會增加抄錯的風險，不會增加正確性。）
--
-- 輸出欄位名沿用 received_at / biz_date 不改名：那是回傳型別的一部分，
-- 改名會連動兩支 RPC 與前端。語意改成「這筆帳成立的時間」——
-- 與 20260825030000:398 對 store_monthly_settlement_items.received_at
-- 的處理方式完全一致（同一套慣例，不另創第二套）。
-- ============================================================

-- ------------------------------------------------------------
-- 1. helper：某店在 [p_from, p_to) 之間的分店價分錄（逐行）
--    正負號與 store_monthly_settlement_items.branch_amount 一致。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_inbound_lines(
  p_store_id BIGINT,
  p_from     TIMESTAMPTZ,
  p_to       TIMESTAMPTZ
) RETURNS TABLE (
  transfer_id       BIGINT,
  transfer_item_id  BIGINT,
  sku_id            BIGINT,
  qty               NUMERIC,
  unit_branch_price NUMERIC,
  amount            NUMERIC,
  entry_type        TEXT,
  description       TEXT,
  received_at       TIMESTAMPTZ,
  biz_date          DATE
)
LANGUAGE sql STABLE
AS $$
  WITH st AS (
    SELECT s.id, s.tenant_id, s.location_id
      FROM public.stores s
     WHERE s.id = p_store_id
       AND s.location_id IS NOT NULL
  )
  -- A) hq_inbound：總倉派給店家（+）
  --    時點＝派車出貨當下、數量＝MAX(派出量,實收量)、狀態白名單含 shipped
  --    ——與生成器 A 段逐條相同（20260901000000）。
  --    ⛔ NOT EXISTS 那段是「經總倉互助 Leg-2 排除」，掉了收貨店會被算兩次。
  SELECT t.id, ti.id, ti.sku_id, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)),
         bp.p, GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) * bp.p,
         'hq_inbound'::TEXT, ti.description, t.shipped_at,
         (t.shipped_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.shipped_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'hq_to_store'
     AND t.status IN ('shipped','received','closed')
     AND t.dest_location = st.location_id
     AND t.shipped_at >= p_from
     AND t.shipped_at <  p_to
     AND GREATEST(ti.qty_shipped, COALESCE(ti.qty_received, 0)) > 0
     AND NOT EXISTS (
           SELECT 1 FROM public.transfers t1
            WHERE t1.next_transfer_id = t.id
              AND t1.transfer_type = 'store_to_store'
              AND t1.status <> 'cancelled')

  UNION ALL
  -- B) air_in：店↔店轉貨收進來（+）
  --    改吃 v_store_aid_transfer_legs（20260825030000）：時點＝轉出店出貨當下、
  --    數量＝qty_shipped，且已把「經總倉互助」的 Leg-1 對到 Leg-2 的收貨店。
  --    ⛔ 不可以退回 customer_order_id IS NOT NULL 的舊寫法 ——
  --      那樣經總倉互助的提供店在每日對帳裡會整個看不到。
  --    description 補 join transfer_items 取回（view 沒帶這欄；訂單相關轉貨用真商品，
  --    現網此欄皆為 NULL，join 只是保證輸出與改動前一致）。
  SELECT l.transfer_id, l.transfer_item_id, l.sku_id, l.qty,
         bp.p, l.qty * bp.p,
         'air_in'::TEXT, ti.description, l.booked_at,
         (l.booked_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.v_store_aid_transfer_legs l ON l.tenant_id = st.tenant_id
    LEFT JOIN public.transfer_items ti ON ti.id = l.transfer_item_id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, l.sku_id, l.booked_at), 0) AS p
    ) bp
   WHERE l.dst_location = st.location_id
     AND l.booked_at >= p_from
     AND l.booked_at <  p_to

  UNION ALL
  -- C) air_out：店↔店轉貨送出去（−）—— 同 B 的母體，站在轉出店那一側
  SELECT l.transfer_id, l.transfer_item_id, l.sku_id, l.qty,
         bp.p, -1 * l.qty * bp.p,
         'air_out'::TEXT, ti.description, l.booked_at,
         (l.booked_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.v_store_aid_transfer_legs l ON l.tenant_id = st.tenant_id
    LEFT JOIN public.transfer_items ti ON ti.id = l.transfer_item_id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, l.sku_id, l.booked_at), 0) AS p
    ) bp
   WHERE l.src_location = st.location_id
     AND l.booked_at >= p_from
     AND l.booked_at <  p_to

  UNION ALL
  -- D) free_in：自由轉入（+，估價；維持收貨時點）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         0, COALESCE(ti.estimated_amount, 0),
         'free_in'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NULL
     -- 經總倉互助的 Leg-1 不是自由轉貨（20260825030000）：它有真商品、沒有估價，
     -- 留在這裡等於計價 0，已改由上面的 air_out 以分店價入帳
     AND t.next_transfer_id IS NULL
     AND t.status IN ('received','closed')
     AND t.dest_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- E) free_out：自由轉出（−，估價；維持收貨時點）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         0, -1 * COALESCE(ti.estimated_amount, 0),
         'free_out'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
   WHERE t.transfer_type = 'store_to_store'
     AND t.customer_order_id IS NULL
     -- 經總倉互助的 Leg-1 不是自由轉貨（20260825030000）：見上面 D) 的說明
     AND t.next_transfer_id IS NULL
     AND t.status IN ('received','closed')
     AND t.source_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0

  UNION ALL
  -- F) return_out：退貨回總倉（−）
  SELECT t.id, ti.id, ti.sku_id, ti.qty_received,
         bp.p, -1 * ti.qty_received * bp.p,
         'return_out'::TEXT, ti.description, t.received_at,
         (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE
    FROM st
    JOIN public.transfers t ON t.tenant_id = st.tenant_id
    JOIN public.transfer_items ti ON ti.transfer_id = t.id
    CROSS JOIN LATERAL (
      SELECT COALESCE(public._branch_price_at(st.tenant_id, ti.sku_id, t.received_at), 0) AS p
    ) bp
   WHERE t.transfer_type = 'return_to_hq'
     AND t.status IN ('received','closed')
     AND t.source_location = st.location_id
     AND t.received_at >= p_from
     AND t.received_at <  p_to
     AND ti.qty_received > 0
$$;

COMMENT ON FUNCTION public._store_inbound_lines(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) IS
  '某分店在指定期間的分店價分錄逐行（口徑同月結 branch_amount，正負號一致）。'
  '內部 helper：不開放直接呼叫，只給 rpc_store_inbound_* 用。'
  '時點：hq_inbound=總倉派車日（2026-09-01 起，數量取 MAX(派出量,實收量)）、'
  'air_in/air_out=轉出店出貨日（2026-08-25 起，走 v_store_aid_transfer_legs）、'
  'free_*/return_*=收貨日。回傳欄位 received_at 存的是「這筆帳成立的時間」。';

REVOKE ALL ON FUNCTION public._store_inbound_lines(BIGINT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;

-- ------------------------------------------------------------
-- 兩支對外 RPC：函式本體不動（無口徑邏輯），只更新說明。
-- 最新版分別是 20260803000000（daily_summary）與
-- 20260805000160（day_items，虛擬 SKU 顯示名）—— 兩支都保持原樣。
-- ------------------------------------------------------------
COMMENT ON FUNCTION public.rpc_store_inbound_daily_summary(BIGINT, DATE) IS
  '分店某月「每日進貨金額」彙總（分店價口徑，日界 Asia/Taipei）。'
  '月合計 = 該月月結 branch_amount（不含人工調整）。分店只能查自己店、HQ 可查全部。'
  '2026-09-01 起：總倉→分店那一段的日期＝總倉派車日（不是店家收貨日），'
  '數量＝MAX(派出量, 實收量)；店↔店訂單相關轉貨＝轉出店出貨日（2026-08-25 起）。';

COMMENT ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) IS
  '分店某日進貨明細（品項/數量/分店價/小計）＋當日總金額，日界 Asia/Taipei。'
  '口徑同月結對帳單（分店價），分店只能查自己店、HQ 可查全部。'
  '自由轉貨的虛擬 SKU 以 transfer_items.description 當品名，不回佔位 SKU 的編號/規格。'
  '2026-09-01 起：總倉→分店那一段的日期＝總倉派車日、數量＝MAX(派出量, 實收量)；'
  '回傳欄位 received_at 存的是「這筆帳成立的時間」，不一定是收貨時間。';
