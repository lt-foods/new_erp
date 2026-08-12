-- ============================================================================
-- 2026-08-12: rpc_create_partial_pr_from_items — 請購單「部分轉採購」（勾選品項搬到新單）
-- ----------------------------------------------------------------------------
-- 需求（老闆 2026-08-12）：
--   員工要「今天只採購一部分」，實務上是用 PR 編輯頁商品列的 ✕ 把暫時不買的品項拉掉，
--   讓剩下的先送審拆 PO。但 ✕ 是實體 DELETE（edit/page.tsx 的 removedIds 在 saveDraft
--   直接 delete purchase_request_items），而結單日補單判定「已請購量」的唯一依據 ——
--   20260714000060:102-111 的 already CTE —— 就是
--     「同 source_close_date 的所有『未取消 close_date PR』的 pri.qty_requested 加總」。
--   品項被實體刪掉 → already 少掉那筆 → delta = demand − already 由 0 變正
--   → 結單日補單卡片跳出來說「這些 SKU 尚未請購」→ 重複請購。
--
-- 解法：不刪，改「搬」。從原 PR 勾選品項 → 開一張新的 draft PR → 勾選的搬過去、
--   未勾選的留在原 PR。搬移語意是「移動」，不是刪掉需求。
--
--   ★ 正確性的關鍵：新 PR **必須整組繼承** source_type / source_close_date /
--     source_campaign_id / source_location_id / tenant_id。
--     already 是「跨 PR 加總」，只要新 PR 也落在同一個
--     (source_type='close_date', source_close_date) 桶子裡，搬移前後總量守恆、
--     補單 delta 完全不變。
--     ⚠️ 若新 PR 圖方便用 source_type='manual'，搬走的量會從 already 消失 →
--        補單重複請購 → 重蹈覆轍。所以「繼承 source 欄位」不是可選項，是必要條件。
--     另外 chk_pr_source_consistency（20260505000000:35-39）也要求 type 與對應欄位
--     配對正確，本來就只能整組帶。
--
-- 設計（守門順序，全部通過才取號）：
--   role 守門（owner/admin/hq_manager；空字串放行，對齊 rpc_delete_pr）→
--   勾選清單非空（去 NULL、去重、排序）→ source PR 存在且同 tenant（header FOR UPDATE）→
--   status 必須 draft → 非補貨來源（restock_requests.linked_pr_id）→
--   鎖被選 items（依 id 遞增，先 header 後 items，避免死鎖）→
--   命中筆數 = 去重後 id 數 → 被選 items 全部未拆 PO →
--   搬移後原 PR 剩餘筆數 > 0（決策 F：禁止全選搬空）→
--   rpc_next_pr_no() 取號 → 建新 draft PR → INSERT 新品項 → 補 join 表 →
--   DELETE 原品項 → 兩張 PR 各自重算 total_amount。
--
-- 基底 / 對齊：
--   - 守門寫法、FOR UPDATE、restock 守衛：rpc_delete_pr（20260706000000）
--   - 建 PR + items + join 表 + 重算 total 的流程：
--     rpc_create_supplementary_pr_from_close_date（20260714000060）
--   - 「先驗證再取號、不浪費序號」：20260714000060:120-125
--   - join 表自動同步：trg_pri_sync_campaigns（20260614000020:57-61）
--
-- 故意不動（決策 E / C）：
--   - 不呼叫 _lock_orders_after_pr_aggregation、不改 campaign status —
--     團在原 PR 建立時就已 locked，這是「搬移」不是「新彙總」，重複鎖會誤動狀態。
--   - 原 PR 的 purchase_request_campaigns 一律不動、不清理（理由見 DELETE 那段註解）。
--   - rpc_submit_pr / rpc_split_pr_to_pos / rpc_pr_reopen / rpc_delete_pr /
--     rpc_create_supplementary_pr_from_close_date 一行都不改；本檔只『新增』一支函式。
--
-- Rollback：
--   DROP FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID);
--   （只是新增函式，沒有 schema 變更；drop 後系統回到本 migration 之前的行為。
--     已經被搬過的 PR 仍然是合法資料——它們就是普通的 close_date PR。）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_partial_pr_from_items(
  p_source_pr_id BIGINT,
  p_item_ids     BIGINT[],
  p_operator     UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_ids        BIGINT[];
  v_want       INTEGER;
  v_matched    INTEGER := 0;
  v_po_linked  INTEGER := 0;
  v_restock    INTEGER;
  v_total      INTEGER;
  v_remaining  INTEGER;
  v_moved      INTEGER;
  v_src        RECORD;
  v_new_pr_id  BIGINT;
  v_new_pr_no  TEXT;
  v_notes      TEXT;
  r            RECORD;
BEGIN
  -- 守衛 1：role 守門 — 採購職能（空字串放行；本機/某些情境 role 為空，對齊 rpc_delete_pr:49-51）
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION '權限不足：角色 % 無法執行部分轉採購', v_role;
  END IF;

  -- 守衛 2：勾選清單非空。去 NULL + 去重 + 依 id 遞增排序 ——
  -- 排序不只是整理，後面鎖列就照這個順序，避免兩個交易對同一張單反向鎖而死鎖。
  v_ids := ARRAY(
    SELECT DISTINCT t.x
      FROM unnest(COALESCE(p_item_ids, ARRAY[]::BIGINT[])) AS t(x)
     WHERE t.x IS NOT NULL
     ORDER BY t.x
  );
  v_want := COALESCE(array_length(v_ids, 1), 0);

  IF v_want = 0 THEN
    RAISE EXCEPTION '請先勾選要轉出的品項';
  END IF;

  -- 守衛 2b（非規格列舉，但 purchase_requests.created_by 是 NOT NULL）：
  -- 先擋掉沒帶操作人的呼叫，別讓它變成看不懂的 not-null constraint 錯誤。
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人員 id，無法建立新請購單';
  END IF;

  -- 守衛 3：source PR 存在、同 tenant，並鎖住 header（先 header 後 items）
  SELECT pr.pr_no, pr.status, pr.source_type, pr.source_close_date,
         pr.source_campaign_id, pr.source_location_id, pr.notes
    INTO v_src
    FROM purchase_requests pr
   WHERE pr.id = p_source_pr_id AND pr.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到請購單 %', p_source_pr_id;
  END IF;

  -- 守衛 4：只有草稿可以搬。已送審 / 已拆 PO 的單改在採購單端處理
  -- （對齊 rpc_delete_pr:63-65 的 status 守門與 rpc_append_campaign_to_pr 的 draft 限制）
  IF v_src.status <> 'draft' THEN
    RAISE EXCEPTION '請購單 % 不是草稿（目前狀態：%），不可部分轉採購', v_src.pr_no, v_src.status;
  END IF;

  -- 守衛 5：補貨來源 PR 走補貨流程 —— rpc_ship_restock_pr_received 靠 linked_pr_id
  -- 對回原單的品項出貨，品項被搬到別張單會直接對不上帳。照抄 rpc_delete_pr:75-81。
  SELECT COUNT(*) INTO v_restock
    FROM restock_requests
   WHERE linked_pr_id = p_source_pr_id AND tenant_id = v_tenant;

  IF v_restock > 0 THEN
    RAISE EXCEPTION '請購單 % 來自補貨申請，請從補貨流程處理，不可部分轉採購', v_src.pr_no;
  END IF;

  -- 守衛 6：鎖被選 items（依 id 遞增）。同一趟順便算命中筆數與已拆 PO 筆數，
  -- 迴圈寫法對齊 _lock_orders_after_pr_aggregation（20260625000000:63-69）。
  FOR r IN
    SELECT pri.id, pri.po_item_id
      FROM purchase_request_items pri
     WHERE pri.pr_id = p_source_pr_id
       AND pri.id = ANY(v_ids)
     ORDER BY pri.id
     FOR UPDATE
  LOOP
    v_matched := v_matched + 1;
    IF r.po_item_id IS NOT NULL THEN
      v_po_linked := v_po_linked + 1;
    END IF;
  END LOOP;

  -- 守衛 7：命中筆數必須等於去重後的勾選數（擋跨單 / 已被刪掉的 item id）
  IF v_matched <> v_want THEN
    RAISE EXCEPTION '有品項不屬於本請購單 %（勾選 % 項，實際命中 % 項）',
      v_src.pr_no, v_want, v_matched;
  END IF;

  -- 守衛 8：被選品項不可已拆 PO（po_item_id 雙重保險，即使 header status 沒同步；
  -- 對齊 rpc_delete_pr:67-73）
  IF v_po_linked > 0 THEN
    RAISE EXCEPTION '勾選的品項有 % 項已拆成採購單(PO)，不可搬移。請改在採購單端處理。', v_po_linked;
  END IF;

  -- 守衛 9（決策 F）：原 PR 不可被搬空。全選直接擋，語意比「剩 0 項再另外處理」乾淨，
  -- 也不用去碰刪單邏輯。訊息要能引導使用者走對的路。
  SELECT COUNT(*) INTO v_total
    FROM purchase_request_items
   WHERE pr_id = p_source_pr_id;

  v_remaining := v_total - v_matched;

  IF v_remaining <= 0 THEN
    RAISE EXCEPTION '不可把請購單 % 的品項全部轉出（會清空原單）。要全部採購請直接送出審核本單。',
      v_src.pr_no;
  END IF;

  -- ---------------------------------------------------------------------------
  -- 守衛全過了才取號。nextval 不受交易 rollback 回補，先取後 RAISE 就是白燒一個序號，
  -- 所以順序照 20260714000060:120-125 的模式：先驗完，再 rpc_next_pr_no()。
  -- ---------------------------------------------------------------------------
  v_new_pr_no := public.rpc_next_pr_no();

  -- 新單備註：原 notes 若非空則整段前置保留，再換行加來源註記
  v_notes := format('分批採購：自 %s 轉出 %s 項', v_src.pr_no, v_matched);
  IF COALESCE(btrim(v_src.notes), '') <> '' THEN
    v_notes := v_src.notes || E'\n' || v_notes;
  END IF;

  -- 建新 draft PR：source_* 四欄 + tenant_id 整組繼承（理由見檔頭 ★）
  INSERT INTO purchase_requests (
    tenant_id, pr_no, source_type, source_close_date, source_campaign_id,
    source_location_id, status, total_amount, notes,
    created_by, updated_by
  ) VALUES (
    v_tenant, v_new_pr_no, v_src.source_type, v_src.source_close_date, v_src.source_campaign_id,
    v_src.source_location_id, 'draft', 0, v_notes,
    p_operator, p_operator
  ) RETURNING id INTO v_new_pr_id;

  -- 搬品項：INSERT 新列 + DELETE 原列。
  -- purchase_request_items 沒有軟刪除欄位、沒有 line_no、沒有 UNIQUE(pr_id,sku_id)，
  -- 硬刪是本系統既有唯一模式（rpc_delete_pr、前端 removedIds 都是硬刪）。
  -- ⚠️ line_subtotal 是 GENERATED ALWAYS AS (qty_requested * unit_cost) STORED
  --    （20260428120000:38-39），INSERT 指定它會直接報錯 → 不帶，讓它自己算。
  -- ⚠️ po_item_id 不帶：上面守衛 8 已保證全為 NULL，帶了反而會把新列誤標成已拆 PO。
  -- 註：suggested_supplier_id 若原本是 NULL，trg_pri_fill_default_supplier
  --    （20260709000030:66-70，BEFORE INSERT WHEN NULL）會補上預設供應商 —— 這是既有且
  --    方向正確的行為（補上，不是洗掉），接受。
  INSERT INTO purchase_request_items (
    pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost,
    retail_price, franchise_price, source_campaign_id,
    raw_line, notes, parse_confidence,
    created_by, updated_by
  )
  SELECT
    v_new_pr_id, pri.sku_id, pri.qty_requested, pri.suggested_supplier_id, pri.unit_cost,
    pri.retail_price, pri.franchise_price, pri.source_campaign_id,
    pri.raw_line, pri.notes, pri.parse_confidence,
    p_operator, p_operator
    FROM purchase_request_items pri
   WHERE pri.pr_id = p_source_pr_id
     AND pri.id = ANY(v_ids)
   ORDER BY pri.id;

  GET DIAGNOSTICS v_moved = ROW_COUNT;

  -- 新 PR 的 join 表（決策 D）：
  --   上面 INSERT 時 trg_pri_sync_campaigns（20260614000020:57-61）已自動 upsert
  --   每列的 source_campaign_id；這裡再顯式補一次，而且是「整組複製原 PR 的關聯」。
  --   為什麼要整組而不是只補被搬品項那幾團：close_date PR 的 pri.source_campaign_id
  --   只記 MIN(campaign_id)（20260625000000:177 的 first_campaign_id），同一 SKU 若跨多團
  --   有訂單，光靠 trigger 會少掉關聯 → 之後拆 PO，撿貨主視圖 v_picking_demand_by_po 的
  --   po_campaigns 就少算需求。rpc_create_supplementary_pr_from_close_date
  --   （20260714000060:166-172）也是整日全帶，行為一致。
  --   多帶關聯是安全的：campaign_demand 另以 poi.sku_id = coi.sku_id 過濾，
  --   rpc_create_wave_from_po 的候選團也會再按 (store, sku) 實際需求挑，
  --   而 fn_check_pr_campaigns_consistency() 只查「pri 有、join 沒有」單一方向。
  INSERT INTO purchase_request_campaigns (pr_id, campaign_id, tenant_id)
  SELECT v_new_pr_id, prc.campaign_id, v_tenant
    FROM purchase_request_campaigns prc
   WHERE prc.pr_id = p_source_pr_id
  ON CONFLICT (pr_id, campaign_id) DO NOTHING;

  -- 刪原列（上面已 FOR UPDATE 鎖住）
  DELETE FROM purchase_request_items
   WHERE pr_id = p_source_pr_id
     AND id = ANY(v_ids);

  -- ⚠️ 原 PR 的 purchase_request_campaigns 一律不動、不清理（決策 C）。三個理由：
  --   1. fn_check_pr_campaigns_consistency()（20260614000020:78-97）只抓
  --      「pri 有 source_campaign_id、join 表沒對應 row」單一方向 → 搬走最後一個掛某團的
  --      品項後，殘留的 join row 不會讓一致性檢查 fail。
  --   2. 撿貨主視圖 v_picking_demand_by_po 的 po_campaigns、缺貨傳播、
  --      rpc_create_wave_from_po 的 campaign 候選全靠這張 join 表；砍掉就有東西看不到。
  --   3. 保守原則：多一條關聯只是多看到一團（後面還會被 sku 相符條件過濾掉），
  --      少一條就是需求直接消失。

  -- total_amount 沒有 trigger 維護，全系統一律在 function 內手算（12 處慣例，
  -- 如 20260625000000:206-211）。兩張 PR 都要重算。
  UPDATE purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal)
             FROM purchase_request_items pri
            WHERE pri.pr_id = pr.id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id IN (p_source_pr_id, v_new_pr_id);

  -- 回傳實際的 post-state 剩餘筆數（重查，不是用減的）
  SELECT COUNT(*) INTO v_remaining
    FROM purchase_request_items
   WHERE pr_id = p_source_pr_id;

  RETURN jsonb_build_object(
    'new_pr_id',       v_new_pr_id,
    'new_pr_no',       v_new_pr_no,
    'moved_count',     v_moved,
    'remaining_count', v_remaining
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) IS
  '請購單部分轉採購：把 draft PR 的勾選品項「搬」到一張新的 draft PR（未勾選的留在原單）；'
  '新 PR 繼承 tenant_id / source_type / source_close_date / source_campaign_id / source_location_id '
  '—— 這是結單日補單「已請購量」跨 PR 加總守恆的必要條件，搬移前後 delta 不變；'
  '守衛 = owner/admin/hq_manager、draft、非補貨來源、品項屬於本單且未拆 PO、不可全選搬空；'
  '原 PR 的 campaigns join 不動（決策 C）；兩張 PR 各自重算 total_amount；'
  '回傳 {new_pr_id, new_pr_no, moved_count, remaining_count}。';
