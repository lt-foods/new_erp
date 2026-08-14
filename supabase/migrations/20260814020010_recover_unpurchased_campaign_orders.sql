-- ============================================================
-- 2026-08-14 (3)：資料收拾 —— 未採購三團的訂單全部退回「還沒配貨」（confirmed）
--
-- 接續 20260814020000（Path C 時間下限）。那支關門之後，這裡把已經被
-- 誤放行的單收回來：
--
--   GRP-20260806-007（包子媽家生煎包，campaign 3579）
--   GRP-20260807-001（大溪順羽土雞蛋，campaign 3601）
--   GRP-20260810-016（厚實鮭魚菲力，campaign 3745）
--
-- 三團共同狀態：PR 還在 draft（PR2608120686 / PR2608140705）、沒有任何
-- PO / 撿貨波次 / transfer / 減抵單 / offset 單 —— 貨從來沒有為這三團
-- 出過總倉。要收拾的殘局：
--
--   1. 5 張被誤按取貨的 completed 單（69485, 69572, 69774, 70389, 72318）：
--      走既有的 rpc_undo_pickup 逐張撤銷 —— reversal 沖回門市庫存
--      （古華 -5 / -3、文山 -1、三峽 -2 的負庫存就是這批扣出來的）、
--      品項還原 pending、寫補償事件與 audit log。
--      閘門已修，撤銷後的狀態重算會落在 'shipping'，由第 2 步一併收回。
--   2. 2 張店家自己撤銷過、但因當時閘門還開著而被重算成 'ready' 的單
--      （69560, 71928），連同第 1 步撤完的單，一律退回 'confirmed'
--      並清掉 ready_at / shipping_at / completed_at —— 即「已成單、
--      還沒配貨」，之後真的採購、開波次派貨時會走正常流程再推進。
--
-- 金流：7 張單 wallet_paid_amount 全為 0，payment_status 全站恆為
-- 'unpaid'（見 CLAUDE.md），這裡不需要動錢。門市若已向客人收現金，
-- 要由門市自行退還 —— 系統帳上本來就沒有記收款。
--
-- 冪等：rpc_undo_pickup 對已撤銷的事件會擋（movement 已被沖銷過），
-- 所以第 1 步只挑「還有 picked_up 品項」的單；第 2 步的 UPDATE 有
-- status 白名單，重跑不會動到已經是 confirmed 的單。
--
-- Rollback：不提供自動 rollback —— 這是資料修復；反向操作（把單推回
-- completed / 重扣庫存）沒有正當業務情境。
-- ============================================================

DO $$
DECLARE
  v_op       CONSTANT UUID := '00000000-0000-0000-0000-000000000000';
  v_reason   CONSTANT TEXT :=
    '未採購誤配貨回收：GRP-20260806-007 / GRP-20260807-001 / GRP-20260810-016 '
    '三團無 PO / 波次 / transfer，取貨閘門 Path C 誤放行（20260814020000 已修）';
  v_camp_ids BIGINT[];
  v_order    RECORD;
  v_res      JSONB;
  v_undone   INT := 0;
  v_reverted INT := 0;
BEGIN
  SELECT array_agg(id) INTO v_camp_ids
    FROM group_buy_campaigns
   WHERE campaign_no IN ('GRP-20260806-007','GRP-20260807-001','GRP-20260810-016');

  IF v_camp_ids IS NULL THEN
    RAISE NOTICE 'recover_unpurchased_campaign_orders: 找不到目標團，略過';
    RETURN;
  END IF;

  -- ---- 1. 撤銷誤按的取貨（庫存 reversal + 品項還原，全走既有 RPC）----
  FOR v_order IN
    SELECT co.id, co.order_no
      FROM customer_orders co
     WHERE co.campaign_id = ANY (v_camp_ids)
       AND EXISTS (
         SELECT 1 FROM customer_order_items coi
          WHERE coi.order_id = co.id AND coi.status = 'picked_up'
       )
     ORDER BY co.id
  LOOP
    v_res := public.rpc_undo_pickup(v_order.id, v_op, v_reason);
    v_undone := v_undone + 1;
    RAISE NOTICE '撤銷取貨 %：%', v_order.order_no, v_res;
  END LOOP;

  -- ---- 2. 全部退回 confirmed（＝已成單、還沒配貨）----
  FOR v_order IN
    SELECT co.id, co.order_no, co.status
      FROM customer_orders co
     WHERE co.campaign_id = ANY (v_camp_ids)
       AND co.status IN ('ready','shipping','partially_completed','completed')
       -- 保險：不該再有 picked_up 殘留（第 1 步已全撤）；有就跳過留給人工
       AND NOT EXISTS (
         SELECT 1 FROM customer_order_items coi
          WHERE coi.order_id = co.id AND coi.status = 'picked_up'
       )
     ORDER BY co.id
     FOR UPDATE
  LOOP
    UPDATE customer_orders
       SET status       = 'confirmed',
           ready_at     = NULL,
           shipping_at  = NULL,
           completed_at = NULL,
           updated_by   = v_op,
           updated_at   = NOW()
     WHERE id = v_order.id;

    INSERT INTO customer_order_audit_log (
      tenant_id, order_id, entity_type, entity_id, field,
      before_value, after_value, edit_reason, operator_id
    )
    SELECT co.tenant_id, co.id, 'order', co.id, 'status',
           to_jsonb(v_order.status), to_jsonb('confirmed'::text),
           v_reason, v_op
      FROM customer_orders co WHERE co.id = v_order.id;

    v_reverted := v_reverted + 1;
    RAISE NOTICE '退回 confirmed：%（原 %）', v_order.order_no, v_order.status;
  END LOOP;

  RAISE NOTICE 'recover_unpurchased_campaign_orders：撤銷取貨 % 張、退回 confirmed % 張',
    v_undone, v_reverted;
END $$;
