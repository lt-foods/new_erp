-- ============================================================================
-- 2026-08-19: 贈品從「訂單」下手 —— 整張單 / 一批訂單的 $0 品項一次標成贈品
--
-- 需求：「從訂單下手」。20260819000000 的開團層級（campaign_items.is_gift）對
--   「整個開團商品都是送的」才成立；促銷實務上贈品是掛在**個別訂單**上的
--   （同一個 SKU 有人買、有人是送的），開團層級一標就把所有人的單價歸零，
--   買的那幾張也跟著變 $0。所以主要入口改成訂單側：
--     - 訂單明細：一鍵把這張單的 $0 品項全標成贈品
--     - 訂單列表：篩「只看 $0」＋開團／門市 → 選取 → 批次標記（促銷一次收掉）
--   逐列標記維持 rpc_mark_order_item_gift（櫃台當場那一顆）。
--
-- 這支只是上面那支的批次版，判定與守衛完全一樣：
--   - 權限逐張走 _check_order_edit_notes_perm（HQ / 總倉 / 自店）——
--     選到別人家的單會整批擋下並指名是哪一張，不會默默略過。
--   - 只動未取貨（pending/reserved/ready）、單價 $0、還沒標過的列。
--   - 【內部】xx 店 / RR- / OV- 容器單（member_type='store_internal'）跳過：
--     那些 $0 是掛帳用的，本來就不受零元守衛限制，標了只是製造雜訊。
--   - 已被開團層級標成贈品的列跳過（本來就免除守衛，重複標沒有意義）。
--   - 理由必填，每一列寫一筆 customer_order_audit_log（field='is_gift'）。
--   - 一次最多 500 張（對齊列表「選全部」的 SELECT_ALL_MAX）。
--
-- 前置：20260819000000（欄位 / rpc_mark_order_item_gift / audit CHECK 擴充）
-- Rollback：DROP FUNCTION public.rpc_mark_zero_price_items_gift(BIGINT[],UUID,TEXT);
--
-- 對應前端（同一個 commit）：
--   - apps/admin/src/app/(protected)/orders/page.tsx（選取後「🎁 標為贈品」）
--   - apps/admin/src/components/OrderDetail.tsx（整單 $0 一鍵標記）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_mark_zero_price_items_gift(
  p_order_ids BIGINT[],
  p_operator  UUID,
  p_reason    TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason   TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_ids      BIGINT[];
  v_id       BIGINT;
  v_order    customer_orders%ROWTYPE;
  v_n        INT;
  v_items    INT := 0;
  v_orders   INT := 0;
  v_internal INT := 0;
BEGIN
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'gift_mark: 請填寫贈品原因（例：週年慶滿額贈 / 買二送一），這筆會留在每一列的異動紀錄裡';
  END IF;

  v_ids := ARRAY(SELECT DISTINCT x FROM unnest(COALESCE(p_order_ids, ARRAY[]::BIGINT[])) AS x);
  IF array_length(v_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'gift_mark: 沒有選到訂單';
  END IF;
  IF array_length(v_ids, 1) > 500 THEN
    RAISE EXCEPTION 'gift_mark: 一次最多處理 500 張訂單（選到 % 張），請再縮小篩選範圍',
      array_length(v_ids, 1);
  END IF;

  FOREACH v_id IN ARRAY v_ids LOOP
    -- 權限 + 鎖單頭。不是自己店的單直接 raise（訊息會指名是哪一張），
    -- 不做「默默略過」——批次動作最怕的就是以為標了其實沒標。
    v_order := public._check_order_edit_notes_perm(v_id);

    IF EXISTS (
      SELECT 1 FROM members mb
       WHERE mb.id = v_order.member_id
         AND mb.tenant_id = v_order.tenant_id
         AND mb.member_type = 'store_internal'
    ) THEN
      v_internal := v_internal + 1;
      CONTINUE;
    END IF;

    WITH upd AS (
      UPDATE customer_order_items coi
         SET is_gift        = TRUE,
             gift_reason    = v_reason,
             gift_marked_by = p_operator,
             gift_marked_at = NOW(),
             updated_by     = p_operator,
             updated_at     = NOW()
       WHERE coi.order_id = v_id
         AND coi.status IN ('pending','reserved','ready')
         AND COALESCE(coi.unit_price, 0) = 0
         AND NOT COALESCE(coi.is_gift, FALSE)
         -- 開團層級已經標成贈品的列本來就免除守衛，不重複標
         AND NOT EXISTS (
           SELECT 1 FROM campaign_items gi
            WHERE gi.id = coi.campaign_item_id AND gi.is_gift
         )
       RETURNING coi.id
    ), logged AS (
      -- 資料異動型 CTE 一定會跑完（不管主查詢有沒有讀它），所以逐列稽核就寫在這裡
      INSERT INTO customer_order_audit_log
        (tenant_id, order_id, entity_type, entity_id, field,
         before_value, after_value, edit_reason, operator_id)
      SELECT v_order.tenant_id, v_id, 'item', u.id, 'is_gift',
             to_jsonb(FALSE), to_jsonb(TRUE), v_reason, p_operator
        FROM upd u
      RETURNING 1
    )
    SELECT count(*)::int INTO v_n FROM upd;

    IF v_n > 0 THEN
      v_orders := v_orders + 1;
      v_items  := v_items + v_n;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'requested_orders', array_length(v_ids, 1),
    'orders',           v_orders,
    'items',            v_items,
    'skipped_internal', v_internal
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_mark_zero_price_items_gift(BIGINT[], UUID, TEXT) IS
  '批次把選取訂單裡「未取貨且單價 $0」的品項標成贈品（免除取貨零元守衛）。'
  '理由必填、逐列寫 customer_order_audit_log(field=is_gift)、逐張走'
  ' _check_order_edit_notes_perm（HQ / 總倉 / 自店，不是自己店的單整批 raise）。'
  '跳過 store_internal 容器單與已被開團層級標成贈品的列；一次最多 500 張。'
  '回 {requested_orders, orders, items, skipped_internal}。';

GRANT EXECUTE ON FUNCTION public.rpc_mark_zero_price_items_gift(BIGINT[], UUID, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- rpc_set_campaign_item_gift v2 —— 開團層級只留給「整項都是送的」
--
-- 基底：20260819000000（逐字保留，只多一道守衛）。
-- 為什麼要加：開團層級標贈品會把 campaign_items.unit_price 設為 0，之後所有
-- 新建訂單的那一項都是 $0。促銷常見的「買二送一」是同一個 SKU 有人買、有人送，
-- 整項標下去等於把還沒建的訂單全部變成免費 —— 這種要從訂單那邊標
-- （rpc_mark_zero_price_items_gift / rpc_mark_order_item_gift）。
-- 所以：該開團商品只要還有「有金額」的未取貨訂單品項，就擋下並指路。
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.rpc_set_campaign_item_gift(
  p_campaign_item_id BIGINT,
  p_is_gift          BOOLEAN,
  p_reason           TEXT DEFAULT NULL
) RETURNS campaign_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  -- 應用角色一律讀 app_metadata；頂層 role 永遠是 'authenticated'（見 CLAUDE.md）
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_paid   INT;
  v_row    campaign_items;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION 'campaign_gift: 權限不足，只有管理員可以把開團商品設為贈品（role=%）', v_role;
  END IF;

  IF p_is_gift AND v_reason IS NULL THEN
    RAISE EXCEPTION 'campaign_gift: 請填寫贈品原因（例：週年慶滿額贈），會顯示在開團商品與訂單品項上';
  END IF;

  -- 已經有人按原價買的，就不是「整項都是送的」→ 擋下，改走訂單側
  IF p_is_gift THEN
    SELECT count(*)::int INTO v_paid
      FROM customer_order_items coi
     WHERE coi.campaign_item_id = p_campaign_item_id
       AND coi.status IN ('pending','reserved','ready')
       AND COALESCE(coi.unit_price, 0) > 0;
    IF v_paid > 0 THEN
      RAISE EXCEPTION 'campaign_gift: 這個開團商品還有 % 筆未取貨的訂單品項是有金額的（客人是買的）。整項設成贈品會把之後建立的訂單全部變成 $0；只有部分客人要送的話，請到訂單那邊標贈品（訂單明細「🎁 整單標成贈品」，或訂單列表篩「只看 $0」後批次標記）',
        v_paid;
    END IF;
  END IF;

  -- 標成贈品＝單價設 0（贈品不收錢），並從此不再被「重新同步商品/價格」與
  -- 零售價 trigger 蓋回零售價。取消標記時單價維持 0，要恢復售價請按
  -- 「重新同步商品/價格」（既有訂單的金額是 snapshot，兩個方向都不會被改動）。
  UPDATE campaign_items
     SET is_gift     = p_is_gift,
         gift_reason = CASE WHEN p_is_gift THEN v_reason ELSE NULL END,
         unit_price  = CASE WHEN p_is_gift THEN 0 ELSE unit_price END,
         updated_by  = auth.uid(),
         updated_at  = NOW()
   WHERE id = p_campaign_item_id AND tenant_id = v_tenant
   RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'campaign_gift: 開團商品 % 不在 tenant 內', p_campaign_item_id;
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.rpc_set_campaign_item_gift(BIGINT, BOOLEAN, TEXT) IS
  '把開團商品標成贈品（整項都是送的才適用）：is_gift=TRUE + 單價設 0 + 理由必填。'
  '效果＝該開團商品的所有 $0 訂單品項（既有與未來）免除取貨零元守衛，'
  '且 rpc_resync_campaign_from_product 與 _sync_retail_price_to_campaigns 都不再改它的單價。'
  '管理員限定（app_metadata.role ∈ owner / admin / 空字串）。取消標記不會自動恢復售價。'
  '20260819000010：該商品還有「有金額」的未取貨訂單品項時擋下（買二送一那種混合情況'
  '要走訂單側的 rpc_mark_zero_price_items_gift / rpc_mark_order_item_gift）。';

GRANT EXECUTE ON FUNCTION public.rpc_set_campaign_item_gift(BIGINT, BOOLEAN, TEXT)
  TO authenticated;
