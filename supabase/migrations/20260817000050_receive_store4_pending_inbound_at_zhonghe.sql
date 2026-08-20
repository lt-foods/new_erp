-- 四號店收攤（續 20260817000020/30）：把四號店的收貨待辦全部改由中和店收。
--
-- 現況：四號店倉（location 8）掛著 434 張 shipped 未收的總倉派貨單
-- （WAVE-，2026-06-10 ～ 08-17，736 行 / 2,182 件）。四號店幾乎沒在系統
-- 收過貨（歷來 transfer_in 只有 24 筆），這批單據上的貨絕大多數還欠著
-- 客人（713 個 SKU 中 709 個在中和仍有未取需求、2,018/2,182 件）——
-- 訂單已在 20260817000020 遷到中和，貨也該入中和的帳。
--
-- 做法（逐張、redirect + receive 同一交易）：
--   1. dest_location 8 → 14（中和店倉），hq_notes 留改派記號。
--   2. rpc_receive_transfer 標準收貨（p_lines NULL = 全數照出貨量入帳）——
--      邏輯 A0–E 照跑：解待補貨、推進 confirmed 遷移單、自動配單、
--      內部池收斂。客人會收到「可到中和取貨」的推進，正是收攤要的效果。
--
-- ⚠ 執行方式：一次收貨實測約 8.5 秒（邏輯 E 要掃中和整本訂單），
--   Management API 單一交易撐不住整批（50 張直接 timeout 回滾）→
--   每次套用只收 5 張（LIMIT 5），**重複套用直到選不到單為止**
--   （2026-08-17 由迴圈逐批套用中，跑完會在 PR 回報最終對帳）。
--   冪等：只撈 dest_location=8 AND status='shipped'，收過的不會再被撈到。
-- rollback：rpc_unreceive_transfer 逐張退回；改派回四號店倉
--   UPDATE dest_location=8（憑 hq_notes 記號找得到這批單）。

DO $$
DECLARE
  v_operator UUID := '39fd694d-3af6-4978-beab-6e826dff7246';  -- cktalex（admin）
  v_tag      TEXT := '四號店收攤：待收貨改派中和店（20260817000050）';
  r RECORD;
  n INT := 0;
BEGIN
  FOR r IN
    SELECT id FROM transfers
     WHERE dest_location = 8
       AND status = 'shipped'
     ORDER BY shipped_at, id
     LIMIT 5
  LOOP
    UPDATE transfers
       SET dest_location = 14,
           hq_notes   = COALESCE(hq_notes || E'\n', '') || v_tag,
           updated_by = v_operator,
           updated_at = NOW()
     WHERE id = r.id;

    PERFORM rpc_receive_transfer(
      r.id, NULL, v_operator,
      '四號店收攤：待收貨改由中和店入帳', TRUE
    );
    n := n + 1;
  END LOOP;

  RAISE NOTICE 'received_this_run=%', n;
END $$;
