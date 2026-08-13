-- ============================================================
-- 訂單取消/逾期 → 自動釋放庫存減抵單的覆蓋（斷根 PR #697 的殭屍單問題）
--
-- 動機：8/06 現貨配單事故留下 4 張綁在「已取消訂單」上的減抵單（DN5/7/8/13，
--   由 scripts/PROD-fix-void-phantom-deduction-notes-2026-08-13.sql 個案作廢）。
--   根因是系統性的：全 repo 沒有任何路徑會寫 inventory_deduction_notes.cancelled_at，
--   訂單死了（取消/逾期）之後，減抵單的覆蓋量繼續掛在 (團,店,SKU) 群組上——
--   取貨閘門 Path D 是 qty-blind 的群組 EXISTS，殘留覆蓋讓同組其他客人顯示
--   「可取」（實際無貨）、ship-vs-demand 的 covered 也被虛增（總倉少派）。
--
-- 為什麼掛 trigger 在 customer_orders、而不是逐一 hook 取消路徑：
--   把訂單/品項改成 cancelled 的路徑超過十條（斷貨連動、待補貨取消、全退、
--   轉單、刪品項、批次取消、腳本…），逐條 hook 一定漏（CLAUDE.md 一再重演的坑），
--   而且 8/06 那批就是腳本取消的，RPC hook 根本接不到。訂單層級的
--   status → cancelled/expired 是唯一乾淨的「需求死了」訊號：
--   - 轉單是 transferred_out，不會誤觸（貨仍欠同店新客人，覆蓋要留著）。
--   - 部分轉出把「品項」標 cancelled 但訂單還活著 → 品項層級無法區分
--     「真的死」和「搬走了」，所以刻意不做品項層級 trigger。
--   - 收尾規則保證「取過貨的訂單」只會變 completed/partially_completed，
--     不會變 cancelled（全品項取消規則排除有 picked_up 的單；全退例外見下）
--     → 訂單變 cancelled 時，該單上的減抵覆蓋必然「未交付或已退回」，全額釋放安全。
--     全退（20260801000000）把整單退貨改成 cancelled：貨已沖回店庫存，
--     覆蓋一樣該釋放（需求消失），語意同樣正確。
--
-- 行為：
--   - 訂單 status 進入 cancelled/expired（從非死亡狀態）→ 對綁定該訂單的
--     有效減抵單，釋放對應明細的覆蓋量：全釋放 → 整張作廢（cancelled_at，
--     qty 保留原值當歷史）；部分釋放 → qty 遞減 + reason 加註記。
--   - 明細加 released_qty 欄追蹤已釋放量：同一張單多次事件（品項先斷貨、
--     訂單後取消）不會重複釋放，重跑冪等。
--   - 釋放「不可逆」：訂單事後被回復（如 rpc_restore_stockout_po 斷貨回復
--     cancelled → pending）不會自動長回覆蓋——保守方向（寧可誠實顯示未到貨，
--     不可憑空放行），需要時店家重開減抵單即可。
--   - 不含 backfill：2026-08-13 以唯讀查詢盤點線上，「有效 DN × 已死訂單」
--     僅 DN5/7/8/13 四張，全部由上述 PROD-fix 腳本（PR #697）個案處理；
--     與本 migration 部署先後無關（trigger 只管未來的轉變）。
--
-- 附帶：rpc_list_inventory_deduction_notes 回傳 cancelled_at，
--   減抵單歷史頁才看得出哪張已作廢（前端同 PR 加標示）。
--
-- 基底版本：
--   inventory_deduction_notes / _items schema = 20260805000170（唯一版本）
--   rpc_list_inventory_deduction_notes        = 20260805000170（唯一版本）
--   _release_idn_coverage_for_orders / trg_release_idn_coverage 為新增
-- rollback:
--   DROP TRIGGER IF EXISTS trg_release_idn_coverage ON customer_orders;
--   DROP FUNCTION IF EXISTS public.trg_release_idn_coverage();
--   DROP FUNCTION IF EXISTS public._release_idn_coverage_for_orders(BIGINT[], UUID, TIMESTAMPTZ);
--   ALTER TABLE inventory_deduction_note_items DROP COLUMN IF EXISTS released_qty;
--   DROP INDEX IF EXISTS idx_idn_items_order;
--   重跑 20260805000170 的 rpc_list_inventory_deduction_notes；
--   （已被釋放的單：cancelled_at / qty / reason 需人工還原，released_qty 有留帳可查）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 明細追蹤已釋放量（冪等的關鍵：釋放過的不再釋放）
-- ------------------------------------------------------------
ALTER TABLE inventory_deduction_note_items
  ADD COLUMN IF NOT EXISTS released_qty NUMERIC(18,3) NOT NULL DEFAULT 0;

COMMENT ON COLUMN inventory_deduction_note_items.released_qty IS
  '綁定訂單取消/逾期時已釋放的覆蓋量（≤ qty）。'
  '_release_idn_coverage_for_orders 寫入；用來讓多次死亡事件冪等。';

-- trigger 由 order_id 反查減抵明細用
CREATE INDEX IF NOT EXISTS idx_idn_items_order
  ON inventory_deduction_note_items (order_id);

