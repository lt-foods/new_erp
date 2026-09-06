-- ============================================================================
-- 2026-09-04（店家退貨頁 · 第 3 支）：總倉「不同意退貨」對乙案的單零庫存動作
--
-- ============================================================================
-- 【一】老闆 2026-09-04 裁示 2（乙案）後半段，逐字錨定
-- ============================================================================
--   「…**總倉按同意的那一刻才真的扣**。**不同意的話什麼都沒動過，乾乾淨淨**」
--     （出處：需求暨計畫_店家退貨頁_2026-09-04.md 第 10-11 行）
--
-- ⛔⛔ 【三支必須一起貼，順序不可顛倒】
--   1️⃣ 20260904020000（建單不扣）→ 2️⃣ 20260904020010（同意才扣）→ 3️⃣ 本檔（不同意零動作）
--   只貼 1️⃣ 不貼本檔 ＝ 總倉按「不同意退貨」時會對店家 rpc_inbound 一次，
--   而店家從來沒被扣過 ⇒ **憑空生貨、店家庫存變兩份**。
--   ⚠️ 這是三支裡「漏貼會直接做出錯帳」的那一支。
--
-- ============================================================================
-- 【二】壞在哪（不是理論，是現行程式碼逐字讀出來的）
-- ============================================================================
--   rpc_reject_transfer 的第 1 段（基底 :51-70）無條件把每一個 qty_shipped > 0 的行
--   rpc_inbound 回 source_location —— 它的前提是「這批貨出庫過」。
--   對舊路徑（rpc_create_order_return，建單即扣）那是對的；
--   對乙案的單（送出時一筆庫存都沒動、out_movement_id 是 NULL）就變成憑空加貨。
--
--   ⇒ 修法：那個迴圈的 WHERE 多一條 ——
--       AND NOT (v_xfer.transfer_type = 'return_to_hq' AND out_movement_id IS NULL)
--     「沒有出庫紀錄」就是「沒扣過」這件事本身，沒扣過就沒有東西要退回去。
--
--   ⚠️ 條件刻意綁死 return_to_hq、不放寬成「只要 out_movement_id IS NULL 就跳過」：
--     本機碰不到正式庫，我**無法證明**歷史上沒有「shipped 但 out_movement_id 是 NULL」
--     的一般調撥單；綁死單型之後，這個條件對所有非退貨單恆為假 ⇒
--     行為與本檔上線前一模一樣，不會改到任何我沒查證過的資料。
--
-- ============================================================================
-- 【三】改了什麼（基底逐字自證）
-- ============================================================================
--   基底＝ 20260827020000_reject_return_reopens_closed_order.sql:41
--     ⚠️ **不是** 20260801000000_full_return_closes_order.sql:363 ——
--       那是舊版。用定義鏈查法自排（git grep -nE
--       "CREATE (OR REPLACE )?FUNCTION (public\.)?rpc_reject_transfer"）得到 6 支，
--       最後一支是 20260827020000。⚠️ 20260801000000 有**兩個同號檔**
--       （_full_return_closes_order 與 _reject_return_to_hq_keep_original_order），
--       後者後套把前者的復原分支整個蓋掉 —— 20260827020000 的檔頭就是在修那次撞號。
--       照舊版當基底會把 Alex/歷次修好的東西洗掉。
--
--   對基底做 diff：**刪 0 行、改 0 行**，只有一個 append 區塊（13 行，其中 12 行是註解）。
--   ⛔ 沒有動到的：波次派貨單守衛、cancel 後續 chain、customer_order 取消／復原分支、
--     source order 回 confirmed、決策 Y（Leg-3）、回傳欄位 —— 全部一字未改。
--
--   ⚠️ 第 2 段（往後 walk、cancel next chain 的那個迴圈，基底 :85）**刻意沒動**：
--     那個迴圈處理的是 v_next（另一張單）。乙案的退貨單不會出現在任何 next-chain 裡
--     —— rpc_create_store_return（20260904020000）沒有寫 next_transfer_id，
--     也沒有任何路徑會把 next_transfer_id 指向它。改它等於在沒有問題的地方動刀。
--
--   ⚠️ 本檔**沒有**重跑 20260827020000 檔尾那段 4 張壞單的資料修復 ——
--     那是一次性的，已經跑過；再跑一次會再摸一次那些訂單。
--
-- ============================================================================
-- 【四】做了會怎樣／不做會怎樣
-- ============================================================================
--   做了：總倉按「不同意退貨」→ 退貨單變 cancelled、貨與帳**一動都沒動**（乙案的單）。
--     ⇒ 店家庫存頁那格的「退貨中 N」會消失（view 只看 status='shipped'），
--       帳上的數字從頭到尾就是對的。
--   不做：如上，憑空生貨。而且**看不出來** —— 店家庫存多了幾件、
--     總倉沒有任何一張單對得上，等到盤點才會發現，那時已經無從追。
--
-- ============================================================================
-- 【五】⚠️ 一個已知限制（誠實列出，本檔不修）
-- ============================================================================
--   總倉收件匣有一顆「恢復在途」（rpc_unreject_transfer，20260731000000:267）。
--   對乙案的單按它會**失敗**，訊息是：
--     「調撥單 N 沒有拒收回流紀錄可沖銷（非拒收取消、或已由工程處理過），無法恢復在途」
--   原因：那支是靠「找 movement_type='transfer_reject' 的異動來沖銷」運作的
--   （:303-310），而本檔讓乙案的單一筆都不寫 ⇒ v_reversed = 0 ⇒ 它自己 RAISE（:346-348）。
--
--   ⭐ 判斷：**不修**。
--     ① 它只是拒絕，不會弄壞任何資料（沖銷迴圈一圈都沒跑就丟例外、整筆回滾）。
--     ② 乙案的「不同意」本來就什麼都沒動 —— 要反悔，店家在退貨頁重按一次
--        「＋我要退貨」就好，比恢復在途更直觀。
--     ③ 老闆 2026-08-21 定的模型是「總倉回覆只有接受／不接受」，沒有第三顆。
--   ⚠️ 但訊息會誤導（它說「非拒收取消、或已由工程處理過」，其實是「這張單本來就沒扣過貨」）。
--     要修就是動 rpc_unreject_transfer 那支的訊息，那是另一支函式、另一個 PR，
--     ⛔ 本波不做，登記在施工回報的「技術債」節。
--
-- Rollback：CREATE OR REPLACE 回 20260827020000:41 的版本即可
--   （本檔沒有動 schema、沒有資料異動）。⚠️ 三支一組，要回就三支一起回。
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_reject_transfer(
  p_transfer_id BIGINT,
  p_reason      TEXT,
  p_operator    UUID
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_xfer            transfers%ROWTYPE;
  v_ti              RECORD;
  v_next            transfers%ROWTYPE;
  v_prev            transfers%ROWTYPE;
  v_co_id           BIGINT;
  v_co              customer_orders%ROWTYPE;
  v_ret_co          customer_orders%ROWTYPE;
  v_restored_co_id  BIGINT;
  v_restored_status TEXT;
  v_leg3_id         BIGINT;
  v_leg3_no         TEXT;
  v_leg3_dest_loc   BIGINT;
  v_leg3_mov        BIGINT;
  v_reason_note     TEXT;
  v_cancelled_ids   BIGINT[] := ARRAY[]::BIGINT[];
  v_epoch           BIGINT;
  v_src_pickable    BOOLEAN := FALSE;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('transfer:' || p_transfer_id));

  SELECT * INTO v_xfer FROM transfers WHERE id = p_transfer_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;
  IF v_xfer.status <> 'shipped' THEN
    RAISE EXCEPTION 'transfer % is %, only shipped can be rejected', p_transfer_id, v_xfer.status;
  END IF;

  -- ── 守衛（2026-07-31）：撿貨波次派貨單，分店不可拒收 ──
  -- 波次派貨單背後掛著多張顧客訂單（customer_order_id 為 NULL、訂單不會被
  -- 本 RPC 一併處理），店端拒收會讓訂單卡在 shipping、庫存虛回總倉。
  -- 只擋「JWT store scope 涵蓋 dest 的分店帳號」；總倉帳號維持可操作（清理用）。
  IF v_xfer.dest_location = ANY (public._jwt_store_location_ids())
     AND EXISTS (
       SELECT 1 FROM picking_wave_items pwi
        WHERE pwi.generated_transfer_id = p_transfer_id
     ) THEN
    RAISE EXCEPTION '總倉派貨單（%）不可由分店拒收：貨還沒到請等貨到再收；貨品有誤或毀損請聯繫總倉處理',
      v_xfer.transfer_no;
  END IF;

  v_reason_note := '[rejected: ' || COALESCE(p_reason, '') || ']';

  -- 1. 反向：把 outbound 過的貨退回 source_location
  FOR v_ti IN
    SELECT id, sku_id, qty_shipped FROM transfer_items
     WHERE transfer_id = p_transfer_id AND qty_shipped > 0
       -- ↓↓ 20260904020020 新增（店家退貨頁乙案）：沒出過庫的行不可以「退回去」
       --   店家退貨頁（rpc_create_store_return，20260904020000）建的單，
       --   送出時**一筆庫存都沒扣**，out_movement_id 是 NULL。
       --   對這種行做 rpc_inbound ＝ 憑空生貨（店裡本來就還有那批貨，再加一次就變兩份）。
       --   ⭐ 老闆 2026-09-04 原話：「不同意的話什麼都沒動過，乾乾淨淨」——
       --     零庫存動作才是「乾乾淨淨」。
       --   ⚠️ 條件刻意綁死 return_to_hq：舊路徑的退貨（rpc_create_order_return）
       --     與所有 hq_to_store / store_to_store 單，建單／派貨當下就寫了 out_movement_id
       --     （20260801000000:248-265、20260508000000:150-166）⇒ 這個條件對它們恆為假、
       --     行為與本檔上線前**一模一樣**。
       --     ⛔ 不要放寬成「只要 out_movement_id IS NULL 就跳過」——那會改到我沒查證過的
       --       歷史資料（本機碰不到正式庫，我無法證明沒有那種列）。
       AND NOT (v_xfer.transfer_type = 'return_to_hq' AND out_movement_id IS NULL)
  LOOP
    PERFORM rpc_inbound(
      p_tenant_id       => v_xfer.tenant_id,
      p_location_id     => v_xfer.source_location,
      p_sku_id          => v_ti.sku_id,
      p_quantity        => v_ti.qty_shipped,
      p_unit_cost       => 0,
      p_movement_type   => 'transfer_reject',
      p_source_doc_type => 'transfer',
      p_source_doc_id   => p_transfer_id,
      p_operator        => p_operator
    );
  END LOOP;

  UPDATE transfers
     SET status = 'cancelled',
         notes = CASE
                   WHEN notes IS NULL OR notes = '' THEN v_reason_note
                   ELSE notes || E'\n' || v_reason_note
                 END,
         updated_by = p_operator
   WHERE id = p_transfer_id;
  v_cancelled_ids := v_cancelled_ids || p_transfer_id;

  -- 2. 往後 walk：next chain 的 draft/shipped cancel 掉
  IF v_xfer.next_transfer_id IS NOT NULL THEN
    SELECT * INTO v_next FROM transfers WHERE id = v_xfer.next_transfer_id FOR UPDATE;
    IF v_next.id IS NOT NULL AND v_next.status IN ('draft', 'shipped') THEN
      IF v_next.status = 'shipped' THEN
        FOR v_ti IN
          SELECT id, sku_id, qty_shipped FROM transfer_items
           WHERE transfer_id = v_next.id AND qty_shipped > 0
        LOOP
          PERFORM rpc_inbound(
            p_tenant_id       => v_next.tenant_id,
            p_location_id     => v_next.source_location,
            p_sku_id          => v_ti.sku_id,
            p_quantity        => v_ti.qty_shipped,
            p_unit_cost       => 0,
            p_movement_type   => 'transfer_reject',
            p_source_doc_type => 'transfer',
            p_source_doc_id   => v_next.id,
            p_operator        => p_operator
          );
        END LOOP;
      END IF;
      UPDATE transfers
         SET status = 'cancelled',
             notes = CASE
                       WHEN notes IS NULL OR notes = '' THEN v_reason_note
                       ELSE notes || E'\n' || v_reason_note
                     END,
             updated_by = p_operator
       WHERE id = v_next.id;
      v_cancelled_ids := v_cancelled_ids || v_next.id;
    END IF;
  END IF;

  -- 3. 找 customer_order 並取消 —— 僅互助/派貨鏈適用（2026-08-01 加判斷）。
  -- return_to_hq（分店退訂單回總倉）的 customer_order_id 是「被退貨的原訂單」：
  -- rpc_create_order_return 建單時訂單狀態保留不動，拒收（退訂單取消）只應
  -- 作廢退貨單本身、貨帳退回店端，原訂單不得取消（30709 / 37587 事故）。
  IF v_xfer.transfer_type <> 'return_to_hq' THEN
    v_co_id := v_xfer.customer_order_id;
    IF v_co_id IS NULL AND v_next.id IS NOT NULL THEN
      v_co_id := v_next.customer_order_id;
    END IF;

    IF v_co_id IS NOT NULL THEN
      SELECT * INTO v_co FROM customer_orders WHERE id = v_co_id;
      UPDATE customer_orders
         SET status       = 'cancelled',
             cancelled_at = NOW(),
             updated_by   = p_operator,
             updated_at   = NOW()
       WHERE id = v_co_id;

      -- ── source order 退回 ──（20260713 修法，與 rpc_cancel_aid_order 一致）
      IF v_co.transferred_from_order_id IS NOT NULL THEN
        UPDATE customer_orders
           SET status                  = 'confirmed',
               transferred_to_order_id = NULL,
               updated_by              = p_operator,
               updated_at              = NOW()
         WHERE id = v_co.transferred_from_order_id
           AND status = 'transferred_out';

        v_src_pickable := public.is_order_pickup_ready(v_co.transferred_from_order_id);
        IF v_src_pickable THEN
          UPDATE customer_orders
             SET status     = 'ready',
                 ready_at   = COALESCE(ready_at, NOW()),
                 updated_by = p_operator,
                 updated_at = NOW()
           WHERE id = v_co.transferred_from_order_id
             AND status = 'confirmed';
        END IF;
      END IF;
    END IF;
  ELSE
    -- ── return_to_hq 拒收 → 復原「因退貨被收尾」的原訂單（2026-08-27 補回）──
    -- 這段在 20260801000000_full_return_closes_order 寫過，被同號的
    -- keep_original_order 版蓋掉、從未上線（見檔頭）。貨已由上面的
    -- transfer_reject inbound 回到店端，原訂單要跟著復原可取：
    --   - 曾因全數退貨收尾成 cancelled（有 active 品項、無已取）→ 回 ready
    --   - 曾因收尾成 completed（仍有 active 品項）→ 回 partially_completed
    --   - 其他（正常 ready / partially_completed / expired…）→ 不動
    --     （退貨單已 cancelled，可取量／應收扣減查詢自動不再計入）
    IF v_xfer.customer_order_id IS NOT NULL THEN
      SELECT * INTO v_ret_co FROM customer_orders
       WHERE id = v_xfer.customer_order_id FOR UPDATE;
      IF v_ret_co.status = 'cancelled'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_ret_co.id AND status IN ('pending','reserved','ready'))
         AND NOT EXISTS (SELECT 1 FROM customer_order_items
                          WHERE order_id = v_ret_co.id AND status = 'picked_up') THEN
        v_restored_co_id  := v_ret_co.id;
        v_restored_status := 'ready';
        UPDATE customer_orders
           SET status       = 'ready',
               ready_at     = COALESCE(ready_at, NOW()),
               cancelled_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_ret_co.id;
      ELSIF v_ret_co.status = 'completed'
         AND EXISTS (SELECT 1 FROM customer_order_items
                      WHERE order_id = v_ret_co.id AND status IN ('pending','reserved','ready')) THEN
        v_restored_co_id  := v_ret_co.id;
        v_restored_status := 'partially_completed';
        UPDATE customer_orders
           SET status       = 'partially_completed',
               completed_at = NULL,
               updated_by   = p_operator,
               updated_at   = NOW()
         WHERE id = v_ret_co.id;
      END IF;
    END IF;
  END IF;

  -- 4. 決策 Y：若往前有 received 的 leg，自動建 Leg-3 退回原 source
  SELECT * INTO v_prev
    FROM transfers
   WHERE next_transfer_id = p_transfer_id
   LIMIT 1;

  IF v_prev.id IS NOT NULL AND v_prev.status = 'received' THEN
    v_leg3_dest_loc := v_prev.source_location;  -- 退回原 source 店

    v_epoch := EXTRACT(EPOCH FROM NOW())::BIGINT;
    v_leg3_no := 'AT-RET-' || p_transfer_id || '-' || v_epoch;

    INSERT INTO transfers (
      tenant_id, transfer_no, source_location, dest_location,
      status, transfer_type, customer_order_id, next_transfer_id,
      requested_by, shipped_by, shipped_at,
      created_by, updated_by, notes
    ) VALUES (
      v_xfer.tenant_id, v_leg3_no, v_xfer.source_location, v_leg3_dest_loc,
      'shipped', 'hq_to_store', NULL, NULL,
      p_operator, p_operator, NOW(),
      p_operator, p_operator, '[Leg-3 退回 source after reject]'
    ) RETURNING id INTO v_leg3_id;

    FOR v_ti IN
      SELECT sku_id, qty_shipped FROM transfer_items
       WHERE transfer_id = p_transfer_id AND qty_shipped > 0
    LOOP
      v_leg3_mov := rpc_outbound(
        p_tenant_id       => v_xfer.tenant_id,
        p_location_id     => v_xfer.source_location,
        p_sku_id          => v_ti.sku_id,
        p_quantity        => v_ti.qty_shipped,
        p_movement_type   => 'transfer_out',
        p_source_doc_type => 'transfer',
        p_source_doc_id   => v_leg3_id,
        p_operator        => p_operator
      );
      INSERT INTO transfer_items (
        transfer_id, sku_id, qty_requested, qty_shipped,
        out_movement_id, created_by, updated_by
      ) VALUES (
        v_leg3_id, v_ti.sku_id, v_ti.qty_shipped, v_ti.qty_shipped,
        v_leg3_mov, p_operator, p_operator
      );
    END LOOP;

    UPDATE transfers SET next_transfer_id = v_leg3_id, updated_by = p_operator
     WHERE id = p_transfer_id;
  END IF;

  RETURN jsonb_build_object(
    'rejected_transfer_id', p_transfer_id,
    'cancelled_transfer_ids', to_jsonb(v_cancelled_ids),
    'cancelled_co_id', v_co_id,
    'restored_co_id', v_restored_co_id,
    'restored_status', v_restored_status,
    'leg3_transfer_id', v_leg3_id,
    'source_order_reverted', v_co.transferred_from_order_id IS NOT NULL,
    'source_order_pickable', v_src_pickable
  );
END;
$$;

COMMENT ON FUNCTION rpc_reject_transfer IS
  'Aid transfer 拒收：反向 inbound、cancel 後續 chain、customer_order 取消、source order 回 confirmed。'
  '經總倉 dest 拒 Leg-2 自動建 Leg-3 退回原 source（決策 Y）。'
  '原單退回時若貨已在店(is_order_pickup_ready) 直接推到 ready（2026-07-13）。'
  '撿貨波次派貨單分店不可拒收，僅總倉帳號可操作（2026-07-31）。'
  'return_to_hq 拒收只作廢退貨單、貨帳退回店端，不取消原顧客訂單（2026-08-01）；'
  '並復原因退貨被收尾的訂單（cancelled→ready / completed→partially_completed，2026-08-27）。'
  '⭐ 2026-09-04：店家退貨頁（乙案）建的 return_to_hq 行送出時沒扣過店家庫存'
  '（out_movement_id IS NULL），拒收時**不做** inbound —— 沒扣過就沒有東西要退回去，'
  '做了就是憑空生貨。老闆原話「不同意的話什麼都沒動過，乾乾淨淨」。';
