-- ============================================================
-- 2026-08-02: 互助貼文發佈後仍可改釋出單價 / 商品說明
--
-- 需求：admin 互助板點開貼文（ThreadModal）後要能編輯 spot_price /
--       spot_description（欄位由 20260802000000 引入），不用砍掉重發。
--       會員端 liff-api 讀取時本來就是每次現查這兩欄，改完即時生效。
--
-- rpc_update_aid_board_listing 為新函式，無歷史版本
-- （已 grep supabase/migrations/ 確認）。
--
-- 語意：兩個參數都是「這次要存成什麼」——
--   NULL = 清除自訂值，回到沿用原價 / 商品主檔原文。
--   前端每次送出完整狀態，不做部分更新（欄位就兩個，不值得引入
--   sentinel 區分「不動」與「清除」）。
--
-- 限制：只有 post_type='offer' 且 status='active' 能改。
--   到期/認領光/取消的貼文會員端本來就看不到，不開放改歷史紀錄。
--
-- Rollback：DROP FUNCTION public.rpc_update_aid_board_listing(BIGINT, UUID, NUMERIC, TEXT);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC DEFAULT NULL,
  p_spot_description TEXT    DEFAULT NULL
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_post_type TEXT;
  v_status    TEXT;
BEGIN
  IF p_spot_price IS NOT NULL AND p_spot_price <= 0 THEN
    RAISE EXCEPTION 'spot_price must be > 0';
  END IF;

  SELECT post_type, status INTO v_post_type, v_status
    FROM mutual_aid_board WHERE id = p_board_id
    FOR UPDATE;
  IF v_post_type IS NULL THEN
    RAISE EXCEPTION 'board post % not found', p_board_id;
  END IF;
  IF v_post_type <> 'offer' THEN
    RAISE EXCEPTION 'only offer posts have price/description';
  END IF;
  IF v_status <> 'active' THEN
    RAISE EXCEPTION 'post is % — only active posts can be edited', v_status;
  END IF;

  UPDATE mutual_aid_board
     SET spot_price       = p_spot_price,
         spot_description = NULLIF(trim(p_spot_description), ''),
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(BIGINT, UUID, NUMERIC, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明。NULL = 清除自訂值'
  '（回到沿用原價 / 商品主檔原文）。僅 active 的 offer 可改。';
