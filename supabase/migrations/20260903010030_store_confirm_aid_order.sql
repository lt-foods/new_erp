-- ============================================================================
-- 2026-09-02（收件匣減法案 · 刀 4 · 阿審 P0-3 修正）：
--   店家專用的「確認互助轉入單」RPC —— 有店家範圍守衛的薄包一層
--
-- ⚠️⚠️ 為什麼要有這一支（阿審 P0-3 原話重點）：
--   刀 4 在互助板加了「確認」入口，但它直接打 rpc_advance_order_status，
--   而那一支是 SECURITY DEFINER、**只驗狀態轉移，沒有角色/tenant/店家範圍檢查**
--   （20260623000000_campaign_status_locked.sql，錨點
--     `CREATE OR REPLACE FUNCTION rpc_advance_order_status`，
--     COMMENT 自己寫「bypass RLS」），且 GRANT 給 authenticated。
--   ⇒ **加了入口＝等於在店家端裸開一個「任何人知道 order_id 就能推任何訂單」的窗。**
--   （這個洞本來就在，是我第一版把它從「沒有入口」變成「有入口」——
--     ⛔ 施工回報第一輪我把它寫成「不會放大這個洞」，那句話是錯的：
--       原本店家端沒有任何入口，加了之後就有了。這裡更正。）
--
-- ----------------------------------------------------------------------------
-- 兩個做法選哪個（CEO 要求附理由）：
--   甲、在 rpc_advance_order_status 裡加「非總部角色 → 限自己店」分支
--   乙、新增一支店家專用 RPC 薄包（本檔採用）
--
--   選乙，三個理由：
--   1. **不會弄壞總倉既有用法。** rpc_advance_order_status 有 2 個呼叫點
--      （hq/inbox/page.tsx 與 AidOrderStatusActions.tsx，全 repo grep 過），
--      總倉那條**合法地要能推任何店的單**。改原函式＝把一支所有人都在用的
--      共用函式改成有條件行為，出錯的半徑比新增一支大得多。
--   2. **這一支管得比甲案更緊。** 甲案只能管「店家範圍」；乙案還能多兩道：
--      只允許 pending → confirmed 這**一種**轉移（⛔ 不是通用狀態推進器），
--      而且那張單必須真的是一趟轉單的轉入單（掛在 customer_order_transfer_links 上）。
--      ⇒ 店家不能拿它去推自己店裡的一般客人訂單（那會讓那張單進入自動配單母體）。
--   3. **回滾便宜。** 乙案的 rollback 是 DROP 一支新函式，既有行為零變動；
--      甲案要把一支歷史函式改回去，還得確認沒人已經依賴新行為。
--
--   ⚠️ 誠實說明：乙案**沒有把原本那個洞補起來** ——
--     rpc_advance_order_status 對 authenticated 仍然是裸的。
--     本檔只保證「**我們這次新加的入口不是那個洞的入口**」。
--     原洞要不要補是另一個案（它 8/21 之前就存在，且動它會碰到總倉既有用法）。
--     ⇒ 已寫進施工回報的「已知風險」。
--
-- ----------------------------------------------------------------------------
-- 店家範圍怎麼比（⭐ 沿用 repo 既有 house pattern，不自己發明）：
--   `public._jwt_store_ids()`（20260707000070_jwt_store_scope_helpers_and_stock_rls.sql）
--   —— 拿 app_metadata.stores 的**店名字串陣列**去對 stores.name，回 store_id[]，
--   tenant 綁定、SECURITY DEFINER。
--   ⛔ 絕對不可以改用 app_metadata.store_id：機制索引記載
--     「線上 33 個 staff 帳號沒有任何一個有 store_id」，用它等於全部擋死。
--   rpc_reject_transfer（20260827020000）也是用同一組 helper 的姊妹版
--   `_jwt_store_location_ids()` 做分店守衛 —— 同一個 house pattern。
--
-- 總部角色放行：owner / admin / hq_manager / hq_accountant / ''（空＝舊帳號沒設 role）
--   ⇒ 與 rpc_resolve_transfer_item_shortage、rpc_ack_transfer_over 的判法一致
--     （那兩支用 `NOT IN ('owner','admin','hq_manager','')` 擋）。
--   ⚠️ 這裡多放行 hq_accountant，因為本動作不碰貨也不碰錢，只推狀態。
--
-- ----------------------------------------------------------------------------
-- ⭐ 2026-09-03 重定基（Alex #898~#904 已上線）—— 本檔對新 main 重驗結論：
--   ✅ rpc_advance_order_status 的最新定義**仍是 20260623000000**
--      （標準查法對新 main 確認：git grep -lnE "FUNCTION (public\.)?rpc_advance_order_status" main）
--      ⇒ 本檔包的東西沒變、守衛前提沒變。
--   ✅ customer_order_transfer_links（③ 那道守衛用它）Alex 這波沒有動
--      （他動的表只有 transfer_items 加一欄、customer_order_audit_log 的 CHECK）。
--   ✅ 本檔與他這波 7 支 migration 零重疊（不碰 transfer_items、不碰短少那條路）。
--   ⚠️ 檔號由 20260902060030 改成 20260903010030 —— 排在他 20260903000200 之後。
-- ----------------------------------------------------------------------------
--
-- 基底：無（全新函式）。⛔ 一行都沒有動 rpc_advance_order_status。
-- Rollback：DROP FUNCTION public.rpc_store_confirm_aid_order(BIGINT, UUID);
--   （前端要一併改回直接呼叫 rpc_advance_order_status，或把刀 4 那顆鈕拿掉。）
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_store_confirm_aid_order(
  p_order_id BIGINT,
  p_operator UUID
) RETURNS customer_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role       TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_jwt_tenant TEXT := COALESCE(auth.jwt() ->> 'tenant_id', '');
  v_order      customer_orders%ROWTYPE;
  v_my_stores  BIGINT[];
  v_is_hq      BOOLEAN;
  v_linked     BOOLEAN;
  v_in_scope   BOOLEAN;
