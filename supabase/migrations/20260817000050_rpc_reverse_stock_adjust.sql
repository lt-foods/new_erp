-- ============================================================
-- 撤銷「＋ 新增庫存」補錯的那一筆 — rpc_reverse_stock_adjust
--
-- 老闆 2026-08-17 回報：「補庫存補錯了要撤掉那一筆」。
--
-- 現況：庫存總覽只有「＋ 新增庫存」（rpc_add_stock_by_product，最新版
--   20260816000050），寫 manual_adjust(+N)。stock_movements 是 append-only
--   （trg_no_update_mov / trg_no_delete_mov，20260422120003:262-268，
--   RAISE 'stock_movements is append-only. Use a reversing entry instead.'），
--   按錯了唯一的救法是到盤點頁重盤整個品項 —— 代價完全不成比例。
--
-- 地基早就有，不要重造（20260422120003 建表當天就寫好）：
--   movement_type CHECK 含 'reversal'（最新清單＝20260713000000:40）
--   reverses    BIGINT REFERENCES stock_movements(id)  -- 這筆沖銷了哪一筆
--   reversed_by BIGINT REFERENCES stock_movements(id)  -- 這筆被哪一筆沖銷了
--
-- ⚠️ reversed_by 永遠寫不進去，不要試：trg_no_update_mov 是
--   BEFORE UPDATE ... FOR EACH ROW，沒有 OF columns、沒有 WHEN，無條件擋掉
--   所有 UPDATE，且建表後從未改過。既有正確作法見 rpc_wallet_reverse
--   （20260606000000:166-172）的註解：「用 reverses 反查；不寫 reversed_by
--   避開 append-only trigger」。本檔逐字沿用。
--   （附帶：20260503000000_cleanup_wv260425184716.sql:109 那行
--     `UPDATE stock_movements SET reversed_by` 是壞的 —— 該檔只 disable 了
--     picking_wave_audit_log 的 trigger。已知，不在本案範圍，不動它。）
--
-- ⭐ 帳為什麼會乾淨地回到原點：
--   apply_movement_to_balance（全系統唯一版，20260422120003:212-238）只在
--   `NEW.quantity > 0 AND NEW.unit_cost IS NOT NULL AND NEW.unit_cost > 0`
--   時才重算加權平均。
--     補：rpc_add_stock_by_product 的 unit_cost 留 NULL → 走 ELSE，avg_cost 不動
--     撤：本函式寫負數      → quantity > 0 不成立 → 走 ELSE，avg_cost 不動
--   → 一補一撤，on_hand 回到原值、avg_cost 三次量測完全相同。
--   本檔另加 unit_cost IS NULL 守衛把這個對稱性釘死（見守衛 6）。
--
-- 守衛（1-8 依需求計畫「切片 C」逐條；9-11 是施工時查出來必須補的）：
--   1  原筆存在 ＋ FOR UPDATE 鎖住（FOR UPDATE 只是 row-lock，不觸發 UPDATE trigger）
--   2  tenant 一致（lookup 就帶 tenant_id，對齊 rpc_delete_store 20260620000080:54）
--   3  拒絕撤銷 reversal（逐字對齊 wallet：cannot reverse a reversal）
--   4  只能撤 movement_type = 'manual_adjust'（不能拿去撤進貨/出貨/盤點）
--   5  只能撤正數那筆（只撤「補進來的」）
--   6  防重複：EXISTS (... WHERE reverses = p_movement_id)（⛔ 不寫 reversed_by）
--   7  當下可用量要夠：on_hand - reserved >= 要撤的量
--      （算式逐字對齊 rpc_outbound 最新版 20260705000000:144-157，含 NOT FOUND → 0）
--   8  SECURITY DEFINER ＋ 明確 REVOKE/GRANT
--   9  ★ source_doc_type IS NULL —— 只撤「庫存總覽手動新增」那一種。
--      理由：manual_adjust 還有第二個寫入者 rpc_adjust_po_item_received
--      （最新 20260801000000:524-529，source_doc_type='po_item_received_adjust'），
--      它與 purchase_order_items.qty_received 是綁在一起改的。單獨撤庫存那一半，
--      採購單的已收量會跟庫存永久對不起來。且該路徑的舊版（20260708000000:134-146）
--      走 rpc_inbound 帶 unit_cost，是**正數**且**帶成本**的 manual_adjust ——
--      線上一定存在這種歷史列（append-only），沒有這道守衛就撤得下去。
--  10  ★ unit_cost IS NULL —— 帶成本的正數進帳「有」推動過 avg_cost，
--      而負數沖銷「不會」把它推回來（apply_movement_to_balance 的 IF 要 quantity > 0）。
--      撤了會把均成本永久弄歪且帳面看不出來 → 一律擋，不要自作聰明去反推。
--  11  ★ 店家守衛 —— 分店角色只能撤自己店的。逐字對齊 20260816000050 給
--      rpc_add_stock_by_product 加的那道（app_metadata.stores 店名陣列，
--      ⛔ 不可用 store_id：線上 33 個分店帳號沒有任何一個有 store_id，見 20260808000020）。
--      少了這道，本函式就是 8/16 那道守衛的後門：A 店帳號可以扣掉 B 店的庫存。
--
-- ⛔ 不能用 rpc_outbound 寫這筆：它的參數沒有 reverses，串不起沖銷關係
--   （也就無法防重複）。故自己 INSERT，並自己做同一份可用量檢查。
--
-- 另建 idx_mov_reverses：reverses 原本無索引，守衛 6 與前端「這筆撤過了沒」
--   的反查都會 seq scan 整張 stock_movements。partial index 只收沖銷列，很小。
--
-- 基底版本：本函式為全新，無既有版本
--   （git grep "rpc_reverse\|reverse_stock\|reverse_adjust" -- supabase/migrations → 零結果）
-- Rollback：
--   DROP FUNCTION public.rpc_reverse_stock_adjust(BIGINT, UUID, TEXT);
--   DROP INDEX public.idx_mov_reverses;
--   （已寫入的 reversal 列砍不掉 —— stock_movements append-only。要退回帳面
--     只能再開一筆反向分錄。）
-- ============================================================

