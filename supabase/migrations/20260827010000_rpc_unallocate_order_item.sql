-- ============================================================================
-- 訂單頁「取消配單」：把波次到貨自動配單配給這一行的貨收回可配量
--
-- 需求（Alex 2026-08-27）：「可以針對訂單取消配單嗎」＋截圖 GRP-20260727-015-0050
--   （泰山，收 WAVE-2151-S50 時被自動配單推成可取貨）—— 訂單頁沒有按鈕。
--
-- 現況：既有的「↩️ 取消配貨」（rpc_unassign_stock_from_order_item，20260825020000）
--   只認 DN 覆蓋 —— 它是「📦 從庫存配貨」的反向。但線上大多數「可取貨」的單
--   是**波次到貨自動配單**推上去的（rpc_receive_transfer 邏輯 C/E、
--   _advance_arrived_confirmed_orders）：身上沒有任何 DN，
--   rpc_get_order_stock_assignments 回空 → 按鈕不出現，配單收不回來。
--
-- 本檔新增：rpc_unallocate_order_item(item_id, operator, reason)
--   1. 品項標 backorder_at / backorder_by ＋ notes 蓋 [取消配單] 章。
--      取貨閘門內含 backorder_at IS NULL（20260818000010 gate 版本第 165 行）
--      → 閘門立刻關掉，取貨頁勾不到、店員發不出去。
--   2. 單頭 ready → confirmed（判準同 rpc_unassign_stock_from_order_item：
--      整單 active 品項 bool_and(閘門) 不成立才退）。ready_at 清掉。
--   3. 不動 stock_balances —— 自動配單本來就沒扣庫存（取貨那一刻才扣），
--      取消只是把「這批貨有主人」的主張拿掉。
--
-- 取消之後那幾件去哪（各算法怎麼看待補貨列）：
--   · 配貨預算 _order_item_stock_budget 的 committed **整列排除**
--     backorder_at IS NOT NULL 的行 → 馬上可以「📦 從庫存配貨」給別張單。
--   · 閘門實體庫存守衛（20260818000010）母體只算 ready/partially_completed/
--     shipping 單頭 → 單頭退回 confirmed 後不再佔額度。
--   · _sku_commitment：這一行從 promised 移到 waiting（waiting 不濾 backorder，
--     刻意不改 —— 現貨直配 SP- 的自由量因此**不會**因取消配單而放大：
--     這位客人的需求還在，下一批貨仍是他的）。
--
-- 怎麼「重新配」（本檔不新增解除路徑，四條既有的都接得上）：
--   · 訂單頁「📦 從庫存配貨」（rpc_assign_stock_to_order_item 會清 backorder_at）
--   · 收貨頁「⚖️ 配貨」（rpc_allocate_shortage）
--   · 下一批貨收進來時 _settle_arrived_backorders（邏輯 A0）數量夠就自動解除
--   · rpc_create_inventory_deduction / rpc_create_offset_sale
--
-- 與「↩️ 取消配貨」的分工（前端也照這條路由）：
--   身上有有效 DN 覆蓋 → 走 rpc_unassign_stock_from_order_item（釋放覆蓋＋還池子）；
--   沒有 DN 而閘門放行（Path A/B/C 波次供貨）→ 走本函式。
--   本函式對有覆蓋的行直接擋下並指路，兩邊不會互踩。
--
-- 守衛（不給取消的）：
--   · picked_up —— 貨真的交出去了，走退貨。
--   · 單頭 shipping —— 波次已派出、貨還在路上，要退走收貨端（拒收/退回）。
--   · 容器單（member_type='store_internal'）／offset 單／SP- 現貨直配 ——
--     它們不是「等貨的客人單」：容器單是現貨池帳本，SP- 整張就是配單
--     （要取消請直接取消訂單，20260816000070 已放行 ready 的 SP-）。
--   · 已經掛 backorder_at 的行 —— 沒有配單可取消。
--
-- 已知取捨：
--   · 整行一起退（不拆行）。qty>1 只想退一部分：先到訂單頁改數量再取消。
--   · 客人若已收過「到貨通知」，取消後要店家自行知會（本檔不發通知 ——
--     比照 rpc_unassign_stock_from_order_item，取消配貨也沒發）。
--   · 下一批同 SKU 收貨時 A0 數量夠會自動重配回這張單（它本來就在排隊）。
--
-- 基底版本：本檔一支函式為新增，不改任何既有函式。
--   守衛與鎖對齊 rpc_unassign_stock_from_order_item（20260825020000）。
-- Rollback：
--   DROP FUNCTION public.rpc_unallocate_order_item(BIGINT, UUID, TEXT);
--   已標掉的列要復原：訂單頁「📦 從庫存配貨」重配，或
--   UPDATE customer_order_items SET backorder_at=NULL, backorder_by=NULL WHERE ...
--
-- 對應前端（同一個 commit）：
--   apps/admin/src/components/CancelAllocationModal.tsx（新）
--   apps/admin/src/components/OrderDetail.tsx（閘門放行且無 DN 的行多一顆「↩️ 取消配單」）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_unallocate_order_item(
  p_item_id  BIGINT,
  p_operator UUID,
  p_reason   TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_jwt_role  TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v           RECORD;
  v_now       TIMESTAMPTZ := NOW();
  v_status2   TEXT;
  v_bo2       TIMESTAMPTZ;
  v_cov       NUMERIC;
  v_all_ready BOOLEAN;
  v_reverted  BOOLEAN := FALSE;
  v_tag       TEXT;
BEGIN
  IF p_operator IS NULL THEN
    RAISE EXCEPTION '缺少操作人';
  END IF;

  SELECT coi.id           AS item_id,
         coi.status       AS item_status,
         coi.qty          AS item_qty,
         coi.backorder_at AS backorder_at,
         coi.sku_id       AS sku_id,
         co.id            AS order_id,
         co.order_no      AS order_no,
         co.status        AS order_status,
         co.tenant_id     AS tenant_id,
         co.pickup_store_id AS store_id,
         COALESCE(co.order_kind, 'normal') AS order_kind,
         COALESCE(m.member_type, '')       AS member_type,
         s.name           AS store_name
    INTO v
    FROM customer_order_items coi
    JOIN customer_orders co ON co.id = coi.order_id
    LEFT JOIN members m ON m.id = co.member_id
    LEFT JOIN stores  s ON s.id = co.pickup_store_id
   WHERE coi.id = p_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到訂單品項 #%', p_item_id;
  END IF;

  IF v.item_status = 'picked_up' THEN
    RAISE EXCEPTION '這個品項已經取貨了，要收回請走退貨流程（不是取消配單）';
  END IF;
  IF v.item_status NOT IN ('pending', 'reserved', 'ready') THEN
    RAISE EXCEPTION '這個品項是「%」，沒有配單可取消', v.item_status;
  END IF;
  IF v.order_status IN ('cancelled', 'expired', 'transferred_out') THEN
    RAISE EXCEPTION '訂單狀態為「%」，沒有配單可取消', v.order_status;
  END IF;
  IF v.order_status = 'shipping' THEN
    RAISE EXCEPTION '這張單在出貨中（波次已派出），貨還在路上 —— 要退請走收貨端流程';
  END IF;
  IF v.member_type = 'store_internal' THEN
    RAISE EXCEPTION '這是【內部】容器單（店端現貨池帳本），不能取消配單';
  END IF;
  IF v.order_kind = 'offset' OR v.order_no LIKE 'SP-%' THEN
    RAISE EXCEPTION '現貨直配／減抵單整張就是配單，要收回請直接取消該張訂單';
  END IF;
  IF v.backorder_at IS NOT NULL THEN
    RAISE EXCEPTION '這一行已經是「待補貨」（配單早已取消或從未配到）';
  END IF;

  -- 店家守衛：同 rpc_assign_stock_to_order_item / rpc_unassign_stock_from_order_item
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉')
     AND NOT (v_my_stores ? v.store_name) THEN
    RAISE EXCEPTION 'wrong_store: 這是「%」的單，分店帳號只能動自己店的貨', v.store_name;
  END IF;

  -- 與配貨 / 取消配貨搶同一把鎖：動的是同一批實體庫存的主張
  PERFORM pg_advisory_xact_lock(hashtext(format('spotsale:%s:%s:%s',
    v.tenant_id, v.store_id, v.sku_id)));

  -- 拿鎖之後鎖列重讀（併發取貨 / 配貨會改 status / backorder_at）
  SELECT coi.status, coi.backorder_at INTO v_status2, v_bo2
    FROM customer_order_items coi
   WHERE coi.id = p_item_id
     FOR UPDATE;
  IF v_status2 NOT IN ('pending', 'reserved', 'ready') THEN
    RAISE EXCEPTION '這個品項剛被別的作業改成「%」了，請重新整理後再試', v_status2;
  END IF;
  IF v_bo2 IS NOT NULL THEN
    RAISE EXCEPTION '這一行剛被標成「待補貨」了，請重新整理後再試';
  END IF;

  -- 身上有有效 DN 覆蓋的行不歸這裡管：那是「從庫存配貨」配的，
  -- 要用「↩️ 取消配貨」收（會一併釋放覆蓋、還現貨池）。
  SELECT COALESCE(SUM(GREATEST(ni.qty - COALESCE(ni.released_qty, 0), 0)), 0)
    INTO v_cov
    FROM inventory_deduction_note_items ni
    JOIN inventory_deduction_notes n ON n.id = ni.note_id AND n.cancelled_at IS NULL
   WHERE ni.order_item_id = p_item_id;
  IF v_cov > 0 THEN
    RAISE EXCEPTION '這一行是「從庫存配貨」配的（覆蓋 % 件），請改用「↩️ 取消配貨」', v_cov;
  END IF;

  v_tag := CASE WHEN NULLIF(TRIM(COALESCE(p_reason, '')), '') IS NULL
                THEN '[取消配單]'
                ELSE '[取消配單｜' || TRIM(p_reason) || ']' END;

  -- 標待補貨＝關取貨閘門（backorder_at IS NULL 那一關）。
  -- 待補貨列同時退出配貨預算的 committed 與 _sku_commitment 的 promised_active，
  -- 這幾件立刻回到別張單的可配量。
  UPDATE customer_order_items
     SET backorder_at = v_now,
         backorder_by = p_operator,
         notes        = TRIM(BOTH E'\n' FROM COALESCE(notes || E'\n', '') || v_tag),
         updated_by   = p_operator,
         updated_at   = v_now
   WHERE id = p_item_id;

  -- 單頭：自動配單推上去的 ready 退回 confirmed（判準同推進時：整單 active
  -- 品項是不是都還過得了閘門）。有取過貨的單（partially_completed）不動。
  IF v.order_status = 'ready' THEN
    SELECT bool_and(public.is_order_item_pickup_ready(c.id)) INTO v_all_ready
      FROM customer_order_items c
     WHERE c.order_id = v.order_id
       AND c.status IN ('pending', 'reserved', 'ready');
    IF NOT COALESCE(v_all_ready, TRUE) THEN
      UPDATE customer_orders
         SET status     = 'confirmed',
             ready_at   = NULL,
             updated_by = p_operator,
             updated_at = v_now
       WHERE id = v.order_id
         AND status = 'ready';
      v_reverted := TRUE;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'item_id',      p_item_id,
    'order_id',     v.order_id,
    'order_no',     v.order_no,
    'qty',          v.item_qty,
    'order_status', CASE WHEN v_reverted THEN 'confirmed' ELSE v.order_status END,
    'reverted',     v_reverted,
    'gate_ready',   public.is_order_item_pickup_ready(p_item_id)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_unallocate_order_item(BIGINT, UUID, TEXT) IS
  '訂單頁「取消配單」：把波次到貨自動配單配給這一行的貨收回可配量 —— 品項標'
  ' backorder_at（取貨閘門立刻關掉）＋ notes 蓋 [取消配單] 章，單頭 ready 退回 confirmed。'
  '不動 stock_balances（自動配單本來就沒扣庫存）。有 DN 覆蓋的行請改用'
  ' rpc_unassign_stock_from_order_item；重新配走「📦 從庫存配貨」／「⚖️ 配貨」／'
  '下一批收貨的 _settle_arrived_backorders。';

REVOKE ALL ON FUNCTION public.rpc_unallocate_order_item(BIGINT, UUID, TEXT)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_unallocate_order_item(BIGINT, UUID, TEXT)
  TO authenticated;
