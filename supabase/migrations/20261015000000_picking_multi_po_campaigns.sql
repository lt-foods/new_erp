-- ============================================================================
-- 2026-10-15: 撿貨用檢查表 —— 同一團、同一樣商品掛了兩張以上採購單
--
-- 症狀：同一團、同一樣商品掛了兩張採購單（例：原單已轉採購後，按「結單日補單」
--   另開了一張差額單），需求表 v_picking_demand_by_po 會讓每一張採購單各帶一次
--   整團的訂單量（20260908000000:62-72）。撿貨草稿（computePrefill）與派貨工作台
--   （storeDemand）再把各店需求跨採購單加總 ⇒ 各店需求變兩倍 ⇒ 依店的編號先來後到
--   分可分配量，排前面的店拿兩倍、後面的店拿 0。
--   實例：2026-10-13 G02671-01／GRP-20260914-056，兩張採購單 19＋1 件，草稿當成 40 件。
--
-- 本檔只新增一支只讀 view（public.v_picking_multi_po_campaigns），前端拿它判斷：
--   撿貨草稿：中招的商品各店數量全部留 0，紅字列出團號、採購單號，請人照訂單樞紐填；
--   派貨工作台：中招的商品加紅字（數字、建單一律不動）。
--
-- 一列 = 一樣商品 × 一個團，同時滿足：
--   1. 這一團有有效訂單含這樣商品（排除條件與需求表 campaign_demand 相同）；
--   2. 這一團連到這樣商品的有效採購單品項有 2 個以上
--      （連法＝需求表 po_campaigns；狀態＝需求表 po_skus 的 sent／partially_received／fully_received）。
--   ⚠ 看「全部」有效採購單，不看還有沒有貨：第一張派完、第二張才到的時候，
--     第二張的需求一樣是整團（已派量只算自己那張單派出去的），照樣會算錯。
--     早就派完的舊團由前端排掉：至少一個採購單品項還在需求表上才算中招。
--
-- 逐字對照 20260908000000（三段的 FROM／JOIN／WHERE 一個字都沒改）：
--   po_skus         ＝ :19-34 整段照抄（含這裡用不到的欄位；用不到的算式 planner 會省掉）
--   po_campaigns    ＝ :42-56 整段照抄
--   campaign_demand ＝ :62、:66-71 照抄；
--                     只改 SELECT（:63-65）與 GROUP BY（:72）：原本是「採購單品項 × 分店」，
--                     這裡要知道「哪一團、哪一樣商品」，不需要分店。
--   正式庫上的需求表停在 20260818000030（9/08 那版沒套上）；這三段在 0818、0908 兩版
--   逐字相同（兩版只差撿貨量那三行），所以不管正式庫是哪一版，連法都一致。
--
-- 安全性：
--   - 只新增這一支 view；不動任何既有 view、函式、資料表、資料。
--   - 權限比照需求表（20260614000010:204）只給 authenticated 讀；
--     先把 PUBLIC、anon、authenticated 的權限全部收回（含 Supabase 預設發的），
--     再只給 authenticated 讀（同 20260907010000:884 的寫法）。
--   - view 以擁有者身分讀表，與 v_picking_demand_by_po 相同。
--   - 整份可以重貼：前置檢查認得本檔建的版本（view 說明裡的記號）。
--
-- 已知限制（2026-10-15 審查後 CEO 裁定這次不做）：
--   只看「團的訂單」那一段（campaign_demand），不看補貨申請那一段（需求表的 restock_demand）。
--   補貨申請的需求如果同一樣商品被拆到兩個採購單品項，需求表一樣會各算一次，這支檢查表擋不到。
--   要發生得同一張補貨請購單裡同一樣商品有兩列、又被拆到兩個採購單品項
--   （restock_request_lines 本身有 UNIQUE (request_id, sku_id)，20260515000001:98），屬罕見。
--
-- 上線順序：先貼本檔、跑確認查詢全 ✅，再合併前端。
--   反過來的話，前端讀不到這支 view ⇒ 每一樣「有需求」的商品都走「檢查失敗、各店全部 0」，
--   草稿還能用，但每樣都要手填。（沒有需求的商品本來就帶不出數字，不標檢查失敗。）
--
-- 還原：scripts/PROD-picking-multi-po-2026-10/rollback_20261015000000.sql（只拿掉這一支 view）。
-- 確認：scripts/PROD-picking-multi-po-2026-10/postcheck_readonly.sql
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、只讀。任何一項不符就整份停下，一行都不會執行。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
  v_name    TEXT;
  v_oid     REGCLASS;
  v_kind    "char";
  v_comment TEXT;
