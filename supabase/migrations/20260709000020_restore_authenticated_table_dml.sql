-- ============================================================================
-- 2026-07-02: 恢復 authenticated 對 public tables 的 INSERT/UPDATE/DELETE
-- ----------------------------------------------------------------------------
-- 事故（PR2607020424 實案，PR2607020421 同因）：
--   線上 DB 在 2026-06-29 ~ 2026-07-02 之間被人以手動方式（無對應 migration）
--   REVOKE 了 anon / authenticated 對 public 全部 141 張 table 的
--   INSERT / UPDATE / DELETE / TRUNCATE（service_role 未動）。
--   admin 前端大量頁面（含請購單編輯頁 saveDraft）是以 authenticated 身分
--   直接 .update() / .insert() 寫 table，全數靜默失敗：
--   使用者在畫面上指派供應商 → 存檔被 permission denied 擋下 →
--   舊版前端把錯誤吞掉繼續送審 → DB 裡品項仍是未指派 → 拆 PO / 送審被守衛擋死。
--   （佐證：purchase_request_items 最後一筆成功更新停在 2026-06-29 08:44）
--
-- 修法：把 INSERT / UPDATE / DELETE 還給 authenticated。
--   - 安全性由 RLS 承擔（public 122 張實體表僅 2 張 _backup_ 快照未開 RLS，
--     其餘全數 enabled，且各表已有 tenant + role 的 policy）— 即回到
--     2026-06-29 前的已知良好狀態。
--   - anon 不還（前端 member/liff 無直寫，維持收緊後的狀態）。
--   - TRUNCATE 不還（前端不可能需要）。
--   - _backup_% 快照表不還（未開 RLS，不該讓前端寫）。
--   - 未來新表由 default privileges 覆蓋（查核過 pg_default_acl 完好未動）。
--
-- Rollback：
--   REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM authenticated;
--   （即回到事故狀態，不建議）
-- ============================================================================

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind = 'r'
       AND c.relname NOT LIKE E'\\_backup\\_%'
  LOOP
    EXECUTE format(
      'GRANT INSERT, UPDATE, DELETE ON public.%I TO authenticated',
      r.relname
    );
  END LOOP;
END $$;
