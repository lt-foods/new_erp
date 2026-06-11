-- ============================================================================
-- 2026-07-06: rpc_delete_pr — 請購單(PR)刪除（實體硬刪 + 守門 + 解鎖團）
-- ----------------------------------------------------------------------------
-- 需求：請購單要可以刪除（建錯結單日 / 多選了團 / 作廢的單想清掉）。
--
-- 難點：PR 建立時有副作用（20260625000000）——
--   1. 鎖團：closed campaigns → 'locked'
--   2. auto-confirm 訂單：那些團的 pending 訂單 → 'confirmed'
-- 若只刪 PR 本體，團會卡在 'locked'（rpc_create_pr* 要求 'closed' 才能再建單），
-- 等於把自己鎖死。故刪除時必須把「該 PR 鎖的團」解鎖回 'closed'。
--
-- 使用者決策（2026-07-06）：
--   - 可刪狀態 = draft / submitted / cancelled；已拆 PO（partially/fully_ordered）一律擋。
--   - 顧客訂單一律「維持 confirmed 不動」（不退回 pending）——不驚動已確認訂單；
--     團解鎖回 closed 後重新建單時，confirmed 訂單照樣納入彙總，無副作用。
--
-- 設計（守門順序）：
--   role 守門（owner/admin/hq_manager；空字串放行，對齊既有 restock RPC）→
--   not found / 跨 tenant → 已拆 PO（status）→ 已拆 PO（po_item_id 雙重保險）→
--   補貨來源 PR（被 restock_requests.linked_pr_id 參照，走補貨流程不在此刪）→
--   解鎖團（locked→closed，來源 = purchase_request_campaigns join ∪ source_campaign_id）→
--   實體刪 purchase_requests（items / campaigns join 為 ON DELETE CASCADE 自動連帶）。
--
-- 關於 locked→closed 與「開團單向」決策：
--   project 決策「開團狀態單向、reopen 不做」指的是 closed→open（重開放下單）。
--   這裡是 locked→closed（解除採購鎖定、回到補單窗口），語意不同、是刪 PR 的必要還原，
--   不違反該決策。group_buy_campaigns 僅有 CHECK 值域、無單向 transition trigger（20260623000000）。
--
-- 基底慣例：rpc_delete_campaign（20260630000020）— 守門 + 硬刪 + 殘參照丟可讀訊息。
-- 依賴：purchase_request_items.pr_id / purchase_request_campaigns.pr_id 為 ON DELETE CASCADE。
-- Rollback：DROP FUNCTION public.rpc_delete_pr(BIGINT, UUID);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_pr(
  p_pr_id    BIGINT,
  p_operator UUID
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant   UUID := public._current_tenant_id();
  v_role     TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_status   TEXT;
  v_po_items INTEGER;
  v_restock  INTEGER;
BEGIN
  -- role 守門：採購職能（空字串放行 — 本機/某些情境 role 為空，對齊 restock RPC）
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION '權限不足：角色 % 無法刪除請購單', v_role;
  END IF;

  SELECT status INTO v_status
    FROM purchase_requests
   WHERE id = p_pr_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION '找不到請購單 %', p_pr_id;
  END IF;

  -- 守門 1：已拆採購單(PO) 不可刪 — PO 可能已發給供應商
  IF v_status IN ('partially_ordered','fully_ordered') THEN
    RAISE EXCEPTION '請購單 % 已拆採購單(PO)，不可刪除（狀態：%）。請改在採購單端處理。', p_pr_id, v_status;
  END IF;

  -- 守門 2：雙重保險 — 任一品項已連到 PO item（即使 status 沒同步）
  SELECT COUNT(*) INTO v_po_items
    FROM purchase_request_items
   WHERE pr_id = p_pr_id AND po_item_id IS NOT NULL;
  IF v_po_items > 0 THEN
    RAISE EXCEPTION '請購單 % 已有品項拆成採購單，不可刪除', p_pr_id;
  END IF;

  -- 守門 3：補貨來源 PR（被 restock_requests 參照）走補貨流程，不在此刪
  SELECT COUNT(*) INTO v_restock
    FROM restock_requests
   WHERE linked_pr_id = p_pr_id AND tenant_id = v_tenant;
  IF v_restock > 0 THEN
    RAISE EXCEPTION '請購單 % 來自補貨申請，請從補貨流程處理，不可在此刪除', p_pr_id;
  END IF;

  -- 解鎖團：把該 PR 鎖的、目前 status='locked' 的 campaign 還原回 'closed'。
  -- 訂單一律不動（維持 confirmed）。來源涵蓋 join 表 ∪ source_campaign_id（單一團 PR）。
  UPDATE group_buy_campaigns gbc
     SET status     = 'closed',
         updated_by = p_operator,
         updated_at = NOW()
   WHERE gbc.tenant_id = v_tenant
     AND gbc.status = 'locked'
     AND gbc.id IN (
       SELECT prc.campaign_id
         FROM purchase_request_campaigns prc
        WHERE prc.pr_id = p_pr_id
       UNION
       SELECT pr.source_campaign_id
         FROM purchase_requests pr
        WHERE pr.id = p_pr_id AND pr.source_campaign_id IS NOT NULL
     );

  -- 實體硬刪：purchase_request_items / purchase_request_campaigns 為 ON DELETE CASCADE
  BEGIN
    DELETE FROM purchase_requests
     WHERE id = p_pr_id AND tenant_id = v_tenant;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION '請購單 % 仍被其他紀錄參照，無法刪除', p_pr_id;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_pr(BIGINT, UUID) IS
  '請購單刪除（硬刪）：限 draft/submitted/cancelled 且未拆 PO、非補貨來源；'
  '刪前把該 PR 鎖的 locked 團還原回 closed（訂單維持 confirmed 不動）；'
  'items/campaigns join 由 ON DELETE CASCADE 連帶刪；同 tenant；owner/admin/hq_manager。';
