-- ============================================================================
-- 現場銷售 (1/3)：schema —— 唯一索引開洞、品項來源 walk_in、每店現場客假會員
-- ============================================================================
-- 需求（Alex 2026-09-01）：「有店家想要賣現場客，但是沒有訂單，然後又想要維護
--   庫存，可以做一個現場銷售的功能，像是一般超商那樣，可以依照人名跟商品庫存來
--   產生一筆訂單，並且扣掉庫存」。規劃見 docs/PLAN-現場銷售POS.md。
--
-- 現場銷售 = 一張「出生時就已經取完貨」的顧客訂單：
--   單頭 completed、品項直接 picked_up、每列寫 sale movement。
--   走既有 customer_orders 這條路，日結 / 營收 / 退貨 / 撤銷取貨 / 成本
--   才會自動涵蓋（另開表的話 rpc_daily_pickup_settlement 會整批漏掉）。
--
-- ⚠ 不要用 day-1 留下來的 pos_sales / pos_sale_items：
--   那是 20260422120005 通用 ERP 骨架的殘留，線上 0 筆、沒接任何前端、
--   `customer_id` 指的還是空的 customers 表（全站其實用 members）。
--   rpc_complete_pos_sale 也從沒被呼叫過。看到它不要以為那是正主。
--
-- ⚠ 2026-09-01 改過號：原本是 20260901000000，與同日 PR #884 的
--   20260901000000_settlement_dispatch_basis.sql 撞號（同批四支有三支撞）。
--   兩批都已進 main 且已套上正式庫，照 CLAUDE.md 的規矩改名 —— 這個 repo 一律走
--   Management API 直接跑 SQL，不會寫 supabase_migrations.schema_migrations，
--   所以改名安全；「從零重跑」時的順序才不會變成由檔名字串隨機決定。
--   同批的 010010 / 010020 / 010030 一起改，內文引用也一併更新。
--
-- 本檔內容：
--   1. customer_orders_trio_kind_active_uniq：predicate 加排除 'WS-%'。
--   2. customer_order_items.source：CHECK 加 'walk_in'。
--   3. _walkin_member(tenant, store) — 每店一筆「現場客」guest 假會員。
--
-- 基底版本：
--   customer_orders_trio_kind_active_uniq = 20260824060000（線上 pg_indexes
--     逐字抽出：含 order_kind<>'restock'、order_no !~~ 'SP-%'、aid_board_id IS NULL）
--   customer_order_items_source_check     = 20260808000020（線上 pg_constraint 逐字抽出）
--   _walkin_member                        = 無（新函式）
--
-- Rollback：
--   DROP INDEX customer_orders_trio_kind_active_uniq; 再建回不含 'WS-%' 的版本
--     （見下方 §1 註解裡的原版 SQL）；
--   CHECK 改回不含 'walk_in' 的清單（先確認沒有 walk_in 列，否則加不回去）；
--   DROP FUNCTION public._walkin_member(UUID, BIGINT);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 唯一索引排除 WS- 單
--
-- 為什麼一定要開這個洞：同一家店的現場銷售全部掛在
--   （同 tenant、同 sentinel 團、同 sentinel 頻道、同一筆「現場客」假會員、
--     order_kind='normal'）
-- 底下 → 第二張單必然撞這支 partial UNIQUE。而且 predicate 只排除
-- transferred_out / expired / cancelled，**completed 仍在索引母體內**，
-- 所以「上一張已經結掉了」救不了，第二筆現場銷售就會失敗。
--
-- 同 SP- 那次（20260816000060）的作法：只在索引 predicate 開洞，
-- **不新增 order_kind** —— 全站 188 處用 `order_kind='normal' OR IS NULL`
-- 當口徑（營收、未結金額、商品分析…），新 kind 會讓現場銷售整批消失。
--
-- 原版（rollback 用）：
--   CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
--     ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
--    WHERE status <> ALL (ARRAY['transferred_out'::text,'expired'::text,'cancelled'::text])
--      AND order_kind <> 'restock'::text
--      AND order_no NOT LIKE 'SP-%'
--      AND aid_board_id IS NULL;
-- ----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.customer_orders_trio_kind_active_uniq;

CREATE UNIQUE INDEX customer_orders_trio_kind_active_uniq
  ON public.customer_orders (tenant_id, campaign_id, channel_id, member_id, order_kind)
 WHERE status <> ALL (ARRAY['transferred_out'::text, 'expired'::text, 'cancelled'::text])
   AND order_kind <> 'restock'::text
   AND order_no NOT LIKE 'SP-%'
   AND order_no NOT LIKE 'WS-%'
   AND aid_board_id IS NULL;