BEGIN
  SELECT * INTO v_order FROM customer_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張訂單（%）', p_order_id;
  END IF;

  -- ① tenant
  IF v_jwt_tenant <> '' AND v_jwt_tenant::UUID <> v_order.tenant_id THEN
    RAISE EXCEPTION '這張訂單不屬於目前的帳本';
  END IF;

  -- ② 只允許這**一種**轉移。⛔ 這一支不是通用的狀態推進器。
  IF v_order.status <> 'pending' THEN
    RAISE EXCEPTION '這張單目前是「%」，只有「待確認」可以按確認', v_order.status;
  END IF;

  -- ③ 必須真的是一趟轉單的轉入單。
  --    ⛔ 少了這道，店家就能拿這支去推自己店裡的**一般客人訂單** pending → confirmed，
  --      而 confirmed 會讓那張單進入自動配單母體（20260811000020 只吃 confirmed）。
  SELECT EXISTS (
    SELECT 1 FROM customer_order_transfer_links l
     WHERE l.dest_order_id = p_order_id
       AND l.tenant_id = v_order.tenant_id
  ) INTO v_linked;
  IF NOT v_linked THEN
    RAISE EXCEPTION '這張單不是互助／轉單的轉入單，不能用這個方式確認';
  END IF;

  -- ④ 範圍：總部放行任何店；分店只能確認「跟自己有關」的那一趟
  v_is_hq := v_role IN ('owner','admin','hq_manager','hq_accountant','');
  IF v_is_hq THEN
    v_in_scope := TRUE;
  ELSE
    v_my_stores := public._jwt_store_ids();
    -- 我是收貨店（轉入單掛在我店），或我是提供店（來源單掛在我店）——
    -- 兩邊都放行，跟互助板旁邊那顆「取消」的既有規則一致
    -- （mutual-aid/page.tsx：未到貨時兩邊都能取消）。
    SELECT
      COALESCE(v_order.pickup_store_id = ANY (v_my_stores), FALSE)
      OR EXISTS (
        SELECT 1
          FROM customer_order_transfer_links l
          JOIN customer_orders src ON src.id = l.source_order_id
         WHERE l.dest_order_id = p_order_id
           AND l.tenant_id = v_order.tenant_id
           AND COALESCE(src.pickup_store_id = ANY (v_my_stores), FALSE)
      )
      INTO v_in_scope;
  END IF;

  IF NOT v_in_scope THEN
    RAISE EXCEPTION '這一趟不是貴店轉出或轉入的，不能由貴店確認';
  END IF;

  -- ⑤ 真正的狀態推進**重用既有函式**，⛔ 不在這裡自己寫一份狀態機
  --    （寫第二份 = 兩份會漂移；那一支還會補 confirmed_at）。
  RETURN rpc_advance_order_status(p_order_id, 'confirmed', p_operator);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_store_confirm_aid_order(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_store_confirm_aid_order(BIGINT, UUID) IS
  '互助／轉單「確認」的店家專用入口（2026-09-02 刀 4，阿審 P0-3）。'
  '四道守衛：tenant／只允許 pending→confirmed／必須是 customer_order_transfer_links 的轉入單／'
  '分店只能確認自己轉出或轉入的那一趟（總部角色放行任何店）。'
  '狀態推進重用 rpc_advance_order_status —— ⛔ 本檔一行都沒有動那一支（總倉合法可推任何店）。'
  '⚠ 本檔沒有補 rpc_advance_order_status 自身無 scope guard 的既有洞，只保證新入口不是那個洞的入口。';