BEGIN
  -- 本檔 view 讀到的每一個欄位（含 po_skus 照抄進來、這裡用不到的那幾個）
  FOREACH v_name IN ARRAY ARRAY[
    'purchase_orders.id',
    'purchase_orders.tenant_id',
    'purchase_orders.po_no',
    'purchase_orders.status',
    'purchase_orders.supplier_id',
    'purchase_order_items.id',
    'purchase_order_items.po_id',
    'purchase_order_items.sku_id',
    'purchase_order_items.qty_ordered',
    'purchase_request_items.po_item_id',
    'purchase_request_items.pr_id',
    'purchase_request_items.source_campaign_id',
    'purchase_requests.id',
    'purchase_request_campaigns.pr_id',
    'purchase_request_campaigns.campaign_id',
    'restock_requests.linked_pr_id',
    'customer_orders.id',
    'customer_orders.campaign_id',
    'customer_orders.status',
    'customer_orders.pickup_store_id',
    'customer_orders.transferred_from_order_id',
    'customer_order_items.order_id',
    'customer_order_items.status',
    'customer_order_items.sku_id',
    'customer_order_items.qty',
    'group_buy_campaigns.id',
    'group_buy_campaigns.campaign_no'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(v_name, '.', 1))
         AND a.attname = split_part(v_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      v_missing := v_missing || ('public.' || v_name);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少欄位：\n%',
      array_to_string(v_missing, E'\n');
  END IF;

  -- 同名的東西：沒有＝第一次貼；有＝必須是本檔建的 view（重貼），否則停下。
  -- ⓘ 用指定（:=）而不是 SELECT … 進變數的寫法：Supabase 視窗會把那個字誤判成建表。
  v_oid := to_regclass('public.v_picking_multi_po_campaigns');
  IF v_oid IS NOT NULL THEN
    v_kind := (SELECT c.relkind FROM pg_class c WHERE c.oid = v_oid);
    v_comment := obj_description(v_oid, 'pg_class');
    IF v_kind <> 'v'
       OR position('picking_multi_po_campaigns:20261015000000' IN coalesce(v_comment, '')) = 0 THEN
      RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。public.v_picking_multi_po_campaigns 已經存在，但不是本檔的版本（說明裡沒有本檔的記號），請先找工程師確認是誰的';
    END IF;
  END IF;
END
$precheck$;

-- ----------------------------------------------------------------------------
-- 1. 檢查表本體
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_picking_multi_po_campaigns AS
WITH po_skus AS (
         SELECT po.id AS po_id,
            po.tenant_id,
            po.po_no,
            po.status AS po_status,
            po.supplier_id,
            poi.id AS po_item_id,
            poi.sku_id,
            poi.qty_ordered,
            (EXISTS ( SELECT 1
                   FROM purchase_request_items pri2
                     JOIN restock_requests rr ON rr.linked_pr_id = pri2.pr_id
                  WHERE pri2.po_item_id = poi.id)) AS is_restock_sourced
           FROM purchase_orders po
             JOIN purchase_order_items poi ON poi.po_id = po.id
          WHERE po.status = ANY (ARRAY['sent'::text, 'partially_received'::text, 'fully_received'::text])
        ), po_campaigns AS (
         SELECT DISTINCT u.po_item_id,
            u.campaign_id
           FROM ( SELECT poi.id AS po_item_id,
                    prc.campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                     JOIN purchase_requests pr ON pr.id = pri.pr_id
                     JOIN purchase_request_campaigns prc ON prc.pr_id = pr.id
                UNION
                 SELECT poi.id AS po_item_id,
                    pri.source_campaign_id AS campaign_id
                   FROM purchase_order_items poi
                     JOIN purchase_request_items pri ON pri.po_item_id = poi.id
                  WHERE pri.source_campaign_id IS NOT NULL) u
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            pc.campaign_id,
            poi.sku_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, pc.campaign_id, poi.sku_id
        )
 SELECT ps.tenant_id,
    cd.sku_id,
    cd.campaign_id,
    gc.campaign_no,
    array_agg(ps.po_item_id ORDER BY ps.po_item_id) AS po_item_ids,
    array_agg(DISTINCT ps.po_no ORDER BY ps.po_no) AS po_nos
   FROM campaign_demand cd
     JOIN po_skus ps ON ps.po_item_id = cd.po_item_id AND ps.sku_id = cd.sku_id
     LEFT JOIN group_buy_campaigns gc ON gc.id = cd.campaign_id
  GROUP BY ps.tenant_id, cd.sku_id, cd.campaign_id, gc.campaign_no
 HAVING count(DISTINCT ps.po_item_id) >= 2;
-- ⓘ 最外層刻意用 cd.sku_id（campaign_demand 的分組欄）：前端用 sku_id = X 或
--   sku_id IN (…) 篩的時候，條件才推得進 campaign_demand（本機 EXPLAIN 看得到），
--   不必先把每一樣商品的需求都分組算完再丟掉。ps.sku_id = cd.sku_id 是同一件事
--   （採購單品項本來就決定了商品），多寫一次是讓 sku_id = X 也能同時縮小 po_skus。
-- ⓘ po_item_ids 是「採購單品項」不是「採購單」：同一張採購單裡同一樣商品出現兩列，
--   需求一樣會被算兩次，所以用品項數判斷；po_nos 只是給人看的單號（去重、排序）。

COMMENT ON VIEW public.v_picking_multi_po_campaigns IS
  '撿貨用檢查表（picking_multi_po_campaigns:20261015000000）：一列＝一樣商品×一個團；這一團有有效訂單含這樣商品，而且連到這樣商品的有效採購單品項有 2 個以上（連法與 v_picking_demand_by_po 的 po_skus／po_campaigns／campaign_demand 相同）。撿貨草稿與派貨工作台拿它判斷各店需求會不會被重複算。只讀。';

-- ----------------------------------------------------------------------------
-- 2. 權限：只給登入後台的人讀（比照 v_picking_demand_by_po，20260614000010:204）
-- ----------------------------------------------------------------------------
REVOKE ALL ON public.v_picking_multi_po_campaigns FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_picking_multi_po_campaigns TO authenticated;
