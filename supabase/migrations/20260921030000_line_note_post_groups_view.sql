-- ============================================================================
-- 20260921030000_line_note_post_groups_view.sql
--
-- 「LINE 記事本 → 貼文」那一頁改成伺服端分頁 + 依社群篩選（老闆 9/21：「太多了看不了」）。
-- 原本是一次抓最新 100 篇全部畫出來、搜尋在前端做 —— 線上已經 589 篇 / 437 團，
-- 捲不完，而且第 101 篇之後的東西**連搜尋都找不到**（根本沒抓回來）。
--
-- 這支 view 的一列 = 畫面上的一張卡（同一團的貼文收成一組，未認出團的各自一組），
-- 前端先分頁抓這裡的 group_key，再去 line_note_posts 抓那幾組的貼文本體。
-- 為什麼不直接對 line_note_posts 分頁：同一團發到 3 個社群 = 3 列，切在頁緣時
-- 同一團會被切成兩張卡出現在不同頁。以「組」為單位分頁就不會。
--
-- security_invoker = true：RLS 沿用 line_note_posts 自己那兩條
-- （lnp_hq_all / lnp_perm_read + _line_note_post_visible），不要在 view 裡再抄一份
-- 分店可見範圍 —— 抄第二份就等著兩邊走鐘（20260918000000 那批已經有一份在 RPC 裡）。
-- 社群 / 開團都是 LEFT JOIN：對面被 RLS 擋掉時只是欄位變 NULL，卡片不會整張消失。
--
-- search_text 是給 ilike 用的（團名 / 團號 / 社群名 / 貼文內文都吃），
-- 前端**不要 select 它**（整組貼文內文串起來很長），只拿來當篩選條件。
--
-- rollback：
--   DROP VIEW public.v_line_note_post_groups;
--   （前端退回「抓最新 100 篇、前端搜尋」那版）
-- ============================================================================

CREATE OR REPLACE VIEW public.v_line_note_post_groups
WITH (security_invoker = true) AS
SELECT
  CASE WHEN p.campaign_id IS NULL THEN 'u' || p.id::TEXT
       ELSE 'c' || p.campaign_id::TEXT END                     AS group_key,
  p.tenant_id,
  p.campaign_id,
  CASE WHEN p.campaign_id IS NULL THEN p.id END                AS unlinked_post_id,
  max(p.created_at)                                            AS latest_at,
  count(*)::INT                                                AS post_count,
  array_agg(DISTINCT p.community_id)                           AS community_ids,
  max(g.campaign_no)                                           AS campaign_no,
  max(g.name)                                                  AS campaign_name,
  max(g.status)                                                AS campaign_status,
  string_agg(
    COALESCE(g.campaign_no, '') || ' ' || COALESCE(g.name, '') || ' ' ||
    COALESCE(c.home_name, '')  || ' ' || COALESCE(c.home_id, '') || ' ' ||
    COALESCE(p.text, ''), ' ')                                 AS search_text
FROM public.line_note_posts p
LEFT JOIN public.group_buy_campaigns g   ON g.id = p.campaign_id
LEFT JOIN public.line_note_communities c ON c.id = p.community_id
GROUP BY 1, 2, 3, 4;

COMMENT ON VIEW public.v_line_note_post_groups IS
  '貼文頁的「一團一張卡」清單（分頁 / 篩選用）。一列 = 一張卡：同團的貼文一組、未認出團的各自一組。'
  'community_ids 給「只看這個社群」用（cs.{id}），search_text 給關鍵字 ilike 用（不要 select，很長）。'
  'security_invoker → RLS 沿用 line_note_posts 的政策。';

GRANT SELECT ON public.v_line_note_post_groups TO authenticated;
