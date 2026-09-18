-- ============================================================================
-- 20260918000000_line_notes_view_perm.sql
--
-- 功能權限新增 `line_notes_view`：role 之外「個別加開」LINE 記事本的**檢視**權。
--
-- 需求（Alex 2026-09-18）：想讓某些非總部帳號（分店店長 / 店員、會計、採購）看得到
--   /line-notes 這一頁跟開團裡的 LINE 記事本，但又不想把他升成總部角色。
--   → 比照 orders_pivot_all_stores / orders_edit_amount，掛在員工管理頁的
--     「功能權限」視窗上逐人勾選（app_metadata.perms）。
--
-- 給的只有「看」：
--   - line_note_communities / line_note_posts / line_note_comments 多一條 SELECT policy
--     給有這個 perm 的人；既有 FOR ALL 的 *_hq_all（總部角色才能寫）原封不動，
--     所以有 perm 的人 UPDATE 留言狀態會是 0 rows、發文 / 讀取 / 刪除等 RPC 照樣被
--     _line_note_require_admin() 擋 insufficient_role。前端唯讀模式不畫那些按鈕，
--     但寬嚴由 DB 決定。
--   - 帳號（v_line_note_accounts，登入 QR / PIN 在這）**不給**：view 的 WHERE 只放總部
--     角色，perm 持有者讀到空清單，頁面也不顯示「帳號」「社群設定」兩個分頁。
--   - 開團的 LINE 記事本彈窗本來就開給全角色看歷史（20260910030000），不用動。
--
-- 分店範圍：有 perm 的分店帳號看到的東西比照 rpc_line_note_campaign_targets 的兩層 ——
--   社群：沒綁店的（總部社群）或綁到自己店的；團：總部的團或自己店開的團。
--   兩層都判斷才不會看到別家店的客人留言。判斷收在 _line_note_post_visible()，
--   SECURITY DEFINER 直接查父表，不受 group_buy_campaigns / line_note_communities 自身
--   RLS 影響（否則 policy 裡的子查詢又要再過一次 RLS，兩邊口徑會漂）。
--
-- 為什麼讀 JWT 而不查 auth.users 即時值（20260814080000 的教訓）：
--   那次是「改金額」的寫入權限，撤回沒即時生效會出事；這裡是純檢視，撤回後最多再看
--   一個 access token TTL，跟 orders_pivot_all_stores 同一個取捨。RLS 裡 auth.jwt()
--   一律包 (SELECT ...) 成 initplan，不要每列重解 JWT（20260818000020）。
--
-- 基底：
--   _is_valid_staff_perm ← 20260814080000_fix_order_edit_perm_store_names.sql:124-130
--     （已 grep 確認是最新版），逐字複製只追加一個 key。
--   三張表的既有 policy（20260908010000 的 lnc_hq_all / lnp_hq_all / lncm_hq_all）不動，
--   本檔只**新增** policy（permissive OR）。
--
-- Rollback：
--   DROP POLICY IF EXISTS lnc_perm_read  ON public.line_note_communities;
--   DROP POLICY IF EXISTS lnp_perm_read  ON public.line_note_posts;
--   DROP POLICY IF EXISTS lncm_perm_read ON public.line_note_comments;
--   DROP FUNCTION public._line_note_post_visible(BIGINT);
--   重跑 20260814080000 的 _is_valid_staff_perm 段（白名單去掉 line_notes_view）。
--   已經勾在 app_metadata.perms 裡的 line_notes_view 會變無效 key，不影響既有邏輯，
--   下次存那位員工的權限時會被 rpc_update_staff_perms 擋下並提示。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 合法 perm key 白名單 — 逐字複製 20260814080000:124-130，只追加一個 key
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_valid_staff_perm(p_perm TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_perm IN (
    'orders_pivot_all_stores',  -- 訂單樞紐表：檢視所有門市欄位
    'orders_edit_amount',       -- 訂單金額：可改單價與折扣（限自己店的訂單）
    'line_notes_view'           -- LINE 記事本：可檢視貼文與留言（唯讀；發文 / 帳號仍只有總部）
  );
$$;

GRANT EXECUTE ON FUNCTION public._is_valid_staff_perm(TEXT) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 這篇貼文（以及底下的留言）這個帳號看不看得到 —— 社群層 + 團層都要過
--    SECURITY DEFINER：policy 裡呼叫時不再受父表 RLS 影響，口徑對齊
--    rpc_line_note_campaign_targets（總部社群 / 自己店的社群；總部團 / 自己店的團）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._line_note_post_visible(p_post_id BIGINT)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  -- campaign_id 可為 NULL（20260910000000 的「未認出團」貼文）→ LEFT JOIN，
  -- 沒有團就只看社群那一層；寫成 INNER JOIN 會把那些貼文整批藏起來（實測少 87 篇）。
  SELECT EXISTS (
    SELECT 1
      FROM line_note_posts p
      JOIN line_note_communities     c ON c.id = p.community_id
      LEFT JOIN group_buy_campaigns  g ON g.id = p.campaign_id
     WHERE p.id = p_post_id
       AND public._line_note_branch_visible_store(c.store_id)
       AND public._line_note_branch_visible_store(g.owner_store_id)
  );
$$;
GRANT EXECUTE ON FUNCTION public._line_note_post_visible(BIGINT) TO authenticated;

COMMENT ON FUNCTION public._line_note_post_visible(BIGINT) IS
  'line_notes_view 功能權限的可見範圍：貼文所在社群沒綁店或綁到自己店，且貼文的團是總部團或自己店開的團。非分店帳號一律 true。';

-- ----------------------------------------------------------------------------
-- 3. 三張表各加一條 SELECT policy 給 perm 持有者（既有 *_hq_all 不動）
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS lnc_perm_read ON public.line_note_communities;
CREATE POLICY lnc_perm_read ON public.line_note_communities FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND public._line_note_branch_visible_store(store_id)
  );

DROP POLICY IF EXISTS lnp_perm_read ON public.line_note_posts;
CREATE POLICY lnp_perm_read ON public.line_note_posts FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND public._line_note_post_visible(id)
  );

DROP POLICY IF EXISTS lncm_perm_read ON public.line_note_comments;
CREATE POLICY lncm_perm_read ON public.line_note_comments FOR SELECT
  USING (
    tenant_id = (SELECT (auth.jwt() ->> 'tenant_id')::uuid)
    AND (SELECT public._jwt_has_perm('line_notes_view'))
    AND public._line_note_post_visible(post_id)
  );