-- ------------------------------------------------------------
-- 2. _release_idn_coverage_for_orders — 釋放死亡訂單上的減抵覆蓋
--    也可手動呼叫掃殘留（對某訂單陣列收斂其所有觸及的減抵單）。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._release_idn_coverage_for_orders(
  p_order_ids BIGINT[],
  p_operator  UUID,
  p_at        TIMESTAMPTZ DEFAULT NOW()
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r     inventory_deduction_notes%ROWTYPE;
  v_rel NUMERIC;
BEGIN
  IF p_order_ids IS NULL OR COALESCE(array_length(p_order_ids, 1), 0) = 0 THEN
    RETURN;
  END IF;

  FOR r IN
    SELECT n.*
      FROM inventory_deduction_notes n
     WHERE n.cancelled_at IS NULL
       AND EXISTS (
         SELECT 1 FROM inventory_deduction_note_items ni
          WHERE ni.note_id = n.id
            AND ni.order_id = ANY(p_order_ids)
       )
     ORDER BY n.id
       FOR UPDATE
  LOOP
    -- 這張單上綁在已死訂單、尚未釋放的覆蓋量。
    -- 刻意不限 p_order_ids：同單其他「也已死」的訂單一併收斂，
    -- 手動掃殘留時才不會要一張張指定。
    SELECT COALESCE(SUM(ni.qty - ni.released_qty), 0) INTO v_rel
      FROM inventory_deduction_note_items ni
      JOIN customer_orders co ON co.id = ni.order_id
     WHERE ni.note_id = r.id
       AND co.status IN ('cancelled', 'expired')
       AND ni.qty > ni.released_qty;

    CONTINUE WHEN v_rel <= 0;

    UPDATE inventory_deduction_note_items ni
       SET released_qty = ni.qty
      FROM customer_orders co
     WHERE co.id = ni.order_id
       AND ni.note_id = r.id
       AND co.status IN ('cancelled', 'expired')
       AND ni.qty > ni.released_qty;

    IF v_rel >= r.qty THEN
      -- 覆蓋全沒了 → 整張作廢。qty 保留原值當歷史紀錄——
      -- 所有 coverage / Path D 消費端都濾 cancelled_at IS NULL，不會再算到它。
      UPDATE inventory_deduction_notes
         SET cancelled_at = p_at,
             cancelled_by = COALESCE(p_operator, r.created_by),
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || ' [綁定訂單取消，覆蓋自動釋放]'), '')
       WHERE id = r.id;
    ELSE
      -- 部分釋放：qty 遞減（CHECK qty > 0 由 v_rel < r.qty 保證）
      UPDATE inventory_deduction_notes
         SET qty = r.qty - v_rel,
             reason = NULLIF(TRIM(COALESCE(reason, '')
                       || format(' [訂單取消釋放 %s 件]', trim_scale(v_rel)::text)), '')
       WHERE id = r.id;
    END IF;
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public._release_idn_coverage_for_orders(BIGINT[], UUID, TIMESTAMPTZ) IS
  '訂單取消/逾期時釋放其綁定的庫存減抵單覆蓋：全釋放→作廢、部分→qty 遞減。'
  '以 released_qty 冪等；釋放不可逆（訂單回復不會自動恢復覆蓋，需要時重開單）。';

REVOKE ALL ON FUNCTION public._release_idn_coverage_for_orders(BIGINT[], UUID, TIMESTAMPTZ) FROM PUBLIC;

-- ------------------------------------------------------------
-- 3. trigger：訂單進入 cancelled/expired 當下釋放
--    掛在訂單層級（不做品項層級）的理由見檔頭。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_release_idn_coverage()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  PERFORM public._release_idn_coverage_for_orders(
    ARRAY[NEW.id],
    COALESCE(NEW.updated_by, NEW.created_by),
    NOW()
  );
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_release_idn_coverage ON customer_orders;
CREATE TRIGGER trg_release_idn_coverage
AFTER UPDATE ON customer_orders
FOR EACH ROW
WHEN (NEW.status IN ('cancelled', 'expired')
      AND OLD.status NOT IN ('cancelled', 'expired'))
EXECUTE FUNCTION public.trg_release_idn_coverage();

-- ------------------------------------------------------------
-- 4. 歷史清單回傳 cancelled_at（基底：20260805000170，唯一版本；
--    只加一個欄位，其餘逐字保留）
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_list_inventory_deduction_notes(
  p_store_id BIGINT DEFAULT NULL,
  p_limit    INT DEFAULT 50
) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id',            n.id,
           'note_no',       n.note_no,
           'qty',           n.qty,
           'reason',        n.reason,
           'created_at',    n.created_at,
           'cancelled_at',  n.cancelled_at,
           'store_id',      n.store_id,
           'store_name',    st.name,
           'campaign_id',   n.campaign_id,
           'campaign_name', gc.name,
           'sku_code',      s.sku_code,
           'sku_label',     (COALESCE(s.product_name, '') ||
                             CASE WHEN s.variant_name IS NOT NULL THEN ' / ' || s.variant_name ELSE '' END),
           'lines',         COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'order_no', co.order_no,
                      'customer', COALESCE(m.name, co.nickname_snapshot),
                      'qty',      li.qty
                    ) ORDER BY li.id)
               FROM inventory_deduction_note_items li
               JOIN customer_orders co ON co.id = li.order_id
               LEFT JOIN members m ON m.id = co.member_id
              WHERE li.note_id = n.id
           ), '[]'::jsonb)
         ) ORDER BY n.id DESC), '[]'::jsonb)
    FROM (
      SELECT * FROM inventory_deduction_notes n0
       WHERE (p_store_id IS NULL OR n0.store_id = p_store_id)
       ORDER BY n0.id DESC
       LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    ) n
    JOIN stores st ON st.id = n.store_id
    JOIN skus s ON s.id = n.sku_id
    LEFT JOIN group_buy_campaigns gc ON gc.id = n.campaign_id;
$$;

COMMENT ON FUNCTION public.rpc_list_inventory_deduction_notes(BIGINT, INT) IS
  '庫存減抵單歷史清單（含明細行的訂單/顧客、作廢時間），減抵單頁面用。';
