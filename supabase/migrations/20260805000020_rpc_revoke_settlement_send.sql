-- ============================================================
-- 2026-08-05: 月結送審撤銷 rpc_revoke_settlement_send（sent → draft，總倉發起）
--
-- 需求（Alex）：「月結送審可以撤消，由總倉發起撤銷。」
--   總部按了「送店家線上核對」之後才發現送錯月份 / 漏加人工調整 /
--   自由轉貨估價還要再修，現況沒有回頭路：只能等店家提爭議
--   （disputed）才輪回總部，或口頭拜託店家先別按 —— 但店家一按同意
--   就直接 confirmed 鎖住並產生應收單，來不及攔。
--
-- 設計：
--   - 只收 sent（已送店家核對、店家尚未動作）→ 回 draft。
--     disputed（球本來就在總部，估價/調整都還能改）與 confirmed 起
--     （已鎖定、已產生應收單）都不收；鎖定後要動金額一律走爭議 /
--     應收單流程，不從這裡開後門。
--   - 僅總部：_settlement_caller_is_hq()（20260715000120；'' = legacy
--     admin）。店家不能自己把單子退回 draft —— 那等於單方面把帳撤掉。
--   - 清掉 sent_at / sent_by（回 draft 就不該再顯示送單時間），撤銷軌跡
--     append 進 notes（時間＋原因），重新送單時 sent_at 會重新蓋上。
--     store_agreed_at/by 不動（sent 狀態下本來就是 NULL）。
--   - 撤銷後的連鎖效果（都是既有行為，不需另外改）：
--     * 店家端 StoreSettlementReview 只列 sent 起 → 該單從店家清單消失。
--     * rpc_store_review_settlement 守門 status='sent' → 店家手上開著的
--       舊分頁按同意/送爭議會被擋（'狀態 draft 不可核對'）。
--     * rpc_settlement_action_count 店家口徑算 sent+confirmed → badge 自動 -1。
--     * 生成器 rpc_generate_hq_to_store_settlement 重算範圍含 draft →
--       撤銷後改來源資料會自動重算，人工調整（錨月份+店）也會重新套用。
--
-- 新函式，無歷史版本（grep supabase/migrations/ 確認無同名）。
-- 依賴：public._settlement_caller_is_hq()（20260715000120）。
-- Rollback：DROP FUNCTION public.rpc_revoke_settlement_send(BIGINT, UUID, TEXT);
--   （已被撤回 draft 的列不會自動回 sent，需要時重新送單即可。）
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_revoke_settlement_send(
  p_settlement_id BIGINT,
  p_operator      UUID,
  p_reason        TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_s      store_monthly_settlements%ROWTYPE;
  v_reason TEXT := NULLIF(TRIM(p_reason), '');
BEGIN
  IF NOT public._settlement_caller_is_hq() THEN
    RAISE EXCEPTION '僅總部帳號可撤銷送審（role=%）',
      COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  END IF;

  SELECT * INTO v_s FROM store_monthly_settlements
   WHERE id = p_settlement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settlement % not found', p_settlement_id;
  END IF;

  IF v_s.status <> 'sent' THEN
    RAISE EXCEPTION '狀態 % 不可撤銷送審（僅 sent 已送店家核對、店家尚未回應）', v_s.status;
  END IF;

  UPDATE store_monthly_settlements
     SET status     = 'draft',
         sent_at    = NULL,
         sent_by    = NULL,
         notes      = TRIM(BOTH E'\n' FROM
           COALESCE(notes || E'\n', '')
           || '[撤銷送審 ' || to_char(NOW(), 'YYYY-MM-DD HH24:MI') || ']'
           || COALESCE('（' || v_reason || '）', '')),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE id = p_settlement_id;

  RETURN jsonb_build_object(
    'settlement_id', p_settlement_id,
    'status',        'draft',
    'was',           v_s.status,
    'sent_at',       v_s.sent_at,
    'reason',        v_reason
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_revoke_settlement_send(BIGINT, UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_revoke_settlement_send IS
  '總部撤銷月結送審：sent→draft（清 sent_at/sent_by、撤銷軌跡寫進 notes）。'
  '僅 sent 可撤（店家已回應的 disputed、已鎖定的 confirmed 起都不收）；僅總部可發起。';
