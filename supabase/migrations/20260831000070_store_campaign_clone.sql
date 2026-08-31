-- ============================================================================
-- 店家自開團：常態團「再開一團」
-- ============================================================================
-- 需求（Alex 2026-08-31）：
--   「我有常態要開團的，可能是豆漿，關團就結單，但我過陣子可以再開。」
--   「再開不要用同一個團，要再開新的團，因為訂單有可能會錯亂。」
--
-- 所以只有一個動作：rpc_clone_store_campaign —— 把一個自開團複製成**新的一團**
--   （新團號），帶團名 / 收單類型 / 上限 / 封面 / 說明 / 全部品項與售價，
--   不帶訂單、收貨、以及上一輪的履約狀態。舊團原封不動。
--   店長開下一輪豆漿團不用重打任何東西。
--
-- 為什麼一定要新的一團，不是把同一團反覆開關（老闆的直覺是對的，而且技術上
-- 也非做不可）：自開團的每一筆帳都掛在 campaign id 上 ——
--   * _store_campaign_demand 的「已收」＝掛在該團的入庫異動總和
--   * _pickup_group_supplied 的供給側也是同一份
-- 同一團開第二輪的話，第一輪收的貨會被算成第二輪的供給：
-- 需求 5、已收 10（第一輪的）→ 未收 0 → **第二輪永遠不會出現在收貨頁**，
-- 而取貨閘門那邊卻覺得供給充足。訂單也會兩輪混在同一個團底下分不開。
-- 一團一輪，帳才切得乾淨；日結的「店家自開團結算」也才分得出哪一輪賺多少。
--
-- ⚠ 因此本檔**刻意不提供**「把已結單的團退回開團中」的函式。
--   先前草稿有一支 rpc_reopen_store_campaign，依老闆指示拿掉，
--   並在本檔一併 DROP（它今天曾被套上正式庫，沒有任何呼叫端）。
--
-- Rollback：DROP FUNCTION public.rpc_clone_store_campaign(BIGINT, TEXT, TIMESTAMPTZ, DATE, TEXT);
-- ============================================================================

-- 先前草稿的產物，沒有呼叫端；一團一輪的原則不允許它存在
DROP FUNCTION IF EXISTS public.rpc_reopen_store_campaign(BIGINT, UUID);

-- ----------------------------------------------------------------------------
-- rpc_clone_store_campaign — 再開一團（常態團的唯一做法）
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_clone_store_campaign(
  p_campaign_id     BIGINT,
  p_name            TEXT        DEFAULT NULL,
  p_end_at          TIMESTAMPTZ DEFAULT NULL,
  p_pickup_deadline DATE        DEFAULT NULL,
  p_status          TEXT        DEFAULT 'open'
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_src    group_buy_campaigns%ROWTYPE;
  v_id     BIGINT;
  v_no     TEXT;
  v_items  INT;
BEGIN
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'insufficient_role: % 不能開團', v_role;
  END IF;

  IF p_status NOT IN ('draft','open') THEN
    RAISE EXCEPTION 'p_status must be draft or open, got %', p_status;
  END IF;

  SELECT * INTO v_src FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign % not in tenant', p_campaign_id;
  END IF;
  IF v_src.owner_store_id IS NULL THEN
    RAISE EXCEPTION 'campaign % 不是店家自開團，請用總倉的開團流程', p_campaign_id;
  END IF;
  PERFORM public._assert_own_store(v_src.owner_store_id);

  IF v_src.close_type = 'fast' AND p_end_at IS NULL THEN
    RAISE EXCEPTION 'fast campaign requires end_at';
  END IF;

  v_no := public.rpc_next_campaign_no();

  INSERT INTO group_buy_campaigns (
    tenant_id, campaign_no, name, description, cover_image_url,
    status, close_type, start_at, end_at, pickup_deadline, pickup_days,
    total_cap_qty, is_for_shop, sales_channel, owner_store_id,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_no, COALESCE(NULLIF(btrim(p_name), ''), v_src.name),
    v_src.description, v_src.cover_image_url,
    p_status, v_src.close_type, NOW(),
    p_end_at, p_pickup_deadline, v_src.pickup_days,
    v_src.total_cap_qty, v_src.is_for_shop, 'main', v_src.owner_store_id,
    auth.uid(), auth.uid()
  ) RETURNING id INTO v_id;

  -- 品項：只複製「賣什麼、賣多少錢」。刻意不帶 locked_at / stockout_at /
  -- stockout_po_id —— 那些是上一輪的履約狀態，新的一輪從乾淨的開始。
  INSERT INTO campaign_items (
    tenant_id, campaign_id, sku_id, unit_price, cap_qty, sort_order,
    notes, is_gift, gift_reason, created_by, updated_by
  )
  SELECT v_tenant, v_id, ci.sku_id, ci.unit_price, ci.cap_qty, ci.sort_order,
         ci.notes, ci.is_gift, ci.gift_reason, auth.uid(), auth.uid()
    FROM campaign_items ci
   WHERE ci.campaign_id = p_campaign_id
     AND ci.tenant_id   = v_tenant
     AND ci.stockout_at IS NULL;   -- 上一輪斷貨的品項不要再帶進來

  GET DIAGNOSTICS v_items = ROW_COUNT;
  IF v_items = 0 THEN
    RAISE EXCEPTION '來源團沒有可複製的品項';
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.rpc_clone_store_campaign(BIGINT, TEXT, TIMESTAMPTZ, DATE, TEXT) IS
  '把一個店家自開團複製成新的一團（常態團的下一輪）：帶團名 / 收單類型 / 上限 / '
  '封面 / 說明 / 品項與售價，不帶訂單、收貨與上一輪的履約狀態。'
  '一團一輪，帳才切得乾淨（見檔頭）。';

REVOKE ALL ON FUNCTION public.rpc_clone_store_campaign(BIGINT, TEXT, TIMESTAMPTZ, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_clone_store_campaign(BIGINT, TEXT, TIMESTAMPTZ, DATE, TEXT) TO authenticated;
