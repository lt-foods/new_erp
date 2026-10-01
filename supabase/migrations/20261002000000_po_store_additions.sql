-- ============================================================================
-- 採購單頁「分店／批發追加」
-- 規格：公司\01_進行中\實作計畫_NEW-ERP採購單頁分店批發追加_2026-10-01.md（第二部分）
--
-- 解決的問題
--   團已結單／已鎖、已轉採購、貨還沒到也還沒派，這時分店或批發要追加。
--   現在只能「重開團 → 加單 → 關團」，重開團會叫醒 LINE 記事本機器人發文。
--   本檔讓採購單頁直接追加，**不重開團**（團只上列鎖、一個欄位都不改）。
--
-- 按一次「送出」系統同時做三件事（少一件都會錯，需求單 §二）
--   ① 在原團幫那家店加「店家內部單」
--      → 派貨工作台每家店要幾件是看**訂單**，不是看採購單數字（20260908000000:62-72）
--   ② 採購單這個商品 +X
--   ③ 請購單對應那一列 +X（先各團明細、後總數）
--      → 派貨工作台靠請購單知道採購單屬於哪一團（20260908000000:41-56）；
--        不改的話補單差額會變 +X，「結單日補單」會再多開一張＝重複叫貨
--
-- X 是多少（X 可能 ≠ 店家加的件數 N）
--   ①做完後呼叫既有的 `_pr_campaign_sku_remaining_rows`（唯一定義 20260921001000:240，
--   本檔只讀不改）取這個 (團, 商品) 的差額，X = max(差額, 0)：
--   - 原本多叫（有人取消）→ X < N，先用掉多出來的，不多加採購單
--   - 這個團原本就有還沒叫貨的量 → X > N，一起補進這張採購單（跟 #995 同一套算法）
--
-- 本檔的範圍
--   🔒 **100% 只新增，不碰任何既有物件。**
--      新增 4 支函式：
--        _po_item_store_add_block_reason   （內部、唯讀：預覽與寫入共用的檢查）
--        _store_add_internal_order_item    （內部：建店家內部單，只給本檔用）
--        rpc_preview_po_store_additions    （畫面用、唯讀）
--        rpc_add_po_store_demands          （畫面用、寫入）
--      0 張表、0 個索引、0 條 policy、0 個觸發器、0 個 ALTER、
--      0 個 CREATE OR REPLACE 打在既有函式上（前置檢查會擋同名的別人的函式）。
--   ⛔ 不改：rpc_add_pr_store_demands（#995，20260924010000）、v_picking_demand_by_po
--      （20260908000000:18）、#982 防重守衛與共用零件（20260921001000:240,485）、
--      #1049 權限守衛 _pr_qty_sync_assert_perm（20261001000000:182）。
--   ⛔ 權限守衛重用 _pr_qty_sync_assert_perm、差額重用 _pr_campaign_sku_remaining_rows，
--      本檔沒有抄第二份。
--   ⛔ 不通知廠商、不做減量／刪除、不碰客人單、不幫已存在的 pending 店家單推 confirmed。
--
-- ⚠️ 兩份同樣的邏輯（改一份要兩份一起改）
--   `_store_add_internal_order_item` 的建店家內部單邏輯，是照
--   `rpc_add_pr_store_demands`（20260924010000:244-341）那段抽出來的**第二份**。
--   #995 那份本檔沒有動。之後任何一份改了（找既有單的條件、單號規則、狀態檢查），
--   另一份要一起改。
--
-- 寫入順序（⚠️ 不可調動）
--   第 1 步 每家店建店家內部單（+N）
--   第 2 步 取差額，X = max(差額, 0)
--   第 3 步 X > 0：先 purchase_request_item_campaigns +X、再 purchase_request_items +X，
--           再重算 purchase_requests.total_amount
--           （順序反了 #982 守衛會擋：20260921001000:543-550；本機已實跑證實）
--   第 4 步 X > 0：purchase_order_items.qty_ordered +X，再重算採購單表頭金額
--   第 5 步 每家店寫一列 purchase_request_store_additions（pr_delta_qty = X）
--
-- 上鎖順序（固定）
--   request_key → 採購單 → 採購單品項 → 請購單與品項 → 團 → (團, 商品) advisory lock
--   （最後一把跟 #982 守衛、#995 是同一把）。**鎖完再跑一次檢查**：檢查完到上鎖之間
--   如果有人開了進貨單／撿貨單／按斷貨，那些動作會碰同一列（外鍵或 UPDATE），
--   會等我們、或我們等它；等完再查一次就看得到。
--
-- 採購單表頭金額怎麼算（照既有寫入點，不自己發明）
--   全 repo 只有兩處寫 purchase_orders 的 subtotal／total，算法相同：
--     rpc_split_pr_to_pos         20260428120000:396-405
--     _split_stockout_po_items    20260812000000:197-204（註解寫明「稅額沿用 rpc_split_pr_to_pos」）
--   ⇒ subtotal = SUM(qty_ordered * unit_cost)、total = subtotal、tax 不動。
--   前端只讀不寫（orders/page.tsx、orders/edit/page.tsx 都是自己加總顯示）。
--
-- Rollback：本檔沒有改任何既有物件，DROP 這 4 支函式即可。
--   DROP FUNCTION IF EXISTS public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID);
--   DROP FUNCTION IF EXISTS public.rpc_preview_po_store_additions(BIGINT);
--   DROP FUNCTION IF EXISTS public._store_add_internal_order_item(UUID, BIGINT, TEXT, BIGINT, BIGINT, NUMERIC, BIGINT, NUMERIC, UUID, TEXT, TEXT);
--   DROP FUNCTION IF EXISTS public._po_item_store_add_block_reason(BIGINT, BIGINT);
--   （已經寫進去的店家內部單、數量、紀錄不會因為 DROP 而退回。）
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、唯讀
--    這份 SQL 是貼進 SQL Editor 執行的（autocommit、沒有交易保護），
--    前提不成立時要在「還沒動任何東西」的階段就停下來。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing  TEXT[] := ARRAY[]::TEXT[];
  v_conflict TEXT[] := ARRAY[]::TEXT[];
  v_name     TEXT;
  v_expected TEXT;
  v_rec      RECORD;
