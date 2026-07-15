-- ============================================================
-- 2026-07-15: 自由轉貨估價事後修正 rpc_update_free_transfer_amount
--
-- 需求（永和店月結對帳回報）：自由轉貨行的金額是店端轉貨當下手填的
-- 估價，月結對帳時發現跟實際分店價對不上；要能事後修正。
--
-- 設計：
--   - 只允許「自由轉貨」行（transfer_type='store_to_store' 且
--     customer_order_id IS NULL；估價入帳的那種）。
--   - 來源真相是 transfer_items.estimated_amount：月結生成器
--     （rpc_generate_hq_to_store_settlement，現行版 20260715000100）
--     重建 draft 時直接讀這個欄位，所以改這裡＋重跑生成器，
--     兩邊店（free_in / free_out 鏡像分錄）的 draft 會一起更新。
--   - 護欄：該行已收貨入帳的月份，只要出貨店或收貨店任一邊月結
--     已 confirmed/settled 就擋下（要改請走爭議流程，不能繞過已
--     確認的帳）。
--   - 修正軌跡：append 到 transfer_items.notes（[估價修正 日期]
--     $舊 → $新（原因）），updated_by 記操作人。
--   - 已收貨的行改完自動重跑該月生成器重建 draft；未收貨的行
--     （尚未入帳）只改估價、不動月結。
--
-- 新函式，無歷史版本。
-- Rollback：DROP FUNCTION public.rpc_update_free_transfer_amount(BIGINT, NUMERIC, UUID, TEXT);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_update_free_transfer_amount(
  p_transfer_item_id BIGINT,
  p_new_amount       NUMERIC,
  p_operator         UUID,
  p_reason           TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ti     RECORD;
  v_t      RECORD;
  v_month  DATE;
  v_old    NUMERIC;
  v_locked TEXT;
  v_regen  BOOLEAN := FALSE;
BEGIN
  IF p_new_amount IS NULL OR p_new_amount < 0 THEN
    RAISE EXCEPTION '估價需 >= 0（收到 %）', p_new_amount;
  END IF;

  SELECT * INTO v_ti FROM transfer_items WHERE id = p_transfer_item_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer_item % 不存在', p_transfer_item_id;
  END IF;

  SELECT * INTO v_t FROM transfers WHERE id = v_ti.transfer_id;

  -- 僅自由轉貨行可修：店↔店、無訂單 FK（有訂單的是空中轉、走成本入帳）
  IF v_t.transfer_type <> 'store_to_store' OR v_t.customer_order_id IS NOT NULL THEN
    RAISE EXCEPTION '調撥單 % 不是自由轉貨（type=%），此行不可修估價',
      v_t.transfer_no, v_t.transfer_type;
  END IF;

  v_old := COALESCE(v_ti.estimated_amount, 0);

  -- 已入帳月份任一邊已確認 → 擋
  IF v_t.status IN ('received','closed') AND v_t.received_at IS NOT NULL THEN
    v_month := DATE_TRUNC('month', v_t.received_at)::DATE;
    SELECT string_agg(st.name || '（' || s.status || '）', '、')
      INTO v_locked
      FROM store_monthly_settlements s
      JOIN stores st ON st.id = s.store_id
     WHERE s.tenant_id = v_t.tenant_id
       AND s.settlement_month = v_month
       AND s.status IN ('confirmed', 'settled')
       AND st.location_id IN (v_t.source_location, v_t.dest_location);
    IF v_locked IS NOT NULL THEN
      RAISE EXCEPTION '% 月結算已確認：%。已確認的帳不可改估價，請走爭議流程。',
        to_char(v_month, 'YYYY-MM'), v_locked;
    END IF;
  END IF;

  UPDATE transfer_items
     SET estimated_amount = p_new_amount,
         notes = TRIM(BOTH E'\n' FROM
           COALESCE(notes || E'\n', '')
           || '[估價修正 ' || to_char(NOW(), 'YYYY-MM-DD') || '] $'
           || trim_scale(v_old)::TEXT || ' → $' || trim_scale(p_new_amount)::TEXT
           || COALESCE('（' || NULLIF(TRIM(p_reason), '') || '）', '')),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_transfer_item_id;

  -- 已收貨 → 重跑該月生成器重建兩邊 draft（confirmed/settled 本來就跳過）
  IF v_month IS NOT NULL THEN
    PERFORM public.rpc_generate_hq_to_store_settlement(v_month, p_operator);
    v_regen := TRUE;
  END IF;

  RETURN jsonb_build_object(
    'transfer_item_id',        p_transfer_item_id,
    'transfer_no',             v_t.transfer_no,
    'old_amount',              v_old,
    'new_amount',              p_new_amount,
    'month',                   CASE WHEN v_month IS NULL THEN NULL
                                    ELSE to_char(v_month, 'YYYY-MM') END,
    'settlements_regenerated', v_regen
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_update_free_transfer_amount IS
  '修正自由轉貨行估價（transfer_items.estimated_amount）：僅限店↔店無訂單 FK 的'
  '自由轉貨行；該月任一邊月結已 confirmed/settled 則擋下；已收貨的行改完自動'
  '重跑該月 rpc_generate_hq_to_store_settlement 重建兩邊 draft；修正軌跡 append'
  '到 notes。';
