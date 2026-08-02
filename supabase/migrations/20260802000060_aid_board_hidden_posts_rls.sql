-- ============================================================
-- 2026-08-02: 設為不公開的互助貼文，後台也只有該店看得到（含管理員）
--
-- 需求：20260802000050 的「其他分店的會員也看得到」開關關掉之後，
--       目前只擋會員端（liff-api）。後台互助交流板每個帳號還是全看得到。
--       要改成：**只有該店的帳號看得到，連 admin / hq_manager / owner 都不行。**
--
-- 做法：收緊 mutual_aid_board 的 SELECT RLS。後台是拿使用者 session 直接查表，
--       所以 RLS 就是唯一該動的地方 —— 前端過濾擋不住直接打 PostgREST。
--
-- ⚠ 兩個一定要一起處理，不然等於沒做：
--
--   1. **`aid_board_owner_write` 是 FOR ALL**。permissive policy 之間是 OR，
--      FOR ALL 連 SELECT 都放行 —— 只改 read policy 的話，owner/admin/hq_manager
--      照樣從那條看得到。這裡把它拆成 INSERT / UPDATE / DELETE 三條，
--      **predicate 一字未改**，只是不再涵蓋 SELECT。
--      （寫入本來就都走 SECURITY DEFINER RPC，這個拆法對 app 沒有行為影響。）
--
--   2. **`mutual_aid_replies` 的 replies_read_all 也是 tenant 全開**。貼文藏起來
--      但留言撈得到，等於從側門把內容漏出去。一起套同一條可見性判斷。
--
-- 「該店」怎麼判定：JWT 的 stores（店名陣列）裡有沒有該貼文釋出店的名字。
--   這是本 repo 既有的慣例 —— rpc_aid_board_active_count（20260720000030）
--   就是這樣認分店帳號的，沒有 store_id claim 可用。
--   ⚠ 副作用：門市**改名**會讓舊帳號暫時看不到自己店的不公開貼文，
--     直到該帳號的 app_metadata.stores 一起更新。之後若補上 store_id claim，
--     把 can_see_aid_post() 換成用 id 比對即可，policy 本身不用動。
--
-- 沒有動到的：
--   - 公開貼文（spot_visible_to_other_stores = TRUE，也就是絕大多數）行為完全不變
--   - 會員端 liff-api 走 service_role，繞過 RLS，維持 20260802000050 的過濾
--   - purge cron 也是 service_role，不受影響
--
-- Rollback：
--   DROP POLICY IF EXISTS aid_board_read_all   ON mutual_aid_board;
--   DROP POLICY IF EXISTS aid_board_owner_insert ON mutual_aid_board;
--   DROP POLICY IF EXISTS aid_board_owner_update ON mutual_aid_board;
--   DROP POLICY IF EXISTS aid_board_owner_delete ON mutual_aid_board;
--   DROP POLICY IF EXISTS replies_read_all     ON mutual_aid_replies;
--   CREATE POLICY aid_board_read_all ON mutual_aid_board FOR SELECT
--     USING (tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid);
--   CREATE POLICY aid_board_owner_write ON mutual_aid_board FOR ALL
--     USING (tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
--            AND (offering_store_id = ((auth.jwt() ->> 'store_id'))::bigint
--                 OR (auth.jwt() ->> 'role') = ANY (ARRAY['owner','admin','hq_manager'])));
--   CREATE POLICY replies_read_all ON mutual_aid_replies FOR SELECT
--     USING (tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid);
--   DROP FUNCTION IF EXISTS public.can_see_aid_post(BIGINT, BOOLEAN);
--   DROP FUNCTION IF EXISTS public.jwt_store_names();
--   -- 並把 rpc_aid_board_active_count 重跑 20260720000030 的版本
-- ============================================================

-- ------------------------------------------------------------
-- 1. helper：JWT 裡的店名陣列
--    app_metadata 巢狀與頂層兩種擺法都收 —— 這個專案兩種都出現過
--    （RLS 讀 auth.jwt()->>'tenant_id' 是頂層，
--      rpc_aid_board_active_count 讀 app_metadata->'stores' 是巢狀）
--
--    ⚠ 一定要用 jsonb_typeof(...) = 'array' 判，不能只靠 COALESCE：
--      線上的 hq_manager 帳號 app_metadata 是 {"stores": null}，那是 **JSON null**
--      不是 SQL NULL，COALESCE 接不住，jsonb_array_elements_text() 會直接炸
--      "cannot extract elements from a scalar"。20260720000030 的
--      rpc_aid_board_active_count 就有這個潛在問題，這裡一併修掉。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.jwt_store_names()
RETURNS TEXT[]
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT ARRAY(
    SELECT jsonb_array_elements_text(v)
      FROM (
        SELECT CASE
                 WHEN jsonb_typeof(auth.jwt() -> 'app_metadata' -> 'stores') = 'array'
                   THEN auth.jwt() -> 'app_metadata' -> 'stores'
                 WHEN jsonb_typeof(auth.jwt() -> 'stores') = 'array'
                   THEN auth.jwt() -> 'stores'
                 ELSE '[]'::jsonb
               END AS v
      ) t
  );
$$;

COMMENT ON FUNCTION public.jwt_store_names IS
  '目前登入帳號在 app_metadata.stores 裡的門市名稱陣列（沒有就回空陣列）。';

