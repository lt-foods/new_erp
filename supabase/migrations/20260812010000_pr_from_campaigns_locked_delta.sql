-- ============================================================================
-- 2026-08-12: 針對團購建單 — 接受已鎖定 (locked) 的團 + 品項只帶未請購差額
-- ----------------------------------------------------------------------------
-- 實案（2026-08-12 使用者回報）：8/11 結單的「一次性隔髒墊」在
-- 「針對團購建單」modal 搜不到。原因鏈：
--   1. 結單日 8/11 的團分批結單，白天建的 close_date PR（含補單）當下
--      只吃 status='closed' 的團；晚上 23:59 才自動結單的團不在裡面。
--   2. 隔天早上建結單日補單（rpc_create_supplementary_pr_from_close_date）
--      時這些團被納入並整批推成 'locked'（20260714000060 鎖團尾巴）。
--   3. modal 前端只列 status='closed'，rpc_create_pr_from_campaigns 守衛的
--      允許清單 ('closed','ordered','receiving','ready','completed') 也獨漏
--      'locked'（本函式寫於 20260513，早於 20260625000000 引入鎖團）——
--      團一被鎖就從 modal 消失，也無法從這條路補單，操作者無從確認
--      「結單的商品到底進了哪張請購單」。
--
-- 本 migration：CREATE OR REPLACE rpc_create_pr_from_campaigns v2
--   基底：20260513000001（唯一前版；已比對線上版本一致）。
--   1. 守衛允許清單加入 'locked'。
--   2. 品項數量改為「補單差額」：
--        delta(sku) = 所選團目前訂單需求(sku)
--                   − 該團結單日所有『未取消 close_date PR』已請購量(sku)
--      算法對齊 rpc_create_supplementary_pr_from_close_date /
--      rpc_list_supplementable_close_dates（單一真相），差在範圍縮到所選團的
--      SKU。已被結單日 PR 涵蓋的量自動歸零剔除 → 重複選團不會重複下單
--      （modal 本來就標榜「同團購可重複開單（補單）」，v1 會整份需求重抓）。
--      註：同一結單日內沒有 SKU 橫跨多個團（線上 2,514 組 (sku,結單日) 全數
--      單一團），SKU 層級沖銷不會把別團的請購量錯算到所選團頭上。
--      跨結單日各自沖銷自己那天的 close_date PR；同 SKU 跨日合併成一列
--      （避免同 PR 重複 SKU 列干擾下游依 SKU 的彙總）。
--   3. 差額全為 0 → RAISE（不留空 PR、不浪費 pr_no），訊息直接顯示在前端。
--   4. purchase_request_campaigns 一律寫入全部所選團（含差額 0 者），
--      比照 20260714000060「顯式補全」的先例，取貨聚合閘門才看得到連結。
--
-- 故意不動：
--   - 不鎖團、不 auto-confirm 訂單（沿用 v1；差額制下重複建單不會重複算量，
--     closed 的團維持可加單/改 qty 的語意）。
--   - rpc_create_pr_from_close_date / rpc_append_campaign_to_pr / 補單雙函式。
--   - 供應商帶入維持函式內 LATERAL + trg_pri_fill_default_supplier fallback
--     （20260709000030）雙保險。
--
-- Rollback：重跑 20260513000001 的 rpc_create_pr_from_campaigns 定義。
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_pr_from_campaigns(
  p_campaign_ids BIGINT[],
  p_operator     UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant         UUID := public._current_tenant_id();
  v_pr_id          BIGINT;
  v_pr_no          TEXT;
  v_dest_loc       BIGINT;
  v_delta_count    INTEGER;
  v_min_close_date DATE;
BEGIN
  IF p_campaign_ids IS NULL OR array_length(p_campaign_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_campaign_ids is empty';
  END IF;

  -- 守衛：所有 campaigns 都必須屬同 tenant 且已結單（v2：補上 'locked'）
  IF EXISTS (
    SELECT 1 FROM group_buy_campaigns
     WHERE id = ANY(p_campaign_ids)
       AND (tenant_id <> v_tenant
            OR status NOT IN ('closed','locked','ordered','receiving','ready','completed'))
  ) THEN
    RAISE EXCEPTION 'some campaigns not in tenant or not closed yet';
  END IF;

  -- 取最小 close_date 作 source_close_date（向下相容用、實際資料看 join 表）
  SELECT MIN(DATE(end_at AT TIME ZONE 'Asia/Taipei')) INTO v_min_close_date
    FROM group_buy_campaigns
   WHERE id = ANY(p_campaign_ids);

  -- dest location
  SELECT id INTO v_dest_loc FROM locations WHERE tenant_id = v_tenant ORDER BY id LIMIT 1;
  IF v_dest_loc IS NULL THEN
    RAISE EXCEPTION 'no locations defined';
  END IF;

  -- v2：先算差額（目前需求 − 該團結單日所有未取消 close_date PR 已請購量），
  -- 空的話直接 RAISE，不浪費 pr_no、不留殘 header（比照 20260714000060 補單）。
  CREATE TEMP TABLE _camp_pr_delta ON COMMIT DROP AS
  WITH sel AS (
    SELECT id, DATE(end_at AT TIME ZONE 'Asia/Taipei') AS close_date
      FROM group_buy_campaigns
     WHERE id = ANY(p_campaign_ids)
  ),
  demand AS (
    SELECT
      coi.sku_id,
      s.close_date,
      MIN(co.campaign_id) AS first_campaign_id,
      SUM(coi.qty)        AS qty
      FROM sel s
      JOIN customer_orders co        ON co.campaign_id = s.id
      JOIN customer_order_items coi  ON coi.order_id = co.id
     WHERE co.tenant_id = v_tenant
       AND co.status  NOT IN ('cancelled','expired','transferred_out')
       AND coi.status NOT IN ('cancelled','expired')
     GROUP BY coi.sku_id, s.close_date
  ),
  already AS (
    SELECT pri.sku_id, pr.source_close_date AS close_date, SUM(pri.qty_requested) AS qty
      FROM purchase_requests pr
      JOIN purchase_request_items pri ON pri.pr_id = pr.id
     WHERE pr.tenant_id = v_tenant
       AND pr.source_type = 'close_date'
       AND pr.source_close_date IN (SELECT DISTINCT close_date FROM sel)
       AND pr.status <> 'cancelled'
     GROUP BY 1, 2
  )
  -- 同 SKU 跨結單日合併成一列（差額各自沖銷完再相加）
  SELECT
    d.sku_id,
    MIN(d.first_campaign_id) AS first_campaign_id,
    SUM(GREATEST(d.qty - COALESCE(a.qty, 0), 0)) AS delta_qty
    FROM demand d
    LEFT JOIN already a
           ON a.sku_id = d.sku_id AND a.close_date = d.close_date
   GROUP BY d.sku_id
  HAVING SUM(GREATEST(d.qty - COALESCE(a.qty, 0), 0)) > 0;

  SELECT COUNT(*) INTO v_delta_count FROM _camp_pr_delta;

  IF v_delta_count = 0 THEN
    RAISE EXCEPTION '所選團購的需求已全數納入既有請購單（結單日 close_date PR），沒有可補的請購量';
  END IF;

  -- PR header（source_type 沿用 close_date、close_date 取最小值 — v1 相容）
  v_pr_no := public.rpc_next_pr_no();

  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_pr_no, 'close_date', v_min_close_date,
    v_dest_loc, 'draft', 0,
    '針對團購建單（僅帶尚未請購的差額）',
    p_operator, p_operator
  ) RETURNING id INTO v_pr_id;

  -- 寫入 join 表：全部所選團（含差額 0 者；trigger 只會補有品項的那幾團）
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_pr_id, unnest(p_campaign_ids), v_tenant
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  -- 差額 → PR items（含售價 snapshot，沿用 v1）
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested,
    suggested_supplier_id, unit_cost,
    retail_price, franchise_price,
    source_campaign_id,
    created_by, updated_by
  )
  SELECT
    v_pr_id, dq.sku_id, dq.delta_qty,
    ss.supplier_id, COALESCE(ss.default_unit_cost, 0),
    pr_retail.price, pr_franchise.price,
    dq.first_campaign_id, p_operator, p_operator
  FROM _camp_pr_delta dq
  LEFT JOIN LATERAL (
    SELECT supplier_id, default_unit_cost
      FROM supplier_skus
     WHERE tenant_id = v_tenant AND sku_id = dq.sku_id AND is_preferred = TRUE
     LIMIT 1
  ) ss ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices WHERE sku_id = dq.sku_id AND scope = 'retail'
     ORDER BY effective_from DESC NULLS LAST LIMIT 1
  ) pr_retail ON TRUE
  LEFT JOIN LATERAL (
    SELECT price FROM prices WHERE sku_id = dq.sku_id AND scope = 'franchise'
     ORDER BY effective_from DESC NULLS LAST LIMIT 1
  ) pr_franchise ON TRUE;

  -- total snapshot
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(line_subtotal) FROM purchase_request_items WHERE pr_id = v_pr_id
         ), 0),
         updated_at = NOW()
   WHERE pr.id = v_pr_id;

  RETURN v_pr_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_pr_from_campaigns(BIGINT[], UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_pr_from_campaigns IS
  '從多選 campaigns 建 PR（v2, 20260812010000）：接受 closed/locked/ordered/receiving/ready/completed；'
  '品項只帶「目前需求 − 該團結單日未取消 close_date PR 已請購量」的差額（對齊結單日補單算法），'
  '差額全 0 → RAISE、不留空單。不鎖團、不 auto-confirm（重複建單不重複算量）。';
