-- ============================================================
-- _check_order_edit_perm: 分店身分改用 app_metadata.stores（店名陣列）判定
--
-- 災情：
--   全站分店帳號無法在取貨視窗打折，只能請總部代改。店長按儲存跳：
--     折扣$儲存失敗:permission denied: role=store_manager store=NULL cannot edit order 58112
--
-- 根因：
--   本函式（基底版本 20260605000003_fix_check_order_edit_perm_jwt.sql:24-27）
--   靠 JWT 的 app_metadata.store_id (BIGINT) 判斷分店身分。但線上根本沒有這個欄位——
--   20260808000020_slf_store_scope_by_name.sql 明文記載「線上 33 個 staff 帳號
--   沒有任何一個有 store_id」，系統早已改用 app_metadata.stores（店名 JSON 陣列）。
--   → v_store 恆為 NULL → 店家分支永遠不成立 → 只要不是 HQ 角色一律被拒。
--   本函式是 2026-06-05 寫的，8/08 改成店名陣列時漏改了它。
--
-- 影響的呼叫點（⚠️ 與需求單所列的 8 個不同，實際只有 5 個還活著）：
--   仍在用本函式、本次一起修好的 5 個：
--     20260605000002:67  rpc_update_order_item_price            改單價
--     20260605000002:121 rpc_update_order_discount              改整單折扣
--     20260605000005:136 rpc_update_order_discount_percent      整單折扣百分比
--     20260605000006:153 rpc_update_order_item_discount_amount  行級折扣（金額）
--     20260605000006:207 rpc_update_order_item_discount_percent 行級折扣（百分比）
--   另 3 個呼叫點的文字雖然還在 migration 檔裡，但所屬函式已被後續 migration
--   整支 CREATE OR REPLACE 換掉，線上早就不呼叫本函式，本次不受影響：
--     20260605000002:167 rpc_update_order_notes      → 20260728000000:95  已改用 _check_order_edit_notes_perm
--     20260605000002:210 rpc_update_order_item_notes → 20260728000000:139 已改用 _check_order_edit_notes_perm
--     20260624000000:169 rpc_update_order_item_qty   → 20260629000010:84  已改用 _check_order_edit_qty_perm
--   （即：備註與數量早在 6/29、7/28 就各自被繞過修好了，只有價格與折扣一直漏著。
--     本次修完，三支 guard 的判定語意才終於一致。）
--
-- 基底版本：20260605000003_fix_check_order_edit_perm_jwt.sql
--   本檔逐字複製該版全文，只「追加」新路徑，不刪不改任何既有分支。
--   唯一被改動的既有敘述是最後的 RAISE EXCEPTION 訊息——多印 stores 內容，
--   純診斷用途，不影響授權判定（原本只印 store=NULL，看不出帳號到底掛哪幾家店）。
--
-- 新路徑寫法對齊 20260813000000_pickup_store_guard.sql:75-88 的店家守衛
-- （同一套 house style：jsonb_typeof/jsonb_array_length 檢查 + `?` 運算子比對店名）。
--
-- 兩個刻意的取捨（審 PR 請特別看這兩點）：
--   1. stores 為「空陣列／未設定」的帳號維持「拒絕」，不放行。
--      空陣列無從判斷該帳號屬於哪一店，放行等於對所有未設定帳號全開。
--      ⚠️ 這跟 20260813000000 取貨守衛對空 stores「不鎖」的語意刻意不同：
--         那邊的既有行為是放行，這邊的既有行為是拒絕，
--         兩邊都選擇「不改變各自的既有行為」，本次不趁機調整任何一邊。
--   2. 舊 store_id 路徑保留不刪，向下相容。
--      線上雖然沒有帳號有 store_id，但萬一未來補回這個欄位，行為不變。
--
-- Rollback：重跑 20260605000003_fix_check_order_edit_perm_jwt.sql
--   （該檔即為本函式的上一版全文，直接 CREATE OR REPLACE 蓋回即可，無其他副作用）。
-- ============================================================

CREATE OR REPLACE FUNCTION public._check_order_edit_perm(p_order_id BIGINT)
RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order  customer_orders%ROWTYPE;
  v_tenant UUID   := (auth.jwt() ->> 'tenant_id')::uuid;
  -- 優先 app_metadata.role；若為 NULL/空 視為 admin tier
  v_role   TEXT   := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'role', ''),
                       NULLIF(auth.jwt() ->> 'role', 'authenticated'),
                       ''
                     );
  v_store  BIGINT := COALESCE(
                       NULLIF(auth.jwt() -> 'app_metadata' ->> 'store_id', '')::bigint,
                       NULLIF(auth.jwt() ->> 'store_id','')::bigint
                     );
  -- 新增：線上實際使用的分店身分來源（店名 JSON 陣列）
  v_my_stores  JSONB := COALESCE(auth.jwt() -> 'app_metadata' -> 'stores', '[]'::jsonb);
  v_store_name TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;

  SELECT * INTO v_order
    FROM customer_orders
   WHERE id = p_order_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'order % not found in tenant %', p_order_id, v_tenant;
  END IF;

  -- HQ tier（含 role NULL/空字串）
  IF v_role IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RETURN v_order;
  END IF;

  -- 店家：限自店
  IF v_store IS NOT NULL AND v_order.pickup_store_id = v_store THEN
    RETURN v_order;
  END IF;

  -- 新路徑：改用 app_metadata.stores 店名陣列比對（線上實際的身分模型）。
  -- 對齊 20260813000000_pickup_store_guard.sql:75-88；stores 為空維持拒絕（見檔頭取捨 1）。
  IF v_role IN ('store_manager','store_staff')
     AND jsonb_typeof(v_my_stores) = 'array'
     AND jsonb_array_length(v_my_stores) > 0 THEN
    -- 總倉 magic value：總倉成員視同不鎖店
    IF v_my_stores ? '總倉' THEN
      RETURN v_order;
    END IF;
    SELECT s.name INTO v_store_name
      FROM stores s
     WHERE s.id = v_order.pickup_store_id
       AND s.tenant_id = v_tenant;
    IF v_store_name IS NOT NULL AND (v_my_stores ? v_store_name) THEN
      RETURN v_order;
    END IF;
  END IF;

  RAISE EXCEPTION 'permission denied: role=% store=% stores=% cannot edit order %',
    v_role, COALESCE(v_store::text,'NULL'), v_my_stores::text, p_order_id;
END;
$$;

COMMENT ON FUNCTION public._check_order_edit_perm(BIGINT) IS
  '訂單編輯權限守衛（價格／折扣類 RPC 共用）。'
  'HQ tier (owner/admin/hq_manager/hq_accountant/空) 全過；'
  '其次沿用 JWT app_metadata.store_id 比對 pickup_store_id（向下相容，線上目前無此欄位）；'
  '再者 store_manager/store_staff 以 app_metadata.stores 店名陣列比對訂單 pickup_store.name '
  '（含 ''總倉'' 則不鎖店）。stores 為空維持拒絕。';
