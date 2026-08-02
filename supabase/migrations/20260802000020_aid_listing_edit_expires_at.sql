-- ============================================================
-- 2026-08-02: 互助貼文發佈後也能改到期時間
--
-- 需求：admin 互助板點開貼文 →「✏️ 修改內容」除了單價 / 商品說明，
--       到期日也要能改（例如貨還在、想延長曝光；或提早收回）。
--
-- 變動：rpc_update_aid_board_listing 加 p_expires_at。
--
-- 基底版本：20260802000010_rpc_update_aid_board_listing.sql
--   （已 grep supabase/migrations/ 確認：那是唯一動過此函式的 migration，
--    本檔基於它擴寫，原有的 offer/active 檢查與 NULL 語意一字未改）
--
-- ⚠ p_expires_at 的 NULL 語意和另外兩個參數**不同**：
--   spot_price / spot_description 的 NULL = 清除自訂值（回沿用原價 / 原文）；
--   expires_at 是 NOT NULL 欄位、沒有「沿用」的概念 → NULL = 不動它。
--   前端一律會帶值，這個分支只是防呆。
--
-- 為何 DROP 再 CREATE：參數個數變了（4 → 5），CREATE OR REPLACE 會多出
--   overload，之後具名呼叫撞 "function is not unique"。
--   新參數有 DEFAULT，已部署的舊前端送 4 個具名參數仍解得到，無空窗。
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(
--     BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ);
--   -- 重跑 20260802000010 整支
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_update_aid_board_listing(BIGINT, UUID, NUMERIC, TEXT);

CREATE OR REPLACE FUNCTION public.rpc_update_aid_board_listing(
  p_board_id         BIGINT,
  p_operator         UUID,
  p_spot_price       NUMERIC     DEFAULT NULL,
  p_spot_description TEXT        DEFAULT NULL,
  p_expires_at       TIMESTAMPTZ DEFAULT NULL
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
  -- 到期時間可以往後延，也可以縮短，但不能設到過去
  -- （設到過去等於立刻下架，那是「結束此貼」該做的事，語意分開）
  IF p_expires_at IS NOT NULL AND p_expires_at <= NOW() THEN
    RAISE EXCEPTION 'expires_at must be in the future';
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
         -- NULL = 不動（expires_at 是 NOT NULL，沒有「清除」的語意）
         expires_at       = COALESCE(p_expires_at, expires_at),
         updated_by       = p_operator
   WHERE id = p_board_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_aid_board_listing(
  BIGINT, UUID, NUMERIC, TEXT, TIMESTAMPTZ) TO authenticated;

COMMENT ON FUNCTION public.rpc_update_aid_board_listing IS
  '互助板 offer 貼文發佈後編輯釋出單價 / 商品說明 / 到期時間。'
  'spot_price、spot_description 的 NULL = 清除自訂值（回沿用原價 / 商品主檔原文）；'
  'expires_at 的 NULL = 不動（該欄 NOT NULL），且不得設到過去。僅 active 的 offer 可改。';