-- ------------------------------------------------------------
-- 2. helper：這則貼文目前這個帳號看不看得到
--    SECURITY DEFINER —— 判斷本身要查 stores，不該被 stores 自己的 RLS 影響
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.can_see_aid_post(
  p_offering_store_id BIGINT,
  p_visible_to_other_stores BOOLEAN
) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(p_visible_to_other_stores, TRUE)
      OR EXISTS (
           SELECT 1 FROM stores s
            WHERE s.id = p_offering_store_id
              AND s.name = ANY (public.jwt_store_names())
         );
$$;

COMMENT ON FUNCTION public.can_see_aid_post IS
  '互助貼文對目前帳號是否可見：公開的一律可見；設為不公開的只有釋出店的帳號'
  '看得到（依 JWT app_metadata.stores 的店名比對）。角色不是後門 —— '
  'admin / hq_manager / owner 一樣看不到別店的不公開貼文。';

GRANT EXECUTE ON FUNCTION public.jwt_store_names() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_see_aid_post(BIGINT, BOOLEAN) TO authenticated;

-- ------------------------------------------------------------
-- 3. mutual_aid_board：SELECT 收緊
-- ------------------------------------------------------------
DROP POLICY IF EXISTS aid_board_read_all ON mutual_aid_board;

CREATE POLICY aid_board_read_all ON mutual_aid_board
  FOR SELECT
  USING (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND public.can_see_aid_post(offering_store_id, spot_visible_to_other_stores)
  );

-- ------------------------------------------------------------
-- 4. mutual_aid_board：把 FOR ALL 拆成三條寫入 policy
--    predicate 完全照抄 20260509000001 的原版，只是不再涵蓋 SELECT
-- ------------------------------------------------------------
DROP POLICY IF EXISTS aid_board_owner_write  ON mutual_aid_board;
DROP POLICY IF EXISTS aid_board_owner_insert ON mutual_aid_board;
DROP POLICY IF EXISTS aid_board_owner_update ON mutual_aid_board;
DROP POLICY IF EXISTS aid_board_owner_delete ON mutual_aid_board;

CREATE POLICY aid_board_owner_insert ON mutual_aid_board
  FOR INSERT
  WITH CHECK (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND (
      offering_store_id = ((auth.jwt() ->> 'store_id'))::bigint
      OR (auth.jwt() ->> 'role') = ANY (ARRAY['owner', 'admin', 'hq_manager'])
    )
  );

CREATE POLICY aid_board_owner_update ON mutual_aid_board
  FOR UPDATE
  USING (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND (
      offering_store_id = ((auth.jwt() ->> 'store_id'))::bigint
      OR (auth.jwt() ->> 'role') = ANY (ARRAY['owner', 'admin', 'hq_manager'])
    )
  )
  WITH CHECK (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND (
      offering_store_id = ((auth.jwt() ->> 'store_id'))::bigint
      OR (auth.jwt() ->> 'role') = ANY (ARRAY['owner', 'admin', 'hq_manager'])
    )
  );

CREATE POLICY aid_board_owner_delete ON mutual_aid_board
  FOR DELETE
  USING (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND (
      offering_store_id = ((auth.jwt() ->> 'store_id'))::bigint
      OR (auth.jwt() ->> 'role') = ANY (ARRAY['owner', 'admin', 'hq_manager'])
    )
  );

-- ------------------------------------------------------------
-- 5. mutual_aid_replies：貼文看不到，留言也不能撈
-- ------------------------------------------------------------
DROP POLICY IF EXISTS replies_read_all ON mutual_aid_replies;

CREATE POLICY replies_read_all ON mutual_aid_replies
  FOR SELECT
  USING (
    tenant_id = ((auth.jwt() ->> 'tenant_id'))::uuid
    AND EXISTS (
      SELECT 1 FROM mutual_aid_board b
       WHERE b.id = mutual_aid_replies.board_id
         AND public.can_see_aid_post(b.offering_store_id, b.spot_visible_to_other_stores)
    )
  );

-- ------------------------------------------------------------
-- 6. 側欄 badge 不要把別店的不公開貼文算進去
--    基底：20260720000030_aid_board_badge_and_expiry_purge.sql（唯一版本，
--    已 grep 確認）。SECURITY DEFINER 會繞過 RLS，所以要自己再判一次，
--    否則 badge 數字和列表對不起來。
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_aid_board_active_count()
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  WITH me AS (
    SELECT public.jwt_store_names() AS store_names
  )
  SELECT CASE
    -- 分店帳號 = stores 非空且不含「總倉」，對齊前端 isBranchUser()
    WHEN (SELECT cardinality(store_names) > 0
             AND NOT ('總倉' = ANY (store_names))
            FROM me) THEN (
      SELECT COUNT(*)::int
        FROM mutual_aid_board b
       WHERE b.tenant_id = (auth.jwt() ->> 'tenant_id')::uuid
         AND b.status = 'active'
         AND public.can_see_aid_post(b.offering_store_id, b.spot_visible_to_other_stores)
    )
    ELSE 0
  END;
$$;

COMMENT ON FUNCTION public.rpc_aid_board_active_count IS
  '側欄「互助交流板」badge：分店帳號看到的進行中貼文數。'
  '2026-08-02 起排除別店設為不公開的貼文，數字才會和列表一致。';
