-- ============================================================
-- 2026-07-10: 批次收貨伺服端 RPC（修「批次收貨 5 筆以上 timeout」）
--
-- 問題：
--   收貨待辦（wms/inbound）的「批次收貨」原本在瀏覽器端用
--   Promise.allSettled 對每張 transfer 各打一次 rpc_receive_transfer，
--   N 筆 = N 個並行 HTTP／DB 交易。每個 rpc_receive_transfer（hq_to_store
--   邏輯 C）都會 UPDATE 該分店「所有 shipping 訂單」並對每張逐一跑昂貴的
--   is_order_pickup_ready()。多筆並行時：
--     - 這些交易搶同一批 customer_orders row lock（同店），彼此互卡；
--     - 每筆又各自重跑一次昂貴的 pickup_ready 判定；
--     - PostgREST 連線池 / statement_timeout 一超過就整批失敗。
--   實測 5 筆以上就會踩到 statement timeout。
--
-- 修法：
--   新增 rpc_receive_transfer_batch(p_transfer_ids, p_operator, p_notes)，
--   在「單一交易、單一 round-trip」內序列處理每張 transfer，直接複用現行
--   rpc_receive_transfer（p_lines=NULL＝全收，與原批次語意一致）。序列化後
--   同店訂單的 row lock 不再互卡、pickup_ready 判定不重疊，避免 timeout。
--   每張用 BEGIN…EXCEPTION 子區塊（savepoint）包起來，單張失敗只回滾該張、
--   不影響其餘，維持原本 Promise.allSettled 的「部分成功」語意。
--
--   風格比照 20260515000005_distribute_batch_any_source.sql 的
--   rpc_transfer_distribute_batch（succeeded / failed 收集）。
--
-- 基底版本：rpc_receive_transfer = 20260703000000（線上現行版，不改動）。
-- Rollback：DROP FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT);
--           前端改回逐筆 Promise.allSettled 即可（見同 PR 之 inbound/page.tsx）。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_receive_transfer_batch(
  p_transfer_ids BIGINT[],
  p_operator     UUID,
  p_notes        TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
-- 序列處理整批可能比單張久；覆寫 PostgREST 預設的 statement_timeout（8s），
-- 讓大批次（一個波次數十家分店）也不會中途被 timeout 砍斷。
SET statement_timeout TO '180000'
AS $$
DECLARE
  v_id        BIGINT;
  v_ok_count  INTEGER := 0;
  v_succeeded BIGINT[] := ARRAY[]::BIGINT[];
  v_failed    JSONB    := '[]'::jsonb;
  v_err       TEXT;
BEGIN
  IF p_transfer_ids IS NULL OR array_length(p_transfer_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'p_transfer_ids is empty';
  END IF;

  FOREACH v_id IN ARRAY p_transfer_ids LOOP
    BEGIN
      -- 序列呼叫現行單張收貨（全收：p_lines=NULL）。子區塊＝savepoint，
      -- 單張失敗只回滾該張、CONTINUE 處理下一張。
      PERFORM public.rpc_receive_transfer(v_id, NULL, p_operator, p_notes);
      v_ok_count  := v_ok_count + 1;
      v_succeeded := v_succeeded || v_id;
    EXCEPTION WHEN OTHERS THEN
      v_err    := SQLERRM;
      v_failed := v_failed || jsonb_build_object('id', v_id, 'error', v_err);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'processed', array_length(p_transfer_ids, 1),
    'ok_count',  v_ok_count,
    'succeeded', v_succeeded,
    'failed',    v_failed
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_receive_transfer_batch(BIGINT[], UUID, TEXT) IS
  '批次收貨：單一交易序列呼叫 rpc_receive_transfer（全收），取代前端並行打 N 次'
  '造成的 row-lock 互卡 / statement timeout。單張失敗以 savepoint 隔離，回傳 succeeded / failed。';