BEGIN
  -- 依賴的既有表
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_orders', 'purchase_order_items',
    'purchase_requests', 'purchase_request_items',
    'purchase_request_item_campaigns', 'purchase_request_campaigns',
    'purchase_request_store_additions',
    'group_buy_campaigns', 'campaign_items',
    'customer_orders', 'customer_order_items',
    'stores', 'line_channels', 'skus',
    'goods_receipts', 'goods_receipt_items',
    'picking_waves', 'picking_wave_items'
  ] LOOP
    IF to_regclass('public.' || v_name) IS NULL THEN
      v_missing := v_missing || ('table public.' || v_name);
    END IF;
  END LOOP;

  -- 依賴的既有欄位（後來才 ADD COLUMN 的那些）
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_order_items.stockout_at',
    'purchase_orders.subtotal',
    'purchase_orders.total',
    'group_buy_campaigns.owner_store_id',
    'stores.store_kind',
    'stores.deleted_at',
    'customer_orders.order_kind',
    'customer_orders.aid_board_id',
    'customer_orders.confirmed_at',
    'picking_waves.source_po_id',
    'purchase_request_store_additions.request_key',
    'purchase_request_store_additions.pr_delta_qty',
    'purchase_request_store_additions.pr_qty_after'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(v_name, '.', 1))
         AND a.attname = split_part(v_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      v_missing := v_missing || ('column public.' || v_name);
    END IF;
  END LOOP;

  -- 依賴的既有函式（⚠️ 本檔只呼叫、不改；這裡是確認在不在，不是驗版本）
  FOR v_rec IN
    SELECT *
      FROM (VALUES
        ('_current_tenant_id', ''),
        ('_pr_campaign_sku_remaining_rows', 'p_campaign_ids bigint[]'),
        ('_pr_qty_sync_assert_perm', ''),
        ('rpc_get_or_create_store_member', 'p_store_id bigint, p_operator uuid')
      ) AS x(fn, args)
  LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public'
         AND p.proname = v_rec.fn
         AND pg_get_function_identity_arguments(p.oid) = v_rec.args
    ) THEN
      v_missing := v_missing || ('function public.' || v_rec.fn || '(' || v_rec.args || ')');
    END IF;
  END LOOP;

  -- #982 三個防重守衛必須在（本檔不動它們，但寫進去的數字要通得過它們）
  FOREACH v_name IN ARRAY ARRAY[
    'trg_pri_cross_close_date_duplicate_guard',
    'trg_pric_cross_close_date_duplicate_guard',
    'trg_prc_cross_close_date_duplicate_guard'
  ] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE NOT tgisinternal AND tgname = v_name) THEN
      v_missing := v_missing || ('trigger ' || v_name || ' (#982)');
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    v_missing := v_missing || 'role authenticated'::TEXT;
  END IF;

  -- 「只新增」的保險：4 個新名字如果已經存在，必須是本檔建的（函式本體帶著本檔的記號）、
  -- 而且參數一模一樣。否則 CREATE OR REPLACE 會**蓋掉別人的函式**或多長一個同名多載 → 停。
  FOR v_rec IN
    SELECT p.proname,
           pg_get_function_identity_arguments(p.oid) AS args,
           (p.prosrc LIKE '%po_store_additions:20261002000000%') AS ours
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('_po_item_store_add_block_reason', '_store_add_internal_order_item',
                         'rpc_preview_po_store_additions', 'rpc_add_po_store_demands')
  LOOP
    v_expected := CASE v_rec.proname
      WHEN '_po_item_store_add_block_reason' THEN
        'p_po_item_id bigint, p_campaign_id bigint'
      WHEN '_store_add_internal_order_item' THEN
        'p_tenant uuid, p_campaign_id bigint, p_campaign_no text, p_campaign_item_id bigint, '
        || 'p_sku_id bigint, p_unit_price numeric, p_store_id bigint, p_qty numeric, '
        || 'p_operator uuid, p_order_note text, p_item_note text, '
        || 'OUT o_order_id bigint, OUT o_order_item_id bigint, OUT o_order_created boolean'
      WHEN 'rpc_preview_po_store_additions' THEN
        'p_po_id bigint'
      WHEN 'rpc_add_po_store_demands' THEN
        'p_po_id bigint, p_po_item_id bigint, p_campaign_id bigint, p_additions jsonb, '
        || 'p_operator uuid, p_request_key uuid'
    END;

    IF NOT v_rec.ours OR v_rec.args IS DISTINCT FROM v_expected THEN
      v_conflict := v_conflict || ('public.' || v_rec.proname || '(' || v_rec.args || ')');
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%',
      array_to_string(v_missing, E'\n');
  END IF;

  IF array_length(v_conflict, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。已經有同名但不是本檔建的函式（或參數不同），貼下去會蓋掉它：\n%',
      array_to_string(v_conflict, E'\n');
  END IF;
END
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. 新增：檢查「這個採購單品項 × 這個團」能不能追加（內部、唯讀）
--    回 NULL ＝ 可以；否則回中文原因。預覽與寫入共用這一支（寫入在鎖完之後再跑一次）。
--    p_campaign_id 傳 NULL ＝ 這個商品對不出任何團（預覽用來產生原因）。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._po_item_store_add_block_reason(
  p_po_item_id  BIGINT,
  p_campaign_id BIGINT
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_poi        RECORD;
  v_camp       RECORD;
  v_rows       INTEGER;
  v_item_qty   NUMERIC;
  v_attr_total NUMERIC;
BEGIN
  SELECT poi.id, poi.po_id, poi.sku_id, poi.qty_received, poi.stockout_at,
         po.status AS po_status
    INTO v_poi
    FROM public.purchase_order_items poi
    JOIN public.purchase_orders po
      ON po.id = poi.po_id
   WHERE poi.id = p_po_item_id
     AND po.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RETURN '找不到這個採購單品項';
  END IF;

  -- ① 採購單已送出（草稿／部分到貨／全到／結案／取消都不行）
  IF v_poi.po_status <> 'sent' THEN
    RETURN '採購單目前是「'
      || CASE v_poi.po_status
           WHEN 'draft'              THEN '草稿（還沒送出）'
           WHEN 'partially_received' THEN '部分到貨'
           WHEN 'fully_received'     THEN '全部到貨'
           WHEN 'closed'             THEN '已結案'
           WHEN 'cancelled'          THEN '已取消'
           ELSE v_poi.po_status
         END
      || '」，只有已送出、還沒收貨的採購單可以追加';
  END IF;

  -- ② 沒有被按過斷貨
  IF v_poi.stockout_at IS NOT NULL THEN
    RETURN '這個商品已經按過斷貨';
  END IF;

  -- ③ 還沒收過貨，而且沒有未取消的進貨單
  IF COALESCE(v_poi.qty_received, 0) <> 0 THEN
    RETURN '這個商品已經收過貨（已收 ' || trim_scale(v_poi.qty_received)::TEXT || '）';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.goods_receipt_items gri
      JOIN public.goods_receipts gr
        ON gr.id = gri.gr_id
     WHERE gri.po_item_id = p_po_item_id
       AND gr.status <> 'cancelled'
  ) THEN
    RETURN '這個商品已經有進貨單（還沒取消），不能再追加';
  END IF;

  -- ④ 沒有未取消的撿貨單
  IF EXISTS (
    SELECT 1
      FROM public.picking_waves pw
      JOIN public.picking_wave_items pwi
        ON pwi.wave_id = pw.id
     WHERE pw.source_po_id = v_poi.po_id
       AND pwi.sku_id = v_poi.sku_id
       AND pw.status <> 'cancelled'
  ) THEN
    RETURN '這個商品已經開了撿貨單';
  END IF;

  IF p_campaign_id IS NULL THEN
    RETURN '對不出這個商品是哪一團的（請購單沒有連到有賣這個商品的團），不能從這裡追加';
  END IF;

  -- ⑤ 這個團屬於這個採購單品項 —— 路徑跟派貨表 v_picking_demand_by_po 的
  --    po_campaigns 一樣（20260908000000:41-56）：
  --    purchase_request_items.po_item_id → purchase_request_campaigns ∪ source_campaign_id
  --    ℹ️ 本函式查請購品項時都多帶 `pri.sku_id = 採購單品項的 sku`：只有 rpc_split_pr_to_pos
  --       （20260428120000:389）與 rpc_merge_prs_to_po（20260422120004:417）會寫 po_item_id，
  --       兩支都是依 sku 對上的，所以結果不變；多這個條件是讓查詢能用 idx_pri_sku_id
  --       （purchase_request_items 沒有 po_item_id 的索引）。
  IF NOT EXISTS (
    SELECT 1
      FROM public.purchase_request_items pri
     WHERE pri.po_item_id = p_po_item_id
       AND pri.sku_id = v_poi.sku_id
       AND (
         pri.source_campaign_id = p_campaign_id
         OR EXISTS (
           SELECT 1
             FROM public.purchase_request_campaigns prc
            WHERE prc.pr_id = pri.pr_id
              AND prc.campaign_id = p_campaign_id
         )
       )
  ) THEN
    RETURN '這個團不在這個採購單品項上（請購單沒有連到這個團）';
  END IF;

  -- ⑥ 團：已結單或已鎖、不是店家自開團、而且有賣這個商品
  SELECT gbc.id, gbc.status, gbc.owner_store_id
    INTO v_camp
    FROM public.group_buy_campaigns gbc
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RETURN '找不到這個團';
  END IF;

  IF v_camp.status NOT IN ('closed', 'locked') THEN
    RETURN '這個團目前是「'
      || CASE v_camp.status
           WHEN 'draft'     THEN '草稿'
           WHEN 'open'      THEN '開團中'
           WHEN 'completed' THEN '已完成'
           WHEN 'cancelled' THEN '已取消'
           ELSE v_camp.status
         END
      || '」，只有已結單／已鎖定的團可以從採購單追加（這裡不會重開團）';
  END IF;

  IF v_camp.owner_store_id IS NOT NULL THEN
    RETURN '這個團是店家自己開的團（貨由店家自己採購），不能從這裡追加';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.campaign_items ci
     WHERE ci.tenant_id = v_tenant
       AND ci.campaign_id = p_campaign_id
       AND ci.sku_id = v_poi.sku_id
  ) THEN
    RETURN '這個團沒有賣這個商品（找不到開團商品）';
  END IF;

  -- ⑦ 找得到**唯一一列**要改的請購單品項：po_item_id = 本品項、而且各團明細裡有這個團
  --    合併建單（rpc_merge_prs_to_po，20260422120004:386）會讓一列採購單品項對到好幾列請購單品項
  SELECT COUNT(*)
    INTO v_rows
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    JOIN public.purchase_request_item_campaigns pric
      ON pric.pr_item_id = pri.id
     AND pric.campaign_id = p_campaign_id
     AND pric.tenant_id = v_tenant
   WHERE pri.po_item_id = p_po_item_id
     AND pri.sku_id = v_poi.sku_id
     AND pr.tenant_id = v_tenant
     AND pr.status <> 'cancelled';

  IF v_rows = 0 THEN
    RETURN '這個商品在請購單上沒有這一團的各團明細（舊資料），不自動改';
  END IF;

  IF v_rows > 1 THEN
    RETURN '合併建單：這個商品同時對到 ' || v_rows::TEXT
      || ' 列有這一團的請購品項，對不出是哪張請購單，不自動改';
  END IF;

  -- ⑦-2 那一列請購品項的總數必須 = 各團明細加總。
  --      對不起來的話，第 3 步「改總數」會被 #982 守衛擋下（20260921001000:543-550），
  --      與其讓人按下去才看到一句技術錯誤，不如在這裡先講清楚。
  SELECT pri.qty_requested,
         (SELECT COALESCE(SUM(c.qty_requested), 0)
            FROM public.purchase_request_item_campaigns c
           WHERE c.pr_item_id = pri.id)
    INTO v_item_qty, v_attr_total
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    JOIN public.purchase_request_item_campaigns pric
      ON pric.pr_item_id = pri.id
     AND pric.campaign_id = p_campaign_id
     AND pric.tenant_id = v_tenant
   WHERE pri.po_item_id = p_po_item_id
     AND pri.sku_id = v_poi.sku_id
     AND pr.tenant_id = v_tenant
     AND pr.status <> 'cancelled';

  IF v_item_qty <> v_attr_total THEN
    RETURN '請購單上這一列的總數 ' || trim_scale(v_item_qty)::TEXT
      || ' 跟各團明細加總 ' || trim_scale(v_attr_total)::TEXT
      || ' 對不起來，不自動改，請人工確認';
  END IF;

  RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public._po_item_store_add_block_reason(BIGINT, BIGINT) FROM PUBLIC;

