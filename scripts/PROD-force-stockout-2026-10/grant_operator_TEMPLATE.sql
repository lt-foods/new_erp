-- ============================================================================
-- ⚠️ 會改正式庫（名單加一個人）：開權限範本——讓一個帳號看得到、按得了「已到貨也能斷貨」
-- ----------------------------------------------------------------------------
-- ⛔ 這是範本：底下 p_email 刻意留空，空的貼了會直接【停】、什麼都不改。
--    要開給誰，由 CEO 在老闆確認後另存一份「本機貼上用」的副本、只填那一行 email；
--    填了 email 的副本 ⛔ 不要放回工程紀錄本（公開的）。
--
-- 做了什麼（只有這一件）
--   用登入 email 找到那個帳號，把「那個帳號＋他所屬的公司」加進名單 po_force_stockout_operators。
--   一個人貼一次；同一個人重貼不會重複加。
--
-- 加了之後會怎樣
--   * 馬上生效：那個人重新整理採購單頁，就看得到「已到貨也能斷貨」（不用重新登入）。
--   * 他可以把一團這個商品還沒取貨的客人一次取消（沒有復原鈕）——只開給老闆核准的人。
--
-- 要收回：目前只有「一鍵關掉」（kill_switch_20261022100000.sql 清空整張名單），再把要留的人重新貼一次。
--
-- 看到什麼要停：
--   * 紅字開頭【停】→ 什麼都沒改，照紅字說的處理（多半是 email 打錯、或那個帳號沒有設定公司）。
-- ============================================================================

DO $grant$
DECLARE
  -- ╔════════ 要填的一行（CEO 在老闆確認後，在本機副本裡填）════════╗
  p_email  TEXT := '';   -- ⬅ 那個人登入後台用的 email，例如 'someone@example.com'；⛔ 空的會直接停
  -- ╚══════════════════════════════════════════════════════════════╝
  p_note   TEXT := '老闆核准開權限（已到貨也能斷貨）';
  v_oid    REGCLASS := to_regclass('public.po_force_stockout_operators');
  v_n      INTEGER;
  v_uid    UUID;
  v_tenant UUID;
  v_role   TEXT;
  v_added  INTEGER;
  v_total  INTEGER;
BEGIN
  -- 0. 前置檢查（只讀）
  IF v_oid IS NULL
     OR position('po_force_stockout:20261022100000' IN coalesce(obj_description(v_oid, 'pg_class'), '')) = 0 THEN
    RAISE EXCEPTION '【停】找不到 20261022100000 建的名單表（migration 還沒貼）。什麼都沒改，請先貼 migration。';
  END IF;
  IF btrim(coalesce(p_email, '')) = '' THEN
    RAISE EXCEPTION '【停】email 是空的。這是範本：要在本機副本的 p_email 那一行填上要開權限的人的登入 email 再貼。什麼都沒改。';
  END IF;

  v_n := (SELECT count(*) FROM auth.users u WHERE lower(u.email) = lower(btrim(p_email)));
  IF v_n <> 1 THEN
    RAISE EXCEPTION '【停】用 email「%」找到 % 個帳號（要剛好 1 個）。請確認 email 有沒有打錯。什麼都沒改。', btrim(p_email), v_n;
  END IF;

  -- ⓘ 用指定（:=）而不是 SELECT … 進變數的寫法：Supabase 視窗會把那個字誤判成建表。
  v_uid    := (SELECT u.id FROM auth.users u WHERE lower(u.email) = lower(btrim(p_email)));
  v_tenant := (SELECT NULLIF(u.raw_app_meta_data ->> 'tenant_id', '')::UUID
                 FROM auth.users u WHERE u.id = v_uid);
  v_role   := (SELECT coalesce(u.raw_app_meta_data ->> 'role', '')
                 FROM auth.users u WHERE u.id = v_uid);
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION '【停】帳號「%」沒有設定所屬公司（app_metadata.tenant_id 是空的），開了也按不了。什麼都沒改。', btrim(p_email);
  END IF;

  -- 1. 加進名單（同一個人已經在就不重複加）
  INSERT INTO public.po_force_stockout_operators (tenant_id, user_id, note)
  VALUES (v_tenant, v_uid, p_note)
  ON CONFLICT (tenant_id, user_id) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;

  v_total := (SELECT count(*) FROM public.po_force_stockout_operators o WHERE o.tenant_id = v_tenant);
  RAISE NOTICE '✅ %：%（角色「%」）。這家公司的名單現在共 % 人。請那個人重新整理採購單頁。',
    CASE WHEN v_added = 1 THEN '已加進名單' ELSE '本來就在名單上，這次沒有改' END,
    btrim(p_email), v_role, v_total;
END
$grant$;
