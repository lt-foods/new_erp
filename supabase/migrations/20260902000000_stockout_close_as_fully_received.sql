-- ============================================================
-- 20260902000000_stockout_close_as_fully_received.sql
--
-- 斷貨連坐鎖住整張單的貨（根治，修法 C）
-- 需求單／實作計畫：公司\01_進行中\需求暨計畫_斷貨連坐鎖貨根治_2026-08-19.md（§六-C、§七）
--
-- ── 病灶 ──────────────────────────────────────────────────
-- 一張採購單有品項斷貨、其餘品項全部收滿的那一刻，母單被自動設成 'closed'。
-- 但 'closed' 不在派貨需求 view 的白名單裡：
--   20260818000030_wave_transfer_join_by_id.sql:77
--     WHERE po.status = ANY (ARRAY['sent','partially_received','fully_received'])
-- ⇒ 已經收進總倉的貨從派貨工作台消失。
--    工作台撈這支 view 時是**雙條件**：
--      .eq("has_stock_left", true).eq("has_demand_left", true)
--      （apps/admin/src/app/(protected)/wms/picking/page.tsx:430-431；
--        草稿預填 apps/admin/src/lib/pickingDraftView.ts:406-407 / 1042-1043 / 1162-1163 同樣兩條）
--    ⛔ 不要只記 has_stock_left —— 2026-09-02 第一版就是漏了 has_demand_left，
--       害驗收 SQL 與畫面文案都寫成「有貨就會回到工作台」的偽陽性承諾（阿審 P1 抓到）。
--       貨要回得了工作台，必須「還有貨 **且** 還有客人／補貨在等」。
-- ⇒ 建不了撿貨波次（rpc_create_wave_from_po 也擋，20260816000050:297）
-- ⇒ 沒有 transfer ⇒ 客人取不到貨、月結收不到錢。
-- 正式庫實測（老闆 2026-09-01 晚）：16 張單、568 件貨卡在總倉，最久從 07-14。
--
-- ── 為什麼改成 fully_received 才是對的語意 ────────────────
-- 'fully_received' = 「該收的都收到了」。斷貨那項既然不會再來，該收的就只剩沒斷貨
-- 的那些，而它們確實都收齊了 —— 這張單的**收貨行為**確實結束了。
-- 而且 view 本來就為「標全到貨但實際短收」準備好欄位，不是硬湊：
--   20260818000030:241  qty_in_transit：po_status <> 'fully_received' 才算在途
--                       ⇒ 改完在途 = 0（正確，斷貨的不會來了）
--   20260818000030:245  qty_shortage ：po_status = 'fully_received' 且 gr_qty < qty_ordered
--                       ⇒ 改完自動算出短缺量（正確，確實短收）
--
-- ── ⛔ cancelled 那半不動 ─────────────────────────────────
-- 「完全沒到貨」（v_total_received = 0）仍然是 cancelled。那種單沒有任何貨卡著，
-- 讓它進派貨工作台只會製造雜訊 —— 這正是老闆 2026-08-26 的顧慮。
--
-- ── ⚠️ 本檔只改一支：_refresh_po_status ──────────────────
-- 全站還有另外兩支也會把斷貨母單寫成 'closed'（阿寫 2026-09-02 重新盤點時發現，
-- 8/19 的需求單只點名這一支）：
--   · rpc_adjust_po_item_received  20260801000000:551
--   · _stockout_po_items           20260812000000:468
-- 那兩支放在**同分支的 20260902000010**，可獨立取捨。⚠️ 只上本檔的話，
-- 「先收滿、最後才按斷貨」與「事後改已收量」這兩條路仍然會把單鎖回去。
--
-- ── 回滾 ─────────────────────────────────────────────────
-- 公司\01_進行中\斷貨修法C_回滾_2026-09-02.sql（把 20260801000000 版逐字貼回）
--
-- ── 基底 ─────────────────────────────────────────────────
-- 20260801000000_po_item_stockout.sql:370-401 逐字保留（本次重驗仍是最新版：
--   git grep -lnE "FUNCTION (public\.)?_refresh_po_status" origin/main -- supabase/migrations
--   → 20260422120004 / 20260801000000，最新 = 20260801000000）
-- 只改 :390 一行 closed → fully_received（外加同段一句過期註解）。
-- ============================================================

CREATE OR REPLACE FUNCTION _refresh_po_status(p_po_id BIGINT)
RETURNS VOID AS $$
DECLARE
  v_total_ordered  NUMERIC;
  v_total_received NUMERIC;
  v_outstanding    INTEGER;
  v_stockout_cnt   INTEGER;
  v_new_status     TEXT;
BEGIN
  SELECT SUM(qty_ordered), SUM(qty_received),
         COUNT(*) FILTER (WHERE stockout_at IS NULL
                            AND COALESCE(qty_received, 0) < qty_ordered),
         COUNT(*) FILTER (WHERE stockout_at IS NOT NULL)
    INTO v_total_ordered, v_total_received, v_outstanding, v_stockout_cnt
    FROM purchase_order_items WHERE po_id = p_po_id;

  IF v_total_received >= v_total_ordered THEN
    v_new_status := 'fully_received';
  ELSIF v_stockout_cnt > 0 AND v_outstanding = 0 THEN
    -- 品項斷貨收尾：其餘品項全數到貨 → 這張單的收貨行為結束
    --   有到貨 fully_received、全無 cancelled。
    --   ⚠️ 20260902000000 起由 closed 改成 fully_received：closed 不在派貨需求 view
    --      的白名單（20260818000030:77），會把已收到、還沒派出的貨鎖在總倉。
    --   ⛔ 不要改回 closed。
    v_new_status := CASE WHEN v_total_received > 0 THEN 'fully_received' ELSE 'cancelled' END;
  ELSIF v_total_received > 0 THEN
    v_new_status := 'partially_received';
  ELSE
    RETURN;
  END IF;

  UPDATE purchase_orders
     SET status = v_new_status, updated_at = NOW()
   WHERE id = p_po_id AND status IN ('sent','partially_received');
END;
$$ LANGUAGE plpgsql;