COMMENT ON FUNCTION public._po_item_store_add_block_reason(BIGINT, BIGINT) IS
  '採購單「分店／批發追加」的檢查（預覽與寫入共用）：回 NULL 代表可以追加，否則回中文原因。唯讀。';


-- ----------------------------------------------------------------------------
-- 2. 新增：替一家店在原團加一筆店家內部單（內部；只給 rpc_add_po_store_demands 呼叫）
--
--    ⚠️⚠️ 這段與 rpc_add_pr_store_demands（20260924010000:244-341，#995）是
--         **兩份同樣的邏輯**，改一份要兩份一起改（找既有單的條件、單號規則、狀態檢查）。
--         #995 那份本檔沒有動。
--    跟 #995 不一樣的只有：備註文字、錯誤訊息裡的「請購單草稿」字樣，
--    以及「追加紀錄那一列」改由呼叫端在算出 X 之後才寫（計畫 1-3 第 5 步）。
--
--    參數由呼叫端驗過（租戶、團、開團商品、分店都已檢查並上鎖），這裡不再重驗。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._store_add_internal_order_item(
  p_tenant           UUID,
  p_campaign_id      BIGINT,
  p_campaign_no      TEXT,
  p_campaign_item_id BIGINT,
  p_sku_id           BIGINT,
  p_unit_price       NUMERIC,
  p_store_id         BIGINT,
  p_qty              NUMERIC,
  p_operator         UUID,
  p_order_note       TEXT,
  p_item_note        TEXT,
  OUT o_order_id       BIGINT,
  OUT o_order_item_id  BIGINT,
  OUT o_order_created  BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
DECLARE
  v_member_id    BIGINT;
  v_channel_id   BIGINT;
  v_order_status TEXT;
  v_seq          INTEGER;
  v_order_no     TEXT;
BEGIN
  o_order_created := FALSE;

  v_member_id := public.rpc_get_or_create_store_member(p_store_id, p_operator);

  SELECT id
    INTO v_channel_id
    FROM public.line_channels
   WHERE tenant_id = p_tenant
     AND home_store_id = p_store_id
     AND is_active = TRUE
   ORDER BY id
   LIMIT 1;

  IF v_channel_id IS NULL THEN
    SELECT id
      INTO v_channel_id
      FROM public.line_channels
     WHERE tenant_id = p_tenant
       AND is_active = TRUE
     ORDER BY id
     LIMIT 1;
  END IF;

  IF v_channel_id IS NULL THEN
    RAISE EXCEPTION '此公司沒有可用的 LINE 頻道，不能建立店內單';
  END IF;

  -- 找既有的店家單：條件對齊唯一索引 customer_orders_trio_kind_active_uniq
  -- （最新定義 20260901010000:67：order_kind、排除 SP-／WS-、aid_board_id IS NULL）
  SELECT id, status
    INTO o_order_id, v_order_status
    FROM public.customer_orders
   WHERE tenant_id = p_tenant
     AND campaign_id = p_campaign_id
     AND channel_id = v_channel_id
     AND member_id = v_member_id
     AND order_kind = 'normal'
     AND status NOT IN ('transferred_out','expired','cancelled')
     AND aid_board_id IS NULL
     AND order_no NOT LIKE 'SP-%'
     AND order_no NOT LIKE 'WS-%'
   ORDER BY id
   LIMIT 1
   FOR UPDATE;

  IF o_order_id IS NULL THEN
    SELECT COUNT(*) + 1
      INTO v_seq
      FROM public.customer_orders
     WHERE tenant_id = p_tenant
       AND campaign_id = p_campaign_id;

    LOOP
      v_order_no := p_campaign_no || '-INT' || lpad(v_seq::TEXT, 4, '0');

      BEGIN
        INSERT INTO public.customer_orders (
          tenant_id, order_no, campaign_id, channel_id, member_id,
          pickup_store_id, status, confirmed_at, order_kind, notes,
          created_by, updated_by
        ) VALUES (
          p_tenant, v_order_no, p_campaign_id, v_channel_id, v_member_id,
          p_store_id, 'confirmed', NOW(), 'normal',
          p_order_note,
          p_operator, p_operator
        )
        RETURNING id INTO o_order_id;

        o_order_created := TRUE;
        EXIT;
      EXCEPTION WHEN unique_violation THEN
        v_seq := v_seq + 1;
      END;
    END LOOP;
  ELSE
    IF v_order_status NOT IN ('pending','confirmed') THEN
      RAISE EXCEPTION '此分店／批發在原團的店內單已進入後段狀態，不能再追加：order_id=%, status=%',
        o_order_id, v_order_status;
    END IF;
  END IF;

  INSERT INTO public.customer_order_items (
    tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
    status, source, notes, created_by, updated_by
  ) VALUES (
    p_tenant, o_order_id, p_campaign_item_id, p_sku_id, p_qty, p_unit_price,
    'pending', 'store_internal', p_item_note,
    p_operator, p_operator
  )
  RETURNING id INTO o_order_item_id;
END;
$$;

REVOKE ALL ON FUNCTION public._store_add_internal_order_item(
  UUID, BIGINT, TEXT, BIGINT, BIGINT, NUMERIC, BIGINT, NUMERIC, UUID, TEXT, TEXT
) FROM PUBLIC;

COMMENT ON FUNCTION public._store_add_internal_order_item(
  UUID, BIGINT, TEXT, BIGINT, BIGINT, NUMERIC, BIGINT, NUMERIC, UUID, TEXT, TEXT
) IS
  '內部：替一家分店／批發在原團加一筆店家內部單（找既有單或新建 confirmed 單）。與 rpc_add_pr_store_demands（20260924010000）是兩份同樣的邏輯，改一份要兩份一起改。';


-- ----------------------------------------------------------------------------
-- 3. 新增：採購單頁的唯讀預覽
--    一列 = 這張採購單的一個 (品項, 可選的團)。對不出任何團的品項也會回一列（團是 NULL），
--    原因寫在 block_reason。
--    demand_qty / already_qty / delta_qty ＝ 現在（追加之前）這個 (團, 商品) 的需求、
--    已請購、差額，直接取自 _pr_campaign_sku_remaining_rows；需求是 0 時那支不回 → NULL。
--    畫面用 max(delta_qty + N, 0) 預估採購單會加幾件；**實際以寫入當下算的為準**。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_preview_po_store_additions(
  p_po_id BIGINT
) RETURNS TABLE(
  po_item_id    BIGINT,
  sku_id        BIGINT,
  sku_label     TEXT,
  qty_ordered   NUMERIC,
  campaign_id   BIGINT,
  campaign_no   TEXT,
  campaign_name TEXT,
  can_add       BOOLEAN,
  block_reason  TEXT,
  demand_qty    NUMERIC,
  already_qty   NUMERIC,
  delta_qty     NUMERIC
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
#variable_conflict use_column
DECLARE
  v_tenant UUID;
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  RETURN QUERY
  WITH items AS (
    SELECT poi.id AS po_item_id, poi.sku_id, poi.qty_ordered
      FROM public.purchase_order_items poi
      JOIN public.purchase_orders po
        ON po.id = poi.po_id
     WHERE po.id = p_po_id
       AND po.tenant_id = v_tenant
  ),
  -- 跟派貨表 po_campaigns 同一條路徑（20260908000000:41-56）
  links AS (
    SELECT DISTINCT u.po_item_id, u.campaign_id
      FROM (
        SELECT it.po_item_id, prc.campaign_id
          FROM items it
          JOIN public.purchase_request_items pri
            ON pri.po_item_id = it.po_item_id
          JOIN public.purchase_request_campaigns prc
            ON prc.pr_id = pri.pr_id
        UNION
        SELECT it.po_item_id, pri.source_campaign_id
          FROM items it
          JOIN public.purchase_request_items pri
            ON pri.po_item_id = it.po_item_id
         WHERE pri.source_campaign_id IS NOT NULL
      ) u
  ),
  -- 只留「有賣這個商品」的團：結單日請購單常連著當天所有團，不濾的話每個商品都會列出一堆無關的團
  cands AS (
    SELECT l.po_item_id, l.campaign_id
      FROM links l
      JOIN items it
        ON it.po_item_id = l.po_item_id
      JOIN public.campaign_items ci
        ON ci.campaign_id = l.campaign_id
       AND ci.sku_id = it.sku_id
       AND ci.tenant_id = v_tenant
  ),
  -- 一次算完（吃陣列的 helper 不要包 per-row LATERAL）
  rem AS (
    SELECT r.campaign_id, r.sku_id, r.demand_qty, r.already_qty, r.delta_qty
      FROM public._pr_campaign_sku_remaining_rows(
             ARRAY(SELECT DISTINCT c.campaign_id FROM cands c ORDER BY c.campaign_id)
           ) r
  ),
  checked AS (
    SELECT
      it.po_item_id,
      it.sku_id,
      it.qty_ordered,
      c.campaign_id,
      public._po_item_store_add_block_reason(it.po_item_id, c.campaign_id) AS block_reason
    FROM items it
    LEFT JOIN cands c
      ON c.po_item_id = it.po_item_id
  )
  SELECT
    ck.po_item_id,
    ck.sku_id,
    COALESCE(
      NULLIF(TRIM(COALESCE(s.product_name, '')
        || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
      s.sku_code,
      '品項#' || ck.sku_id::TEXT
    ) AS sku_label,
    ck.qty_ordered,
    ck.campaign_id,
    gbc.campaign_no,
    gbc.name AS campaign_name,
    (ck.block_reason IS NULL) AS can_add,
    ck.block_reason,
    r.demand_qty,
    r.already_qty,
    r.delta_qty
  FROM checked ck
  LEFT JOIN public.group_buy_campaigns gbc
    ON gbc.id = ck.campaign_id
  LEFT JOIN rem r
    ON r.campaign_id = ck.campaign_id
   AND r.sku_id = ck.sku_id
  LEFT JOIN public.skus s
    ON s.id = ck.sku_id
  ORDER BY ck.po_item_id, gbc.campaign_no NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_preview_po_store_additions(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_preview_po_store_additions(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_preview_po_store_additions(BIGINT) IS
  '採購單頁「分店／批發追加」的唯讀預覽：每個 (品項, 可選的團) 能不能追加、不能的原因，以及目前的需求／已請購／差額。';


-- ----------------------------------------------------------------------------
-- 4. 新增：真正寫入
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_add_po_store_demands(
  p_po_id        BIGINT,
  p_po_item_id   BIGINT,
  p_campaign_id  BIGINT,
  p_additions    JSONB,
  p_operator     UUID,
  p_request_key  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- po_store_additions:20261002000000
DECLARE
  v_tenant            UUID;
  v_reason            TEXT;
  v_existing          RECORD;
  v_existing_po_item  BIGINT;
  v_po_qty_now        NUMERIC;
  v_po                RECORD;
  v_poi               RECORD;
  v_pr                RECORD;
  v_campaign          RECORD;
  v_ci                RECORD;
  v_res               RECORD;
  v_bad_count         INTEGER := 0;
  v_missing_store_ids TEXT;
  v_store_count       INTEGER := 0;
  v_store_added_qty   NUMERIC := 0;
  v_order_count       INTEGER := 0;
  v_delta             NUMERIC;
  v_demand            NUMERIC;
  v_already           NUMERIC;
  v_x                 NUMERIC := 0;
  v_pr_qty_after      NUMERIC;
  v_po_qty_after      NUMERIC;
  v_stores            JSONB;
  r                   RECORD;
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  v_tenant := public._current_tenant_id();
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  IF p_request_key IS NULL THEN
    RAISE EXCEPTION 'request key is required';
  END IF;

  -- ── 防重送（比照 #995）────────────────────────────────────────────────────
  -- 跟 #995 用**同一個前綴**的鎖：兩支共用 purchase_request_store_additions 與它的
  -- (tenant_id, request_key, store_id) 唯一索引，同一把 key 不管從哪一支進來都會排隊。
  PERFORM pg_advisory_xact_lock(hashtext('pr_store_add:' || p_request_key::TEXT));

  SELECT COUNT(*)                                     AS store_count,
         COUNT(DISTINCT a.pr_item_id)                 AS item_cnt,
         COUNT(DISTINCT a.campaign_id)                AS camp_cnt,
         MIN(a.pr_id)                                 AS pr_id,
         MIN(a.pr_item_id)                            AS pr_item_id,
         MIN(a.campaign_id)                           AS campaign_id,
         bool_and(a.created_by IS NOT DISTINCT FROM p_operator) AS same_operator,
         COALESCE(SUM(a.qty_added), 0)                AS store_added_qty,
         COALESCE(MAX(a.pr_delta_qty), 0)             AS pr_delta_qty,
         MAX(a.pr_qty_after)                          AS pr_qty_after,
         jsonb_agg(jsonb_build_object(
           'store_id', a.store_id,
           'qty', a.qty_added,
           'order_id', a.order_id,
           'order_item_id', a.order_item_id
         ) ORDER BY a.store_id)                       AS stores
    INTO v_existing
    FROM public.purchase_request_store_additions a
   WHERE a.tenant_id = v_tenant
     AND a.request_key = p_request_key;

  IF v_existing.store_count > 0 THEN
    SELECT pri.po_item_id
      INTO v_existing_po_item
      FROM public.purchase_request_items pri
     WHERE pri.id = v_existing.pr_item_id;

    SELECT poi.qty_ordered
      INTO v_po_qty_now
      FROM public.purchase_order_items poi
     WHERE poi.id = p_po_item_id
       AND poi.po_id = p_po_id;

    IF v_existing.item_cnt <> 1
       OR v_existing.camp_cnt <> 1
       OR NOT v_existing.same_operator
       OR v_existing.campaign_id <> p_campaign_id
       OR v_existing_po_item IS DISTINCT FROM p_po_item_id
       OR v_po_qty_now IS NULL THEN
      RAISE EXCEPTION 'request key already used by another store-addition request';
    END IF;

    -- 上次已經做完：照紀錄回傳，不重做。
    -- ⚠️ 採購單「改之前是多少」紀錄表沒有存（表不加欄位），所以 po_qty_before 回 NULL、
    --    po_qty_after 回**現值**（之後若有人再改過，就不是當時的數字）。
    RETURN jsonb_build_object(
      'po_id', p_po_id,
      'po_item_id', p_po_item_id,
      'campaign_id', p_campaign_id,
      'request_key', p_request_key,
      'pr_id', v_existing.pr_id,
      'pr_item_id', v_existing.pr_item_id,
      'stores', v_existing.stores,
      'store_count', v_existing.store_count,
      'store_added_qty', v_existing.store_added_qty,
      'po_added_qty', v_existing.pr_delta_qty,
      'po_qty_before', NULL,
      'po_qty_after', v_po_qty_now,
      'pr_qty_after', v_existing.pr_qty_after,
      'idempotent', TRUE
    );
  END IF;

  -- ── 先檢查一次（還沒上鎖；不行就早點停，不必去搶鎖）──────────────────────
  v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION '%', v_reason;
  END IF;

  -- ── 輸入（照抄 #995 的解析與分店檢查）─────────────────────────────────────
  IF p_additions IS NULL OR jsonb_typeof(p_additions) <> 'array' OR jsonb_array_length(p_additions) = 0 THEN
    RAISE EXCEPTION '請至少選一間分店或批發與數量';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_raw;
  CREATE TEMP TABLE _po_store_add_raw ON COMMIT DROP AS
  SELECT
    x.store_id::BIGINT AS store_id,
    x.qty::NUMERIC AS qty
  FROM jsonb_to_recordset(p_additions) AS x(store_id BIGINT, qty NUMERIC);

  SELECT COUNT(*)
    INTO v_bad_count
    FROM pg_temp._po_store_add_raw
   WHERE store_id IS NULL
      OR qty IS NULL
      OR qty <= 0;

  IF v_bad_count > 0 THEN
    RAISE EXCEPTION '分店／批發追加數量必須大於 0';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_input;
  CREATE TEMP TABLE _po_store_add_input ON COMMIT DROP AS
  SELECT store_id, SUM(qty)::NUMERIC(18,3) AS qty
    FROM pg_temp._po_store_add_raw
   GROUP BY store_id;

  SELECT COUNT(*), COALESCE(SUM(qty), 0)
    INTO v_store_count, v_store_added_qty
    FROM pg_temp._po_store_add_input;

  SELECT string_agg(i.store_id::TEXT, ',')
    INTO v_missing_store_ids
    FROM pg_temp._po_store_add_input i
    LEFT JOIN public.stores s
      ON s.id = i.store_id
     AND s.tenant_id = v_tenant
     AND s.is_active = TRUE
     AND s.deleted_at IS NULL
     AND COALESCE(s.store_kind, 'branch') IN ('branch', 'wholesale')
   WHERE s.id IS NULL;

  IF v_missing_store_ids IS NOT NULL THEN
    RAISE EXCEPTION '有分店／批發不存在、停用或已刪除：%', v_missing_store_ids;
  END IF;

  -- ── 上鎖（順序固定：採購單 → 採購單品項 → 請購單與品項 → 團 → (團, 商品)）──
  SELECT po.id, po.po_no, po.status
    INTO v_po
    FROM public.purchase_orders po
   WHERE po.id = p_po_id
     AND po.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張採購單';
  END IF;

  SELECT poi.id, poi.sku_id, poi.qty_ordered
    INTO v_poi
    FROM public.purchase_order_items poi
   WHERE poi.id = p_po_item_id
     AND poi.po_id = p_po_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '這個商品不在這張採購單上';
  END IF;

  PERFORM 1
     FROM public.purchase_request_items pri
     JOIN public.purchase_requests pr
       ON pr.id = pri.pr_id
    WHERE pri.po_item_id = p_po_item_id
      AND pri.sku_id = v_poi.sku_id
      AND pr.tenant_id = v_tenant
    ORDER BY pri.id
    FOR UPDATE OF pr, pri;

  SELECT gbc.id, gbc.campaign_no, gbc.name, gbc.status
    INTO v_campaign
    FROM public.group_buy_campaigns gbc
   WHERE gbc.id = p_campaign_id
     AND gbc.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這個團 %', p_campaign_id;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::TEXT), hashtext(v_poi.sku_id::TEXT));

  -- >>> RECHECK BEGIN（鎖完再跑一次同一套檢查 —— 不可拿掉）
  -- 第一次檢查到上鎖之間，可能有人開了進貨單、撿貨單、按了斷貨或改了團的狀態。
  -- 那些動作都會碰到我們剛鎖的列（UPDATE 或外鍵），所以這時候再查一次一定看得到。
  v_reason := public._po_item_store_add_block_reason(p_po_item_id, p_campaign_id);
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION '%', v_reason;
  END IF;
  -- <<< RECHECK END

  -- 要改的那一列請購品項（檢查已保證：剛好一列、總數 = 各團明細加總）
  SELECT pr.id AS pr_id, pr.pr_no, pri.id AS pr_item_id, pri.qty_requested
    INTO v_pr
    FROM public.purchase_request_items pri
    JOIN public.purchase_requests pr
      ON pr.id = pri.pr_id
    JOIN public.purchase_request_item_campaigns pric
      ON pric.pr_item_id = pri.id
     AND pric.campaign_id = p_campaign_id
     AND pric.tenant_id = v_tenant
   WHERE pri.po_item_id = p_po_item_id
     AND pri.sku_id = v_poi.sku_id
     AND pr.tenant_id = v_tenant
     AND pr.status <> 'cancelled';

  IF NOT FOUND THEN
    RAISE EXCEPTION '內部錯誤：找不到要改的請購品項（po_item_id=%）', p_po_item_id;
  END IF;

  SELECT ci.id, ci.unit_price
    INTO v_ci
    FROM public.campaign_items ci
   WHERE ci.tenant_id = v_tenant
     AND ci.campaign_id = p_campaign_id
     AND ci.sku_id = v_poi.sku_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '此品項不屬於指定原團';
  END IF;

  DROP TABLE IF EXISTS pg_temp._po_store_add_done;
  CREATE TEMP TABLE _po_store_add_done (
    store_id      BIGINT,
    qty           NUMERIC,
    order_id      BIGINT,
    order_item_id BIGINT,
    order_created BOOLEAN
  ) ON COMMIT DROP;

  -- >>> STEP1 BEGIN（第 1 步：每家店建店家內部單 +N）
  FOR r IN SELECT store_id, qty FROM pg_temp._po_store_add_input ORDER BY store_id
  LOOP
    SELECT o.o_order_id, o.o_order_item_id, o.o_order_created
      INTO v_res
      FROM public._store_add_internal_order_item(
             v_tenant, p_campaign_id, v_campaign.campaign_no, v_ci.id, v_poi.sku_id,
             v_ci.unit_price, r.store_id, r.qty, p_operator,
             format('【採購單分店／批發追加】%s', v_po.po_no),
             format('採購單 %s 分店／批發追加', v_po.po_no)
           ) o;

    INSERT INTO pg_temp._po_store_add_done (store_id, qty, order_id, order_item_id, order_created)
    VALUES (r.store_id, r.qty, v_res.o_order_id, v_res.o_order_item_id, v_res.o_order_created);

    IF v_res.o_order_created THEN
      v_order_count := v_order_count + 1;
    END IF;
  END LOOP;
  -- <<< STEP1 END

  -- 第 2 步：差額（加完店家單之後）。X = max(差額, 0)
  SELECT d.delta_qty, d.demand_qty, d.already_qty
    INTO v_delta, v_demand, v_already
    FROM public._pr_campaign_sku_remaining_rows(ARRAY[p_campaign_id]) d
   WHERE d.campaign_id = p_campaign_id
     AND d.sku_id = v_poi.sku_id;

  v_x := GREATEST(COALESCE(v_delta, 0), 0);

  -- >>> STEP3 BEGIN（第 3 步：請購單 +X，先各團明細、後總數 —— 順序反了 #982 守衛會擋）
  IF v_x > 0 THEN
    UPDATE public.purchase_request_item_campaigns
       SET qty_requested = qty_requested + v_x
     WHERE pr_item_id = v_pr.pr_item_id
       AND campaign_id = p_campaign_id
       AND tenant_id = v_tenant;

    IF NOT FOUND THEN
      RAISE EXCEPTION '內部錯誤：請購品項的這一團明細在途中消失了（pr_item_id=%）', v_pr.pr_item_id;
    END IF;

    UPDATE public.purchase_request_items
       SET qty_requested = qty_requested + v_x,
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = v_pr.pr_item_id;

    -- 請購單總金額：跟 #995（20260924010000:372-380）同一個算法；line_subtotal 是 generated column
    UPDATE public.purchase_requests pr
       SET total_amount = COALESCE((
             SELECT SUM(pri.line_subtotal)
               FROM public.purchase_request_items pri
              WHERE pri.pr_id = v_pr.pr_id
           ), 0),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE pr.id = v_pr.pr_id;
  END IF;
  -- <<< STEP3 END

  SELECT pri.qty_requested
    INTO v_pr_qty_after
    FROM public.purchase_request_items pri
   WHERE pri.id = v_pr.pr_item_id;

  -- 第 4 步：採購單 +X，再重算表頭（算法見檔頭：subtotal = SUM(qty_ordered * unit_cost)、
  --          total = subtotal、tax 不動 —— 跟 rpc_split_pr_to_pos 20260428120000:396-405 相同）
  IF v_x > 0 THEN
    UPDATE public.purchase_order_items
       SET qty_ordered = qty_ordered + v_x,
           updated_by = p_operator,
           updated_at = NOW()
     WHERE id = p_po_item_id;

    UPDATE public.purchase_orders po
       SET subtotal   = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                    FROM public.purchase_order_items WHERE po_id = po.id), 0),
           total      = COALESCE((SELECT SUM(qty_ordered * unit_cost)
                                    FROM public.purchase_order_items WHERE po_id = po.id), 0),
           updated_by = p_operator,
           updated_at = NOW()
     WHERE po.id = p_po_id;
  END IF;

  SELECT poi.qty_ordered
    INTO v_po_qty_after
    FROM public.purchase_order_items poi
   WHERE poi.id = p_po_item_id;

  -- 第 5 步：每家店一列追加紀錄（表不加欄位；採購單從 pr_item_id → po_item_id 查得到）
  INSERT INTO public.purchase_request_store_additions (
    tenant_id, pr_id, pr_item_id, campaign_id, store_id,
    order_id, order_item_id, sku_id, qty_added, request_key, created_by,
    pr_delta_qty, pr_qty_after
  )
  SELECT v_tenant, v_pr.pr_id, v_pr.pr_item_id, p_campaign_id, d.store_id,
         d.order_id, d.order_item_id, v_poi.sku_id, d.qty, p_request_key, p_operator,
         v_x, v_pr_qty_after
    FROM pg_temp._po_store_add_done d
   ORDER BY d.store_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'store_id', d.store_id,
           'qty', d.qty,
           'order_id', d.order_id,
           'order_item_id', d.order_item_id,
           'order_created', d.order_created
         ) ORDER BY d.store_id), '[]'::JSONB)
    INTO v_stores
    FROM pg_temp._po_store_add_done d;

  RETURN jsonb_build_object(
    'po_id', p_po_id,
    'po_no', v_po.po_no,
    'po_item_id', p_po_item_id,
    'campaign_id', p_campaign_id,
    'campaign_no', v_campaign.campaign_no,
    'request_key', p_request_key,
    'pr_id', v_pr.pr_id,
    'pr_no', v_pr.pr_no,
    'pr_item_id', v_pr.pr_item_id,
    'stores', v_stores,
    'store_count', v_store_count,
    'store_added_qty', v_store_added_qty,
    'po_added_qty', v_x,
    'po_qty_before', v_poi.qty_ordered,
    'po_qty_after', v_po_qty_after,
    'pr_qty_before', v_pr.qty_requested,
    'pr_qty_after', v_pr_qty_after,
    'demand_qty', v_demand,
    'already_qty_before_sync', v_already,
    'delta_qty', v_delta,
    'created_order_count', v_order_count,
    'idempotent', FALSE
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) IS
  '採購單頁「分店／批發追加」：替分店／批發在原團加店家內部單（+N），再用 _pr_campaign_sku_remaining_rows 算出 X = max(差額, 0)，請購單（先各團明細後總數）與採購單各 +X。不重開團、不通知廠商。同一 request_key 重送回上次結果。';


-- ----------------------------------------------------------------------------
-- 5. 權限：兩支內部函式誰都不給；兩支 rpc_* 只給 authenticated
--    （Supabase 預設會把新函式的 EXECUTE 給 anon／authenticated，所以要明確收回）
-- ----------------------------------------------------------------------------
DO $revoke_roles$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public._po_item_store_add_block_reason(BIGINT, BIGINT) FROM anon;
    REVOKE ALL ON FUNCTION public._store_add_internal_order_item(
      UUID, BIGINT, TEXT, BIGINT, BIGINT, NUMERIC, BIGINT, NUMERIC, UUID, TEXT, TEXT
    ) FROM anon;
    REVOKE ALL ON FUNCTION public.rpc_preview_po_store_additions(BIGINT) FROM anon;
    REVOKE ALL ON FUNCTION public.rpc_add_po_store_demands(BIGINT, BIGINT, BIGINT, JSONB, UUID, UUID) FROM anon;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON FUNCTION public._po_item_store_add_block_reason(BIGINT, BIGINT) FROM authenticated;
    REVOKE ALL ON FUNCTION public._store_add_internal_order_item(
      UUID, BIGINT, TEXT, BIGINT, BIGINT, NUMERIC, BIGINT, NUMERIC, UUID, TEXT, TEXT
    ) FROM authenticated;
  END IF;
END
$revoke_roles$;

NOTIFY pgrst, 'reload schema';
