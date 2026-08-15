-- ============================================================
-- 訂單金額編輯權：分店帳號改用「員工功能權限」orders_edit_amount 個別授予
--
-- 災情：
--   全站分店帳號無法在取貨視窗打折，只能請總部代改。店長按儲存跳：
--     折扣$儲存失敗:permission denied: role=store_manager store=NULL cannot edit order 58112
--
-- 根因：
--   守衛 _check_order_edit_perm（基底版本 20260605000003_fix_check_order_edit_perm_jwt.sql:24-27）
--   靠 JWT 的 app_metadata.store_id (BIGINT) 判斷分店身分。但線上根本沒有這個欄位——
--   20260808000020_slf_store_scope_by_name.sql 明文記載「線上 33 個 staff 帳號
--   沒有任何一個有 store_id」，系統早已改用 app_metadata.stores（店名 JSON 陣列）。
--   → v_store 恆為 NULL → 店家分支永遠不成立 → 只要不是 HQ 角色一律被拒。
--   本函式是 2026-06-05 寫的，8/08 改成店名陣列時漏改了它。
--
-- ⚠️ 設計變更（2026-08-14，老闆與工程師定案）：從「角色制」改成「功能權限制」
--   本檔第一版是角色制——只要 role 是 store_manager/store_staff 且店名對得上就放行，
--   等於「全站所有分店帳號一次全開」，要收回只能改程式再上一次線。
--   改成掛既有的員工功能權限（員工管理 → 功能權限，app_metadata.perms）逐人授予：
--     - 出事可在後台取消勾選收回，不用動程式（且是即時的，見下面「為什麼要查 auth.users」）
--     - 可以只給某一家店、某一個人試用
--     - 用系統既有機制，不再為這件事開特例
--   權限 key：orders_edit_amount（「訂單金額：可改單價與折扣」）
--   20260803000000_staff_feature_perms.sql:13 檔頭已寫明擴充方式＝
--   「在 _is_valid_staff_perm 補 key + 前端 ALL_STAFF_PERMS 補一筆」，本檔照做。
--
-- ⚠️⚠️ 為什麼要查 auth.users 而不只信 JWT（2026-08-14 第二輪審查 P0 / P1-2 修正）
--   ❌ 本檔第一版的檔頭寫「出事可在後台取消勾選**當場**收回」——那句話當時是錯的。
--      role / perms / stores 全都存在 access token 裡，後台取消勾選只改
--      auth.users.raw_app_meta_data，**舊 token 到期前內容還是舊的**。實際災情有兩條：
--        P0  停用帳號還能改金額：停用只是把 role 改成 'disabled'（20260613000150:151），
--            停用前發出的 JWT 裡 role 仍是 store_manager、perms 仍留著 orders_edit_amount
--            → 舊路徑、新路徑都通得過。而且因為 JWT 內的 role 是舊的，
--            光加一條 v_role <> 'disabled' 也擋不住（擋的是舊值）。
--        P1-2 撤回權限也不是當場生效，最長要等一個 access token TTL。
--   ✅ 修法：守衛內用 auth.uid() 直接查 auth.users.raw_app_meta_data 的即時
--      role / perms / stores，之後所有判定都用即時值。
--      → 停用與撤權現在**確實是即時生效**（下一次呼叫就擋掉，不必等 token 過期、
--        不必請當事人重新登入）。檔頭那句「當場收回」到這一版才成立。
--   ℹ️ auth.uid() 為 NULL 時（service_role、edge function、任何沒有 sub 的 token）
--      **不做即時查詢**，沿用原本從 auth.jwt() 算出來的 role/store/stores/perms，
--      行為與本次修改前一字不差 —— 不因為這次改動把 service_role 擋掉。
--      （現況：這 5 支金額 RPC 只有 apps/admin 前端在呼叫，supabase/functions 底下
--        13 支 edge function 沒有任何一支碰它們；此 fallback 是保險，不是現行路徑。）
--   ℹ️ auth.uid() 有值但 auth.users 查無此人（帳號被硬刪）→ 直接拒絕。
--      理由：token 指名的使用者已不存在，沒有任何權限可言；此處刻意選 fail-closed。
--   ℹ️ 成本：每次改價/改折扣多一次 auth.users 主鍵單筆查詢（走 pkey index），
--      而且只在「按下儲存」時發生，不在讀取路徑上。
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
--   （即：備註與數量早在 6/29、7/28 就各自被繞過修好了，只有價格與折扣一直漏著。）
--
-- 基底版本（兩支都是逐字複製既有全文再追加，零刪除）：
--   _is_valid_staff_perm  ← 20260803000000_staff_feature_perms.sql:35-40，白名單多一個 key
--   _check_order_edit_perm ← 20260605000003_fix_check_order_edit_perm_jwt.sql:9-55，只追加新路徑
--   既有敘述一行未刪；被「改動」的只有兩處，且都是刻意的：
--     (a) 最後的 RAISE EXCEPTION 訊息——多印 stores 與 perm 判定結果，純診斷用途，
--         不影響授權判定（原本只印 store=NULL，看不出帳號掛哪幾家店、有沒有被授權）。
--     (b) 舊 store_id 路徑的 IF 多一個 AND v_has_perm（第二輪審查 P1-1，理由見下方取捨 2）。
--   HQ tier 的三行（白名單含 '' → role NULL/空視為 HQ）完全原封不動。
--
-- 新路徑是「雙閘門」，不是換一道門：
--   閘門一 orders_edit_amount 功能權限            → 這個人有沒有被授權改金額
--   閘門二 stores 店名比對                        → 這張單是不是他自己店的
--   （兩個閘門吃的都是 auth.users 的即時值，不是 JWT，見上面 P0 那段）
--   兩關都過才放行。有權限也只能改自己店的單。
--   閘門二的寫法對齊 20260813000000_pickup_store_guard.sql:75-88 的店家守衛
--   （同一套 house style：jsonb_typeof/jsonb_array_length 檢查 + `?` 運算子比對店名）。
--
-- ⚠️⚠️ 這次「放寬」了 role gate，請審 PR 的工程師決定要不要收回去：
--   本檔第一版的新路徑限定 v_role IN ('store_manager','store_staff')。
--   改成權限制之後把這個 role gate 拿掉了——理由是既然要一人一人勾才有權限，
--   role 白名單就是多餘的第二份名單，反而害 assistant / purchaser 之類的角色
--   勾了也不能用、還得再改一次程式。把關交給 perms。
--   但這確實是擴大授權面：任何角色只要被勾了 orders_edit_amount 且店名對得上就能改金額。
--   ✅ 但 role='disabled' 的停用帳號已在本版被擋死——不是靠 role 白名單，
--      是靠上面的 auth.users 即時查核（見「為什麼要查 auth.users」P0）。
--   要收回去只要在新路徑補一行 AND v_role IN (...) 就好，其餘不動
--   （v_role 此時已是 auth.users 的即時 role，不是 JWT 快照）。
--
-- 兩個刻意的取捨（審 PR 請一併看）：
--   1. stores 為「空陣列／未設定」的帳號維持「拒絕」，不放行。
--      空陣列無從判斷該帳號屬於哪一店，放行等於對所有未設定帳號全開。
--      ⚠️ 這跟 20260813000000 取貨守衛對空 stores「不鎖」的語意刻意不同：
--         那邊的既有行為是放行，這邊的既有行為是拒絕，
--         兩邊都選擇「不改變各自的既有行為」，本次不趁機調整任何一邊。
--   2. 舊 store_id 路徑保留不刪，向下相容。
--      線上雖然沒有帳號有 store_id，但萬一未來補回這個欄位，行為不變。
--      ⚠️ 2026-08-14 第二輪審查 P1-1：這條原本**不吃**功能權限，等於一條繞過新授權設計的
--         後門（前端已用 canEditAmount 鎖住、DB 卻放行），與「改用功能權限」自相矛盾。
--         本版補上 v_has_perm，與新路徑一致。線上無帳號有 store_id，實務影響為零。
--
-- ⚠️ 上線後要記得：
--   - DB 這一側不用等 token：權限勾選／取消、帳號停用，下一次呼叫就生效（查 auth.users 即時值）。
--   - **前端 UI 仍讀 JWT**（useHasStaffPerm → user.app_metadata.perms），所以剛被勾權限的員工
--     畫面上金額欄還是灰的，要重新登入 / token refresh 才會亮。前端只是 UX，
--     所有分岐都是 fail-closed（畫面亮但 DB 拒 → 跳錯誤；畫面灰但 DB 允許 → 少一次可編輯），
--     不會讓沒權限的人改到金額，故本次不改前端（見 PR #727 說明）。
--   - 本檔不動 rpc_update_staff_perms / rpc_list_staff：它們吃 _is_valid_staff_perm
--     白名單，加了 key 就自動支援，員工管理頁不用改後端。
--
-- Rollback：
--   重跑 20260803000000_staff_feature_perms.sql（還原 _is_valid_staff_perm 白名單）
--   + 重跑 20260605000003_fix_check_order_edit_perm_jwt.sql（還原守衛）。
--   兩檔皆為各自函式的上一版全文，直接 CREATE OR REPLACE 蓋回即可，無其他副作用。
--   （已經被勾在 app_metadata.perms 裡的 orders_edit_amount 會變成無效 key，
--     不影響任何既有邏輯，下次存員工權限時會被 rpc_update_staff_perms 擋下並提示。）
-- ============================================================