-- 沖銷關係反查用（守衛 6 與前端「已撤銷」標示）。只收有 reverses 的列。
CREATE INDEX IF NOT EXISTS idx_mov_reverses
  ON stock_movements (reverses)
  WHERE reverses IS NOT NULL;

CREATE OR REPLACE FUNCTION public.rpc_reverse_stock_adjust(
  p_movement_id BIGINT,
  p_operator    UUID    DEFAULT NULL,
  p_reason      TEXT    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID  := (auth.jwt() ->> 'tenant_id')::uuid;
  v_jwt_role   TEXT  := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_operator   UUID  := COALESCE(p_operator, auth.uid());
  v_orig       stock_movements%ROWTYPE;
  v_loc        locations%ROWTYPE;
  v_store_name TEXT;
  v_available  NUMERIC;
  v_rev_id     BIGINT;
  v_on_hand    NUMERIC;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_operator IS NULL THEN
    RAISE EXCEPTION '尚未登入，無法撤銷庫存異動';
  END IF;

  -- 守衛 1 + 2：原筆存在（含 tenant）、鎖住。
  -- FOR UPDATE 只是 row-lock，不觸發 append-only 的 UPDATE trigger
  -- （同 rpc_wallet_reverse 20260606000000:155 的作法）。
  -- 這把鎖同時是「同一筆同時撤兩次」的序列化點：後到的那筆會等到前一筆
  -- commit 之後才往下跑，屆時守衛 6 的 EXISTS 就看得到已寫入的沖銷列。
  SELECT * INTO v_orig
    FROM stock_movements
   WHERE id = p_movement_id
     AND tenant_id = v_tenant
   FOR UPDATE;
  IF v_orig.id IS NULL THEN
    RAISE EXCEPTION '找不到這筆庫存異動（#%）', p_movement_id;
  END IF;

  -- 守衛 3：拒絕撤銷沖銷單（逐字對齊 rpc_wallet_reverse 的 cannot reverse a reversal）
  IF v_orig.movement_type = 'reversal' THEN
    RAISE EXCEPTION '這筆本身就是沖銷紀錄，不能再撤銷（#%）', p_movement_id;
  END IF;

  -- 守衛 4：只撤手動調整
  IF v_orig.movement_type <> 'manual_adjust' THEN
    RAISE EXCEPTION '只能撤銷「手動調整」的庫存異動，這筆是 %（#%）',
      v_orig.movement_type, p_movement_id;
  END IF;

  -- 守衛 9：只撤庫存總覽「＋ 新增庫存」寫的那種（沒有來源單據）
  IF v_orig.source_doc_type IS NOT NULL THEN
    RAISE EXCEPTION '這筆是「%」連動產生的庫存異動，不能單獨撤銷（會讓單據與庫存對不起來），請回該單據處理',
      v_orig.source_doc_type;
  END IF;

  -- 守衛 5：只撤正數（只撤「補進來的」）
  IF v_orig.quantity <= 0 THEN
    RAISE EXCEPTION '只能撤銷「新增庫存」（正數）那一筆，這筆是 %（#%）',
      v_orig.quantity, p_movement_id;
  END IF;

  -- 守衛 10：帶成本的進帳動過均成本，負數沖銷推不回來 → 不給撤
  IF v_orig.unit_cost IS NOT NULL THEN
    RAISE EXCEPTION '這筆帶了成本（%），撤銷會讓均成本算錯，請改走盤點調整',
      v_orig.unit_cost;
  END IF;

  -- 守衛 6：防重複（用 reverses 反查；⛔ 不寫 reversed_by，見檔頭）
  IF EXISTS (
    SELECT 1 FROM stock_movements
     WHERE tenant_id = v_tenant
       AND reverses  = p_movement_id
  ) THEN
    RAISE EXCEPTION '這筆已經撤銷過了（#%）', p_movement_id;
  END IF;

  SELECT * INTO v_loc FROM locations WHERE id = v_orig.location_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '倉別 % 不存在', v_orig.location_id;
  END IF;

  -- 守衛 11：分店角色只能撤自己店的庫存異動。
  -- 逐字對齊 20260816000050 給 rpc_add_stock_by_product 加的守衛 ——
  -- 加得了才撤得掉，兩邊範圍必須一樣，否則這支就是那道守衛的後門。
  IF v_jwt_role IN ('store_manager', 'store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0
     AND NOT (v_my_stores ? '總倉') THEN
    SELECT s.name INTO v_store_name
      FROM stores s
     WHERE s.location_id = v_orig.location_id
       AND s.tenant_id   = v_loc.tenant_id;
    IF v_store_name IS NULL OR NOT (v_my_stores ? v_store_name) THEN
      RAISE EXCEPTION 'wrong_store: 這個倉別（%）不是你的店，分店帳號只能撤銷自己店的庫存異動',
        COALESCE(v_store_name, v_loc.name);
    END IF;
  END IF;

  -- 守衛 7：當下可用量要夠 —— 那批貨可能已經派出去了，硬撤會做出負庫存。
  -- 算式逐字對齊 rpc_outbound 最新版（20260705000000:145-156）：
  -- 可用量 = on_hand - reserved，查不到餘額列視為 0。
  SELECT on_hand - reserved
    INTO v_available
    FROM stock_balances
   WHERE tenant_id   = v_orig.tenant_id
     AND location_id = v_orig.location_id
     AND sku_id      = v_orig.sku_id
   FOR UPDATE;
  IF NOT FOUND THEN
    v_available := 0;
  END IF;

  IF v_available < v_orig.quantity THEN
    RAISE EXCEPTION '撤銷會做出負庫存：這筆補了 % 件，但現在可用只剩 % 件（貨可能已經派出去了）',
      v_orig.quantity, v_available;
  END IF;

  -- 寫沖銷分錄。⛔ 不走 rpc_outbound：它沒有 reverses 參數，串不起沖銷關係。
  -- quantity 取負（CHECK 只要求 <> 0，負數合法）；unit_cost 沿用原筆（此處恆為
  -- NULL，見守衛 10）→ apply_movement_to_balance 走 ELSE，avg_cost 原封不動。
  INSERT INTO stock_movements (
    tenant_id, location_id, sku_id, quantity, unit_cost, movement_type,
    source_doc_type, source_doc_id, reverses, reason, operator_id
  ) VALUES (
    v_orig.tenant_id, v_orig.location_id, v_orig.sku_id,
    -v_orig.quantity,
    v_orig.unit_cost,
    'reversal',
    v_orig.source_doc_type, v_orig.source_doc_id,
    p_movement_id,
    COALESCE(NULLIF(TRIM(p_reason), ''), '撤銷手動新增庫存 #' || p_movement_id::TEXT),
    v_operator
  ) RETURNING id INTO v_rev_id;

  SELECT on_hand INTO v_on_hand
    FROM stock_balances
   WHERE tenant_id   = v_orig.tenant_id
     AND location_id = v_orig.location_id
     AND sku_id      = v_orig.sku_id;

  RETURN jsonb_build_object(
    'reversal_id',  v_rev_id,
    'reversed_id',  p_movement_id,
    'location_id',  v_orig.location_id,
    'sku_id',       v_orig.sku_id,
    'quantity',     -v_orig.quantity,
    'on_hand',      COALESCE(v_on_hand, 0)
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_reverse_stock_adjust(BIGINT, UUID, TEXT) IS
  '撤銷庫存總覽「＋ 新增庫存」補錯的那一筆：寫一筆 reversal(-N) 並用 reverses 指回原筆。'
  '原筆不會消失（stock_movements append-only，帳留痕）。'
  '只收 movement_type=manual_adjust、quantity>0、source_doc_type IS NULL、unit_cost IS NULL 且尚未被撤過的列；'
  '可用量（on_hand-reserved）不足不給撤；分店角色只能撤自己店。';

REVOKE ALL ON FUNCTION public.rpc_reverse_stock_adjust(BIGINT, UUID, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reverse_stock_adjust(BIGINT, UUID, TEXT) TO authenticated;
