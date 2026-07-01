-- ============================================================
-- rpc_channel_bound_member_ids：回傳「這批會員裡，已在指定 LINE 頻道綁過暱稱」的會員 id。
--
-- 為什麼要另開一支：小幫手加單頁的 rpc_search_aliases 是用「暱稱 ILIKE 搜尋字串」在濾，
-- 所以當店員用會員編號 / 姓名（例：259405）搜尋、而該會員綁定的暱稱不含這串字時，
-- 該 alias 不會被回傳，前端 `aliased` 判斷失準，導致「+綁」按鈕對「已綁定」的會員又冒出來，
-- 再按下去就會產生重複綁定。這支 RPC 不吃搜尋字串，只針對「當前結果的 member ids」查是否已綁，
-- 讓前端能穩定地把已綁會員的「+綁」按鈕收起來。
--
-- 併檔處理：alias.member_id 可能指向已被合併的舊檔，沿 merged_into_member_id 追到 active 目標
-- （最多 5 跳），與 rpc_search_members / rpc_search_aliases 的解法一致，回傳解算後的目標 id。
--
-- 基底：無（全新 function）。rollback：DROP FUNCTION public.rpc_channel_bound_member_ids(BIGINT, BIGINT[]);
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_channel_bound_member_ids(
  p_channel_id BIGINT,
  p_member_ids BIGINT[]
) RETURNS TABLE (member_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
BEGIN
  IF p_channel_id IS NULL
     OR p_member_ids IS NULL
     OR COALESCE(array_length(p_member_ids, 1), 0) = 0 THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH RECURSIVE aliased AS (
    SELECT a.member_id AS source_id, m.id AS target_id,
           m.status, m.merged_into_member_id, 0 AS hop
      FROM customer_line_aliases a
      JOIN members m ON m.id = a.member_id
     WHERE a.tenant_id  = v_tenant
       AND a.channel_id = p_channel_id
    UNION ALL
    SELECT r.source_id, m.id, m.status, m.merged_into_member_id, r.hop + 1
      FROM aliased r
      JOIN members m ON m.id = r.merged_into_member_id
     WHERE r.status = 'merged'
       AND r.merged_into_member_id IS NOT NULL
       AND r.hop < 5
  ),
  resolved AS (
    SELECT DISTINCT ON (source_id) target_id, status
      FROM aliased
     ORDER BY source_id, hop DESC
  )
  SELECT DISTINCT r.target_id
    FROM resolved r
   WHERE r.status NOT IN ('merged', 'deleted')
     AND r.target_id = ANY(p_member_ids);
END;
$$;
GRANT EXECUTE ON FUNCTION public.rpc_channel_bound_member_ids TO authenticated;
