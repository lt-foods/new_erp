-- ============================================================
-- 2026-08-05: 每日進貨對帳明細 — 自由轉貨不要顯示「虛擬轉貨商品 MISC-01」
--
-- 問題：
--   自由轉貨（店轉店）的品項掛在虛擬 SKU（product_code='MISC' /
--   sku_code='MISC-01' / name='虛擬轉貨商品'）上，實際品名放在
--   transfer_items.description。原本的 rpc_store_inbound_day_items 用
--   COALESCE(sk.product_name, l.description)，虛擬 SKU 的 product_name
--   不是 NULL，所以明細每一行都印成「虛擬轉貨商品 MISC-01」，
--   店家看不出到底轉了什麼。
--
-- 修法：
--   join products 判斷 is_virtual —— 虛擬 SKU 一律用 description 當品名，
--   並且不回 sku_code / variant_name（那是佔位 SKU 的編號與規格，
--   對店家沒有意義、還會誤導）。非虛擬 SKU 行為完全不變。
--   （現網資料：description 只出現在虛擬 SKU 的 store_to_store 行，
--    共 177 筆且全部非空；其餘 17185 筆皆為 NULL。）
--
-- 基底版本：20260803000000_store_daily_inbound.sql（v1，本函式唯一版本）
-- Rollback：重跑 20260803000000 裡的 rpc_store_inbound_day_items 定義。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_store_inbound_day_items(
  p_store_id BIGINT,
  p_date     DATE
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_store  public.stores%ROWTYPE;
  v_from   TIMESTAMPTZ;
  v_to     TIMESTAMPTZ;
  v_items  JSONB;
  v_total  NUMERIC(18,4);
BEGIN
  SELECT * INTO v_store FROM public.stores WHERE id = p_store_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'store % not found', p_store_id;
  END IF;
  IF NOT (public._settlement_caller_is_hq() OR public._settlement_caller_in_store(p_store_id)) THEN
    RAISE EXCEPTION '無權查看此分店的進貨明細（store_id=%）', p_store_id;
  END IF;
  IF v_store.location_id IS NULL THEN
    RAISE EXCEPTION '分店 % 未設定倉別（location_id），無法計算進貨金額', v_store.name;
  END IF;

  v_from := (p_date)::TIMESTAMP AT TIME ZONE 'Asia/Taipei';
  v_to   := (p_date + 1)::TIMESTAMP AT TIME ZONE 'Asia/Taipei';

  WITH l AS (
    SELECT * FROM public._store_inbound_lines(p_store_id, v_from, v_to)
  )
  SELECT
    COALESCE(jsonb_agg(jsonb_build_object(
      'transfer_id',       l.transfer_id,
      'transfer_no',       t.transfer_no,
      'transfer_item_id',  l.transfer_item_id,
      'sku_id',            l.sku_id,
      -- 虛擬 SKU（自由轉貨佔位）不回編號/規格，品名改用 description
      'sku_code',          CASE WHEN COALESCE(pr.is_virtual, FALSE) THEN NULL ELSE sk.sku_code END,
      'product_name',      CASE WHEN COALESCE(pr.is_virtual, FALSE)
                                THEN COALESCE(NULLIF(btrim(l.description), ''), '自由轉貨品項')
                                ELSE COALESCE(sk.product_name, NULLIF(btrim(l.description), '')) END,
      'variant_name',      CASE WHEN COALESCE(pr.is_virtual, FALSE) THEN NULL ELSE sk.variant_name END,
      'qty',               l.qty,
      'unit_branch_price', l.unit_branch_price,
      'amount',            l.amount,
      'entry_type',        l.entry_type,
      'description',       l.description,
      -- 分店價沒設到（貨款行卻 0 元）→ 前端標示，提醒回報總部補價
      'missing_price',     (l.entry_type IN ('hq_inbound','air_in','air_out','return_out')
                            AND l.unit_branch_price = 0),
      'received_at',       l.received_at
    ) ORDER BY l.entry_type, l.received_at, l.transfer_item_id), '[]'::jsonb),
    COALESCE(SUM(l.amount), 0)
    INTO v_items, v_total
    FROM l
    LEFT JOIN public.transfers t ON t.id = l.transfer_id
    LEFT JOIN public.skus sk     ON sk.id = l.sku_id
    LEFT JOIN public.products pr ON pr.id = sk.product_id;

  RETURN jsonb_build_object(
    'store_id',   p_store_id,
    'store_name', v_store.name,
    'date',       to_char(p_date, 'YYYY-MM-DD'),
    'items',      v_items,
    'total',      v_total
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) IS
  '分店某日進貨明細（品項/數量/分店價/小計）＋當日總金額，日界 Asia/Taipei。'
  '口徑同月結對帳單（分店價），分店只能查自己店、HQ 可查全部。'
  '自由轉貨的虛擬 SKU 以 transfer_items.description 當品名，不回佔位 SKU 的編號/規格。';

GRANT EXECUTE ON FUNCTION public.rpc_store_inbound_day_items(BIGINT, DATE) TO authenticated;
