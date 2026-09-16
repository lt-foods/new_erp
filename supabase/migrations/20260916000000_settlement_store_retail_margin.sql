-- ============================================================
-- 2026-09-16: 分店端月結對帳的「毛利」改成「售價 − 分店價」
--
-- 老闆定義的毛利分兩種、依登入身分看到不同價：
--   - 總倉：分店價 − 進貨成本（既有 cost_amount / line_amount，總倉端頁面已在用）
--   - 分店：售價（零售價）− 分店價（分店拿貨成本）
-- #956 把「分店價 − 總倉成本」給分店看是錯的：等於把總倉成本間接給分店。
-- 分店端改用本檔兩支函式取售價口徑，前端不再讀 unit_cost / line_amount。
--
-- 1. _retail_price_at(tenant, sku, at)：取 at 時點生效的零售價
--    （prices scope='retail'、scope_id IS NULL、price > 0），時點查無則 fallback
--    現行價；再無則 NULL。寫法逐字比照 _branch_price_at（20260715000000）。
-- 2. rpc_settlement_retail_lines(p_settlement_ids)：每個明細行的售價單價／售價小計。
--    正負號跟 branch_amount 同向（air_out / return_out / free_out 取負）。
--    自由轉貨行（description IS NOT NULL，虛擬 SKU）沒有售價 → NULL。
-- 3. rpc_settlement_retail_totals(p_settlement_ids)：每張結算單的
--    分店價合計、售價合計、沒有售價的行數（給列表頁算毛利，不用抓整批明細）。
--
-- 兩支 RPC 都是 SECURITY INVOKER：走 store_monthly_settlement_items 與 prices
-- 既有 RLS（分店帳號本來就讀得到自家明細與 retail scope 的價格）。
--
-- Rollback：
--   DROP FUNCTION public.rpc_settlement_retail_totals(BIGINT[]);
--   DROP FUNCTION public.rpc_settlement_retail_lines(BIGINT[]);
--   DROP FUNCTION public._retail_price_at(UUID, BIGINT, TIMESTAMPTZ);
-- ============================================================

CREATE OR REPLACE FUNCTION public._retail_price_at(
  p_tenant UUID,
  p_sku_id BIGINT,
  p_at     TIMESTAMPTZ
) RETURNS NUMERIC
LANGUAGE sql STABLE
AS $$
  SELECT COALESCE(
    (SELECT pr.price
       FROM public.prices pr
      WHERE pr.tenant_id    = p_tenant
        AND pr.sku_id       = p_sku_id
        AND pr.scope        = 'retail'
        AND pr.scope_id     IS NULL
        AND pr.price        > 0
        AND pr.effective_from <= p_at
        AND (pr.effective_to IS NULL OR pr.effective_to > p_at)
      ORDER BY pr.effective_from DESC
      LIMIT 1),
    (SELECT pr.price
       FROM public.prices pr
      WHERE pr.tenant_id    = p_tenant
        AND pr.sku_id       = p_sku_id
        AND pr.scope        = 'retail'
        AND pr.scope_id     IS NULL
        AND pr.price        > 0
        AND pr.effective_to IS NULL
      ORDER BY pr.effective_from DESC
      LIMIT 1)
  )
$$;

COMMENT ON FUNCTION public._retail_price_at(UUID, BIGINT, TIMESTAMPTZ) IS
  '取 at 時點生效的零售價（prices scope=retail）；查無則現行價；再無 NULL';

CREATE OR REPLACE FUNCTION public.rpc_settlement_retail_lines(p_settlement_ids BIGINT[])
RETURNS TABLE (
  settlement_id     BIGINT,
  item_id           BIGINT,
  unit_retail_price NUMERIC,
  retail_amount     NUMERIC
)
LANGUAGE sql STABLE
AS $$
  SELECT i.settlement_id,
         i.id,
         r.price,
         CASE WHEN r.price IS NULL THEN NULL
              ELSE (CASE WHEN i.entry_type IN ('air_out','return_out','free_out') THEN -1 ELSE 1 END)
                   * i.qty_received * r.price
         END
    FROM public.store_monthly_settlement_items i
    LEFT JOIN LATERAL (
      SELECT public._retail_price_at(i.tenant_id, i.sku_id, i.received_at) AS price
       WHERE i.description IS NULL
    ) r ON TRUE
   WHERE i.settlement_id = ANY (p_settlement_ids)
$$;

COMMENT ON FUNCTION public.rpc_settlement_retail_lines(BIGINT[]) IS
  '月結明細每行的售價單價／售價小計（分店端毛利＝售價 − 分店價用）；自由轉貨行 NULL';

CREATE OR REPLACE FUNCTION public.rpc_settlement_retail_totals(p_settlement_ids BIGINT[])
RETURNS TABLE (
  settlement_id BIGINT,
  branch_total  NUMERIC,
  retail_total  NUMERIC,
  missing_count INTEGER
)
LANGUAGE sql STABLE
AS $$
  SELECT l.settlement_id,
         COALESCE(SUM(i.branch_amount), 0),
         COALESCE(SUM(l.retail_amount), 0),
         COUNT(*) FILTER (WHERE l.retail_amount IS NULL AND i.description IS NULL)::INTEGER
    FROM public.rpc_settlement_retail_lines(p_settlement_ids) l
    JOIN public.store_monthly_settlement_items i ON i.id = l.item_id
   GROUP BY l.settlement_id
$$;

COMMENT ON FUNCTION public.rpc_settlement_retail_totals(BIGINT[]) IS
  '每張月結單的分店價合計／售價合計／缺售價行數（分店端列表算毛利用）';

GRANT EXECUTE ON FUNCTION public._retail_price_at(UUID, BIGINT, TIMESTAMPTZ) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_settlement_retail_lines(BIGINT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_settlement_retail_totals(BIGINT[]) TO authenticated;
