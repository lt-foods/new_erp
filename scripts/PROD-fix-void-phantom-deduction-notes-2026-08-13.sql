-- ============================================================
-- PROD-fix：作廢 4 張假覆蓋減抵單（DN5、DN7、DN8、DN13）
-- 日期：2026-08-13｜撰寫：CEO｜狀態：v4 —— 依貨況查證結果重寫前提，等 Codex 審＋老闆執行
--   （DN28 已於稍早由獨立腳本作廢完成，不在本檔）
--
-- 版本沿革：
--   v1→v3：Codex 兩輪審查（P1×4＋P0×1）修畢；v3 執行時被「群組防呆」擋下——
--   同組還有活品項依賴 Path D 覆蓋 → 停下人工查證（防呆正確發揮作用）。
--   v4：查證完成（2026-08-13 晚，老闆跑「三組貨況診斷」實測）：
--     松山×G01610-01：待取 25、帳上 0、歷來轉入 0 —— 貨從未到店
--     松山×G01610-02：待取 3、帳上 0、歷來轉入 0 —— 貨從未到店
--     中和×G01529-01：待取 6、帳上 2（店家自入）、歷來轉入 0 —— 總倉從未派過
--   結論：這些活品項的「可取」全靠事故殘留 DN 的假覆蓋（Path D），貨並不存在；
--   假覆蓋同時壓低派貨頁短缺（松山-02 吃掉 2/3、中和吃掉 3/6）。
--   作廢 = 讓取貨頁誠實顯示「未到貨」＋讓派貨短缺回到真實值 → 老闆裁示執行。
--   店內實體現貨（中和 2 片）之後由店家用「現貨配單」正規流程配給客人。
--
-- 效果：只把 4 張單標記作廢。不碰庫存、不碰訂單、不碰取貨。
-- 安全設計：
--   - 單一交易；任何檢查不過 → RAISE → 整包回滾、零殘留；重跑在檢查點大聲失敗
--   - 每張 DN：有效＋「所有」明細都綁在指定的已取消訂單上（混到別單就停）
--   - 【v4 新前提·取代舊群組防呆】把查證證據寫進程式：該店該品必須
--     「歷來零筆總倉轉入（transfer_in）」才准作廢——若執行前貨真的到了，
--     條件不成立 → 停下重查（那時 Path B 已能撐閘門，另行評估即可）
--   - 每個 UPDATE 恰好 1 列（ROW_COUNT），否則整包回滾
--   - 操作者沿用本次修復案同一位（DN30 建立者），修復紀錄一致
--
-- Rollback：UPDATE inventory_deduction_notes
--            SET cancelled_at = NULL, cancelled_by = NULL WHERE id IN (5,7,8,13);
-- 執行後留檔，之後併入 repo scripts/ 的 PR。
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_operator uuid;
  v_cnt int;
  r record;
BEGIN
  SELECT created_by INTO v_operator FROM inventory_deduction_notes WHERE id = 30;
  IF v_operator IS NULL THEN
    RAISE EXCEPTION '前置失敗：找不到 DN30 的建立者（操作者來源）';
  END IF;

  FOR r IN
    SELECT * FROM (VALUES (5, 68217), (7, 68301), (8, 68301), (13, 68619))
      AS t(dn_id, expect_order)
  LOOP
    -- 【檢查①】DN 有效、至少一筆明細，且「所有」明細都綁在那張已取消的訂單上
    SELECT COUNT(*) INTO v_cnt
      FROM inventory_deduction_notes n
     WHERE n.id = r.dn_id AND n.cancelled_at IS NULL
       AND EXISTS (
         SELECT 1 FROM inventory_deduction_note_items ni WHERE ni.note_id = n.id
       )
       AND NOT EXISTS (
         SELECT 1
           FROM inventory_deduction_note_items ni
           LEFT JOIN customer_orders co ON co.id = ni.order_id
          WHERE ni.note_id = n.id
            AND (ni.order_id <> r.expect_order
                 OR co.id IS NULL
                 OR co.status <> 'cancelled')
       );
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION '前置失敗：DN% 不符「有效且全部明細都綁已取消訂單 %」（可能已作廢、狀態改變或混到別單），停止', r.dn_id, r.expect_order;
    END IF;

    -- 【檢查②·v4 假覆蓋證據】該店該品從無任何總倉轉入（transfer_in）紀錄。
    --   這是 2026-08-13 貨況診斷的實測前提；若執行前貨真的派到了，
    --   本條會擋下 → 停止重查（屆時 Path B 撐閘門，作廢影響另行評估）。
    SELECT COUNT(*) INTO v_cnt
      FROM inventory_deduction_notes n
      JOIN stores st
        ON st.id = n.store_id
       AND st.tenant_id = n.tenant_id
      JOIN stock_movements m
        ON m.tenant_id = n.tenant_id
       AND m.location_id = st.location_id
       AND m.sku_id = n.sku_id
       AND m.movement_type = 'transfer_in'
     WHERE n.id = r.dn_id;
    IF v_cnt > 0 THEN
      RAISE EXCEPTION '前提變動：DN% 的店×品已出現 % 筆總倉轉入紀錄（貨到了？），與「假覆蓋」查證前提不符，停止、重新評估', r.dn_id, v_cnt;
    END IF;

    -- 作廢
    UPDATE inventory_deduction_notes n
       SET cancelled_at = NOW(), cancelled_by = v_operator
     WHERE n.id = r.dn_id AND n.cancelled_at IS NULL;
    GET DIAGNOSTICS v_cnt = ROW_COUNT;
    IF v_cnt <> 1 THEN
      RAISE EXCEPTION '作廢 DN% 失敗：更新 % 列（預期恰好 1），整包回滾', r.dn_id, v_cnt;
    END IF;
  END LOOP;

  RAISE NOTICE '完成：DN5/7/8/13 已作廢（假覆蓋移除；取貨頁將誠實顯示未到貨、派貨短缺回真實值）';
END $$;

COMMIT;

-- ============ 執行後驗證（缺列也會現形） ============
WITH expect(id) AS (VALUES (5), (7), (8), (13))
SELECT e.id::text AS "減抵單id",
       COALESCE(n.note_no, '（找不到這張單）') AS "單號",
       CASE
         WHEN n.id IS NULL THEN '❌ 單不存在，貼給 AI'
         WHEN n.cancelled_at IS NOT NULL THEN '✅ 已作廢'
         ELSE '❌ 仍有效，貼給 AI'
       END AS "判定"
  FROM expect e
  LEFT JOIN inventory_deduction_notes n ON n.id = e.id
UNION ALL
SELECT '總檢', '4 張全作廢且同一操作者',
       CASE WHEN (SELECT COUNT(*) FROM inventory_deduction_notes
                   WHERE id IN (5,7,8,13) AND cancelled_at IS NOT NULL) = 4
             AND (SELECT COUNT(DISTINCT cancelled_by) FROM inventory_deduction_notes
                   WHERE id IN (5,7,8,13) AND cancelled_by IS NOT NULL) = 1
            THEN '✅' ELSE '❌ 貼給 AI' END
 ORDER BY 1;