-- ------------------------------------------------------------
-- 1. 合法 perm key 白名單 — 逐字複製 20260803000000:35-40，只追加一個 key
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._is_valid_staff_perm(p_perm TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
  SELECT p_perm IN (
    'orders_pivot_all_stores',  -- 訂單樞紐表：檢視所有門市欄位
    'orders_edit_amount'        -- 訂單金額：可改單價與折扣（限自己店的訂單）
  );
$$;

-- CREATE OR REPLACE 會保留既有 GRANT，這裡重下一次純粹讓本檔自成一體
GRANT EXECUTE ON FUNCTION public._is_valid_staff_perm(TEXT) TO authenticated;

-- ------------------------------------------------------------
-- 2. 訂單編輯權限守衛 — 逐字複製 20260605000003:9-55，只追加新路徑
-- ------------------------------------------------------------
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
  -- 新增：本人有沒有被授予「訂單金額：可改單價與折扣」功能權限
  -- ⚠️ 這三個 JWT 值只是「auth.uid() 為 NULL 時」的 fallback 初值；
  --    一般登入者會在下面被 auth.users 的即時值覆蓋（見 BEGIN 內的即時查核）。
  v_has_perm   BOOLEAN := public._jwt_has_perm('orders_edit_amount');
  -- 新增：auth.users 的即時值（不信 JWT 快照，理由見檔頭）
  v_live_role   TEXT;
  v_live_perms  JSONB;
  v_live_stores JSONB;
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

  -- ------------------------------------------------------------------
  -- 即時權限查核：role / perms / stores 一律改讀 auth.users，不信 JWT 快照
  --   停用與撤權都只是改 auth.users.raw_app_meta_data，舊 access token 到期前
  --   內容還是舊的 → 只看 auth.jwt() 會讓「已停用帳號」「已被撤回權限的人」
  --   繼續改金額（見檔頭「為什麼要查 auth.users」）。
  --   auth.uid() 為 NULL（service_role / 無 sub 的 token）不做即時查核，
  --   沿用上面 DECLARE 由 JWT 算出的值，行為與本次修改前完全相同。
  --   本函式 SET search_path = public，故 auth.users 完全限定寫；
  --   同 house style：rpc_list_staff（20260803000000:168）也是 SECURITY DEFINER
  --   直接 FROM auth.users。
  -- ------------------------------------------------------------------
  IF auth.uid() IS NOT NULL THEN
    SELECT COALESCE(u.raw_app_meta_data ->> 'role', ''),
           COALESCE(u.raw_app_meta_data -> 'perms',  '[]'::jsonb),
           COALESCE(u.raw_app_meta_data -> 'stores', '[]'::jsonb)
      INTO v_live_role, v_live_perms, v_live_stores
      FROM auth.users u
     WHERE u.id = auth.uid();

    IF NOT FOUND THEN
      -- token 指名的使用者已不存在（帳號被硬刪）→ 沒有任何權限可言
      RAISE EXCEPTION 'permission denied: 帳號不存在（uid=%），無法編輯訂單 %',
        auth.uid(), p_order_id;
    END IF;

    -- 停用帳號一律拒絕（即使停用前發出的 JWT 尚未過期）
    IF v_live_role = 'disabled' THEN
      RAISE EXCEPTION 'permission denied: 此帳號已停用，無法編輯訂單 %', p_order_id;
    END IF;

    -- 之後的判定一律改用即時值。
    -- ⚠️ HQ tier 語意原封不動：raw_app_meta_data 沒有 role（NULL）時 COALESCE 成 ''，
    --    '' 仍在下面的 HQ 白名單裡 → 「role 為 NULL/空 = HQ tier」不變。
    v_role      := v_live_role;
    v_my_stores := v_live_stores;
    -- 對齊 _jwt_has_perm（20260803000000:49-56）：非陣列一律視為沒有權限
    v_has_perm  := (jsonb_typeof(v_live_perms) = 'array'
                    AND (v_live_perms ? 'orders_edit_amount'));
  END IF;

  -- HQ tier（含 role NULL/空字串）
  IF v_role IN ('owner','admin','hq_manager','hq_accountant','') THEN
    RETURN v_order;
  END IF;

  -- 店家：限自店（舊 store_id 路徑，向下相容）
  -- ⚠️ 2026-08-14 審查 P1-1：這條原本不吃功能權限，等於繞過新的授權設計
  --    （前端鎖住但 DB 放行）。補上 v_has_perm 與新路徑對齊。
  --    v_store 本身仍取自 JWT（auth.users 沒有這個欄位可查、線上也無帳號有它），
  --    但把關的 v_has_perm 已是即時值，停用／撤權一樣擋得住。
  IF v_has_perm AND v_store IS NOT NULL AND v_order.pickup_store_id = v_store THEN
    RETURN v_order;
  END IF;

  -- 新路徑（雙閘門）：
  --   閘門一 = 有沒有被授予 orders_edit_amount 功能權限（owner/admin 在員工管理頁逐人勾）
  --   閘門二 = 這張單是不是自己店的（app_metadata.stores 店名陣列，線上實際的身分模型）
  -- 對齊 20260813000000_pickup_store_guard.sql:75-88；stores 為空維持拒絕（見檔頭取捨 1）。
  -- role gate 已刻意拿掉，改由 perms 把關（見檔頭「放寬」警告）；
  -- 停用帳號則在上面的即時查核就已被擋掉，走不到這裡。
  IF v_has_perm
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

  -- 診斷訊息：登入者印的是 auth.users 即時值（非 JWT 快照），排查時看到什麼就是判定用的什麼
  RAISE EXCEPTION 'permission denied: role=% store=% stores=% perm(orders_edit_amount)=% cannot edit order %',
    v_role, COALESCE(v_store::text,'NULL'), v_my_stores::text, v_has_perm, p_order_id;
END;
$$;

COMMENT ON FUNCTION public._check_order_edit_perm(BIGINT) IS
  '訂單編輯權限守衛（價格／折扣類 RPC 共用）。'
  'role／perms／stores 一律取 auth.users.raw_app_meta_data 的即時值，不信 JWT 快照 —— '
  '停用帳號一律拒絕、撤回權限即時生效，不必等舊 access token 過期；'
  'auth.uid() 為 NULL（service_role 等）時不做即時查核，沿用 JWT，行為與先前相同。'
  'HQ tier (owner/admin/hq_manager/hq_accountant/空) 全過；'
  '其次 store_id 比對 pickup_store_id（向下相容，線上目前無此欄位，且同樣需有 orders_edit_amount）；'
  '再者「雙閘門」：需有 orders_edit_amount 功能權限（員工管理頁逐人授予），'
  '且以 stores 店名陣列比對訂單 pickup_store.name（含 ''總倉'' 則不鎖店）。'
  'stores 為空維持拒絕。';
