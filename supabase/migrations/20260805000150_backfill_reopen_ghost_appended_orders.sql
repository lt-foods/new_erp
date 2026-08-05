-- ============================================================
-- 一次性資料修復：把「結案後才被追加品項」的訂單重開
--
-- 20260805000140 讓之後不會再發生（append 到 completed 單時自動重開），
-- 這支處理已經發生的。掃描條件：訂單 status='completed'，但名下有
-- created_at > completed_at 且仍未取（pending/reserved/ready）的品項 ——
-- 那些品項在 UI 完全摸不到（待取清單只看 active 狀態、
-- is_order_item_pickup_ready 第一條就擋 completed）。
--
-- 2026-08-05 掃出 3 張，全是「追加轉入」造成、全在湖口店：
--   53781 __INTERNAL_RESTOCK__-TF0092  member 67091 *琡芳*205528-湖口
--         completed 2026-07-21 → 2026-08-03 追加 G01020-03 ×2 /
--         G01020-05 ×2 / G00763-01 ×1（本次回報的 5 件）
--   53750 GB20260527-C000473-TF0048    member 61989 陳芝蓁280907-湖口
--         completed 2026-07-17 → 2026-08-01 追加 G00213-03 ×1
--   51747 GRP-20260608-009-TF0031      member 62316 盧朝忠317185-湖口
--         completed 2026-07-15 → 2026-07-24 追加 G00419-01 ×6
--
-- 重開後這些單會變 partially_completed（三張都有已取品項），待取清單看得到、
-- 品項層級的到貨判定也會放行（三張的貨都已經到店收貨了）。已取的品項維持
-- picked_up，不會被要求再取一次。
--
-- 冪等：條件本身就排除已經重開過的單（重開會清掉 completed_at 並改 status），
-- 重跑不會有效果。
-- rollback：沒有自動 rollback —— 要還原就依 customer_order_audit_log 裡
--   operator_id='00000000-0000-0000-0000-000000000000' 且
--   field='status'、after_value 為本次值的那幾筆，手動改回 completed
--   並補回 completed_at（不建議：那等於把品項再埋回去）。
-- ============================================================

DO $$
DECLARE
  r          RECORD;
  v_new      TEXT;
  v_fixed    INT := 0;
BEGIN
  FOR r IN
    SELECT co.id, co.order_no
      FROM customer_orders co
     WHERE co.status = 'completed'
       AND co.completed_at IS NOT NULL
       AND EXISTS (
         SELECT 1 FROM customer_order_items oi
          WHERE oi.order_id = co.id
            AND oi.created_at > co.completed_at
            AND oi.status IN ('pending', 'reserved', 'ready')
       )
     ORDER BY co.id
  LOOP
    v_new := public._reopen_order_if_completed(
      r.id,
      '00000000-0000-0000-0000-000000000000'::uuid,
      '資料修復：結案後被追加的品項一直沒現形');
    IF v_new IS NOT NULL THEN
      v_fixed := v_fixed + 1;
      RAISE NOTICE '重開訂單 % (#%) → %', r.order_no, r.id, v_new;
    END IF;
  END LOOP;

  RAISE NOTICE '共重開 % 張訂單', v_fixed;
END $$;