COMMENT ON INDEX public.customer_orders_trio_kind_active_uniq IS
  '一會員一活動一張 active 單（真團的核心不變量，rpc_create_customer_orders 靠它合併）。'
  'restock（RR- 補貨容器單）、SP-（現貨直配，20260816000060）、'
  'WS-（現場銷售，20260901010000）、互助認領單（aid_board_id）除外 —— '
  '那些是「一次動作一張單」的語意，不該被合併。';

-- ----------------------------------------------------------------------------
-- 2. 品項來源新增 walk_in
--
-- 對齊 apps/admin/src/lib/orderSource.ts 檔頭寫的三步驟（(a) 前端 tuple + meta、
-- (b) 本 CHECK、(c) 是否進 SOURCE_TREND_SERIES）。現場銷售**不進**那張折線圖：
-- 它畫的是「人是怎麼下這張單的」三個線上通路（App / 商城 / 小幫手），
-- 把臨櫃結帳混進去會讓通路消長的圖說謊。
-- ----------------------------------------------------------------------------
ALTER TABLE public.customer_order_items
  DROP CONSTRAINT IF EXISTS customer_order_items_source_check;

ALTER TABLE public.customer_order_items
  ADD CONSTRAINT customer_order_items_source_check CHECK (
    source = ANY (ARRAY[
      'manual'::text,
      'screenshot_parse'::text,
      'csv'::text,
      'rollover'::text,
      'liff'::text,
      'pwa'::text,
      'store_internal'::text,
      'aid_transfer'::text,
      'walk_in'::text
    ])
  );

-- ----------------------------------------------------------------------------
-- 3. _walkin_member — 每店一筆「現場客」共用收件人
--
-- 為什麼不替每位現場客開一筆會員：線上已有 21,538 位沒有電話的 active 會員，
--   一天幾十筆現場客會把會員庫沖爛（搜尋 / 合併 / 標籤跟著爛），而且手機唯一
--   索引那組雷（20260831000050：merged 殘骸佔號、林口 83 筆）會被新路徑再踩一次。
--   真正的客人名字存在訂單的 nickname_snapshot（＝需求說的「依照人名產生訂單」）。
--   店員想把人留下來時，前端改帶真的 member_id 進來，不走這支。
--
-- 為什麼 member_type 用 'guest' 不用 'store_internal'：
--   store_internal 被 rpc_daily_pickup_settlement **明文排除**（那是現貨池帳本
--   搬運，不是對客人收的錢）→ 掛上去等於現場銷售收的錢在日結看不到，
--   正好把最重要的那件事弄壞。它還被 _sku_commitment 的池子口徑、
--   rpc_record_pickup 的零元守衛特判，語意完全不同。
--   'guest' 在 CHECK 裡合法（20260429120000）、後台 MemberDetail 已經會顯示
--   「訪客」標籤，而線上一筆都沒有 → 乾淨的新語意。
--
-- phone / phone_hash 一律留 NULL：不佔號，也就繞開唯一索引那整組問題。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._walkin_member(
  p_tenant   UUID,
  p_store_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_store stores%ROWTYPE;
  v_no    TEXT;
  v_id    BIGINT;
BEGIN
  SELECT * INTO v_store FROM stores WHERE id = p_store_id AND tenant_id = p_tenant;
  IF NOT FOUND THEN
    RAISE EXCEPTION '分店 % 不存在（tenant %）', p_store_id, p_tenant;
  END IF;

  v_no := 'WALKIN-' || p_store_id::TEXT;

  SELECT id INTO v_id FROM members WHERE tenant_id = p_tenant AND member_no = v_no;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO members (
    tenant_id, member_no, name, member_type, home_store_id, status, notes
  ) VALUES (
    p_tenant, v_no, '現場客（' || v_store.name || '）', 'guest', p_store_id, 'active',
    '門市現場銷售的共用收件人（20260901010000）。真正的客人名字存在該筆訂單的 '
    'nickname_snapshot；不要拿它當真的會員做行銷 / 通知 / 合併。'
  )
  ON CONFLICT (tenant_id, member_no) DO NOTHING
  RETURNING id INTO v_id;

  -- 併發時另一個交易先插入 → ON CONFLICT 不回列，補撈一次
  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM members WHERE tenant_id = p_tenant AND member_no = v_no;
  END IF;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public._walkin_member(UUID, BIGINT) IS
  '取得（沒有就建）某店的「現場客」共用假會員 WALKIN-<store_id>（member_type=guest）。'
  '現場銷售不替每位客人開會員，人名存訂單的 nickname_snapshot。'
  '不可用 store_internal —— 那會被日結報表排除掉。';

REVOKE ALL ON FUNCTION public._walkin_member(UUID, BIGINT) FROM PUBLIC, anon, authenticated;
