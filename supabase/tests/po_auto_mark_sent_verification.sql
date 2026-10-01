-- ============================================================================
-- 驗證腳本：拿掉採購單「發送供應商」那一步
-- 對應 migration：supabase/migrations/20261002010000_po_auto_mark_sent.sql
-- 規格：公司\01_進行中\需求暨計畫_NEW-ERP拿掉採購單發送供應商_2026-10-01.md（第八節）
-- ----------------------------------------------------------------------------
-- ⛔ 只在**本機臨時庫**執行。整份包在交易裡，跑完 ROLLBACK 不留測資。
--    （不要在測試庫／正式庫跑：夾具會建團、訂單、請購單、採購單，測 3／4／12 還會在交易裡
--      暫時把 rpc_send_purchase_order 換成會丟錯的版本。）
--
-- ⚠️ 執行身分：需要超級使用者（測 3／4／12 在交易裡換函式；測 15～17 會 SET ROLE anon／authenticated）。
--
-- 測試清單（括號是 CEO 派工單的編號）
--    0. 夾具前提：新舊函式都在
--    1. （①）核准的請購單、兩家廠商 → 新程式 → 2 張採購單都是已發送、管道 manual、
--       sent_at／sent_by 有值；品項、金額、請購單狀態照舊
--    2. （①）對照原本的拆單：同一張請購單，兩邊結果逐欄比，差別只有 status／sent_at／sent_by／sent_channel
--    3. （②）rpc_send_purchase_order 換成「第 2 次呼叫丟錯」→ 新程式整筆失敗、白話訊息
--    4. （②）換成「第 1 次就丟錯」→ 同上
--    5. （③）請購單待審核 → 照舊擋（原本的訊息原封不動）、一張採購單都沒建
--    6. （③）請購單已退回 → 同上
--    7. （③）重複按（請購單已拆過）→ 照舊擋，第一次建的採購單不動
--    8. （④）斷貨單 → 新的回復 → 單子已發送、客人訂單照舊還原；
--       跟「只呼叫原本 restore」逐欄比對全部相關表，差別只有採購單的 status／sent_at／sent_by／sent_channel；
--       回傳 JSON 只差 po_status
--    9. （⑤）斷貨單有到貨量 → 照舊擋、什麼都沒變
--   10. （⑤）斷貨單有未取消的進貨單 → 照舊擋、什麼都沒變
--   11. （⑥）來源請購單被改成「已退回」（用真的 rpc_send_purchase_order 擋）→ 原本 restore 自己會成功，
--       新程式整筆不做：還是斷貨單、客人訂單沒還原、沒發通知；訊息白話
--   12. （⑥）rpc_send_purchase_order 換成會丟錯的版本 → 回復整筆不做
--   13. （⑦）舊的草稿單（用原本的拆單建）→ 原本的 rpc_send_purchase_order 照樣能送（line、manual）
--   14. （⑦）舊的「已回復成草稿」單（用原本的 restore）→ 原本的 rpc_send_purchase_order 照樣能送
--   15. （⑧）權限：anon 不能執行兩支新函式（has_function_privilege＋實際呼叫拿到 42501）、
--       PUBLIC 沒有執行權、authenticated 有
--   16. （⑧）用 authenticated 身分實際跑「建立採購單」新程式 → 成功、已發送（SECURITY INVOKER 走得通）
--   17. （⑧）用 authenticated 身分實際跑「回復斷貨」新程式 → 成功、已發送
--   18. 函式屬性：SECURITY INVOKER、search_path=public、本檔記號、參數與回傳型別
--   ⇒（⑨）對照組由本機測試工具負責：拿掉「標已發送」那段 → 測 1（回復那支是測 8）必須紅。
--
-- 斷貨的狀態是夾具直接寫出來的（照 _stockout_po_items／_split_stockout_po_items 會寫的欄位），
-- 不是跑真的斷貨函式。
-- 測試資料一律用「店A／店B」「廠商A／廠商B」「會員A／會員B」這種一般名稱，不用真實門市。
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT
  'feed0000-0000-4000-8000-000000000041'::UUID AS tenant,
  'feed0000-0000-4000-8000-0000000000fe'::UUID AS operator;

CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;


-- ----------------------------------------------------------------------------
-- 共用小工具
-- ----------------------------------------------------------------------------
CREATE FUNCTION pg_temp._t_id(p_k TEXT) RETURNS BIGINT
LANGUAGE plpgsql AS $f$
DECLARE v BIGINT;
BEGIN
  SELECT c.v INTO v FROM _t_ctx c WHERE c.k = p_k;
  IF v IS NULL THEN
    RAISE EXCEPTION '夾具找不到 %', p_k;
  END IF;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp._t_put(p_k TEXT, p_v BIGINT) RETURNS BIGINT
LANGUAGE sql AS $f$
  INSERT INTO _t_ctx(k, v) VALUES (p_k, p_v) RETURNING v
$f$;

CREATE FUNCTION pg_temp._t_op() RETURNS UUID
LANGUAGE sql AS $f$ SELECT operator FROM _t_env $f$;

-- 整個庫的快照（本機臨時庫只有夾具資料）：{表: {列鍵: 整列}}
-- notifications 的 id 是序號、回滾也不會退回 → 用內容當鍵
CREATE FUNCTION pg_temp._t_snapshot() RETURNS JSONB
LANGUAGE sql AS $f$
  SELECT jsonb_build_object(
    'purchase_orders',        (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.purchase_orders t),
    'purchase_order_items',   (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.purchase_order_items t),
    'purchase_requests',      (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.purchase_requests t),
    'purchase_request_items', (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.purchase_request_items t),
    'purchase_request_campaigns',
                              (SELECT COALESCE(jsonb_object_agg(t.pr_id || '-' || t.campaign_id, to_jsonb(t)), '{}')
                                 FROM public.purchase_request_campaigns t),
    'campaign_items',         (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.campaign_items t),
    'customer_orders',        (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.customer_orders t),
    'customer_order_items',   (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.customer_order_items t),
    'restock_requests',       (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.restock_requests t),
    'restock_request_lines',  (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.restock_request_lines t),
    'goods_receipts',         (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.goods_receipts t),
    'picking_waves',          (SELECT COALESCE(jsonb_object_agg(t.id::TEXT, to_jsonb(t)), '{}') FROM public.picking_waves t),
    'notifications',          (SELECT COALESCE(jsonb_object_agg(s.k, s.j), '{}')
                                 FROM (SELECT md5((to_jsonb(t) - 'id')::TEXT) || '#'
                                              || row_number() OVER (PARTITION BY md5((to_jsonb(t) - 'id')::TEXT) ORDER BY t.id) AS k,
                                              to_jsonb(t) - 'id' AS j
                                         FROM public.notifications t) s)
  )
$f$;

-- 兩份快照逐欄比：回傳每一個不一樣的 (表, 列, 欄)
CREATE FUNCTION pg_temp._t_diff(a JSONB, b JSONB)
RETURNS TABLE(tbl TEXT, rk TEXT, col TEXT, va JSONB, vb JSONB)
LANGUAGE sql AS $f$
  WITH tbls AS (
    SELECT x FROM jsonb_object_keys(a) x
    UNION
    SELECT x FROM jsonb_object_keys(b) x
  ), rws AS (
    SELECT t.x AS tbl, r.x AS rk
      FROM tbls t
      CROSS JOIN LATERAL (
        SELECT x FROM jsonb_object_keys(COALESCE(a -> t.x, '{}'::JSONB)) x
        UNION
        SELECT x FROM jsonb_object_keys(COALESCE(b -> t.x, '{}'::JSONB)) x
      ) r
  ), cls AS (
    SELECT w.tbl, w.rk, c.x AS col
      FROM rws w
      CROSS JOIN LATERAL (
        SELECT x FROM jsonb_object_keys(COALESCE(a -> w.tbl -> w.rk, '{}'::JSONB)) x
        UNION
        SELECT x FROM jsonb_object_keys(COALESCE(b -> w.tbl -> w.rk, '{}'::JSONB)) x
      ) c
  )
  SELECT c.tbl, c.rk, c.col, a -> c.tbl -> c.rk -> c.col, b -> c.tbl -> c.rk -> c.col
    FROM cls c
   WHERE (a -> c.tbl -> c.rk -> c.col) IS DISTINCT FROM (b -> c.tbl -> c.rk -> c.col)
$f$;

CREATE FUNCTION pg_temp._t_diff_txt(a JSONB, b JSONB) RETURNS TEXT
LANGUAGE sql AS $f$
  SELECT string_agg(d.tbl || '#' || d.rk || '.' || d.col || ': '
                    || COALESCE(d.va::TEXT, '∅') || ' → ' || COALESCE(d.vb::TEXT, '∅'),
                    '； ' ORDER BY d.tbl, d.rk, d.col)
    FROM pg_temp._t_diff(a, b) d
$f$;

-- 一張請購單拆出來的採購單，去掉 id／單號（序號回滾不會退回）後依廠商排好，可以拿去逐欄比
CREATE FUNCTION pg_temp._t_po_norm(p_pr BIGINT) RETURNS JSONB
LANGUAGE sql AS $f$
  SELECT jsonb_build_object(
    'pr', jsonb_build_object('pr', (SELECT to_jsonb(pr) FROM public.purchase_requests pr WHERE pr.id = p_pr)),
    'po', COALESCE((
      SELECT jsonb_object_agg(po.supplier_id::TEXT,
               (to_jsonb(po) - 'id' - 'po_no')
               || jsonb_build_object('items',
                    (SELECT jsonb_agg(to_jsonb(poi) - 'id' - 'po_id' ORDER BY poi.sku_id)
                       FROM public.purchase_order_items poi WHERE poi.po_id = po.id)))
        FROM public.purchase_orders po
       WHERE po.id IN (SELECT poi.po_id
                         FROM public.purchase_order_items poi
                         JOIN public.purchase_request_items pri ON pri.po_item_id = poi.id
                        WHERE pri.pr_id = p_pr)), '{}'),
    'pri', COALESCE((
      SELECT jsonb_object_agg(pri.sku_id::TEXT,
               (to_jsonb(pri) - 'po_item_id')
               || jsonb_build_object(
                    'linked_po_supplier', (SELECT po.supplier_id
                                             FROM public.purchase_order_items poi
                                             JOIN public.purchase_orders po ON po.id = poi.po_id
                                            WHERE poi.id = pri.po_item_id),
                    'linked_sku_match',   (SELECT poi.sku_id = pri.sku_id
                                             FROM public.purchase_order_items poi
                                            WHERE poi.id = pri.po_item_id)))
        FROM public.purchase_request_items pri
       WHERE pri.pr_id = p_pr), '{}')
  )
$f$;

-- 這張請購單目前連到幾張採購單
CREATE FUNCTION pg_temp._t_pos_of(p_pr BIGINT) RETURNS BIGINT[]
LANGUAGE sql AS $f$
  SELECT COALESCE(array_agg(DISTINCT poi.po_id ORDER BY poi.po_id), ARRAY[]::BIGINT[])
    FROM public.purchase_order_items poi
    JOIN public.purchase_request_items pri ON pri.po_item_id = poi.id
   WHERE pri.pr_id = p_pr
$f$;

-- 在「目前這個交易」裡把 rpc_send_purchase_order 換成會丟錯的版本（第 p_fail_at 次呼叫起丟錯；
-- 在那之前照常把單子標成已發送）。⚠️ 一定要在會被回滾的區塊裡呼叫。
CREATE FUNCTION pg_temp._t_install_failing_send(p_fail_at INT) RETURNS VOID
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('t.send_calls', '0', TRUE);
  EXECUTE format($ddl$
    CREATE OR REPLACE FUNCTION public.rpc_send_purchase_order(
      p_po_id    BIGINT,
      p_channel  TEXT,
      p_operator UUID
    ) RETURNS VOID
    LANGUAGE plpgsql SECURITY DEFINER
    AS $body$
    DECLARE n INT := COALESCE(NULLIF(current_setting('t.send_calls', TRUE), ''), '0')::INT + 1;
    BEGIN
      PERFORM set_config('t.send_calls', n::TEXT, TRUE);
      IF n >= %s THEN
        RAISE EXCEPTION '測試用：第 %% 次標已發送故意失敗', n;
      END IF;
      UPDATE purchase_orders
         SET status = 'sent', sent_at = NOW(), sent_by = p_operator, sent_channel = p_channel,
             updated_by = p_operator, updated_at = NOW()
       WHERE id = p_po_id;
    END
    $body$
  $ddl$, p_fail_at);
END $f$;

CREATE FUNCTION pg_temp._t_send_md5() RETURNS TEXT
LANGUAGE sql AS $f$
  SELECT md5(p.prosrc) FROM pg_proc p
   WHERE p.oid = 'public.rpc_send_purchase_order(bigint,text,uuid)'::REGPROCEDURE
$f$;


-- ----------------------------------------------------------------------------
-- 共用夾具：一個租戶、總倉、兩家廠商、兩家店、兩位會員、三個商品、補貨用的內部團
-- ----------------------------------------------------------------------------
DO $base$
DECLARE
  v_t  UUID := (SELECT tenant FROM _t_env);
  v_id BIGINT;
  v_s  TEXT;
BEGIN
  INSERT INTO public.locations(tenant_id, code, name) VALUES (v_t, 'T-HQ', '測試總倉') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('loc', v_id);
  INSERT INTO public.suppliers(tenant_id, code, name) VALUES (v_t, 'T-SA', '廠商A') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('supA', v_id);
  INSERT INTO public.suppliers(tenant_id, code, name) VALUES (v_t, 'T-SB', '廠商B') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('supB', v_id);
  INSERT INTO public.stores(tenant_id, code, name) VALUES (v_t, 'T-A', '店A') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('storeA', v_id);
  INSERT INTO public.stores(tenant_id, code, name) VALUES (v_t, 'T-B', '店B') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('storeB', v_id);
  INSERT INTO public.members(tenant_id, name) VALUES (v_t, '會員A') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('memA', v_id);
  INSERT INTO public.members(tenant_id, name) VALUES (v_t, '會員B') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('memB', v_id);
  INSERT INTO public.members(tenant_id, name) VALUES (v_t, '【內部】店A') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('memInternalA', v_id);
  FOREACH v_s IN ARRAY ARRAY['1', '2', '3'] LOOP
    INSERT INTO public.skus(tenant_id, sku_code, product_name, variant_name)
    VALUES (v_t, 'T-SKU-' || v_s, '測試商品' || v_s, NULL) RETURNING id INTO v_id;
    PERFORM pg_temp._t_put('sku' || v_s, v_id);
  END LOOP;
  -- 補貨內部單掛的團（正式庫是 __INTERNAL_RESTOCK__ 那種 sentinel 團）
  INSERT INTO public.group_buy_campaigns(tenant_id, campaign_no, name, status)
  VALUES (v_t, 'T-INTERNAL', '測試內部補貨團', 'open') RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('campInternal', v_id);
  INSERT INTO public.campaign_items(tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_t, v_id, pg_temp._t_id('sku1'), 100) RETURNING id INTO v_id;
  PERFORM pg_temp._t_put('ciInternal1', v_id);
END
$base$;

-- 一張請購單：S1×10＠50、S2×5＠20 → 廠商A；S3×8＠30 → 廠商B（廠商A 600、廠商B 240）
CREATE FUNCTION pg_temp._t_make_pr(p_key TEXT, p_review TEXT, p_status TEXT) RETURNS BIGINT
LANGUAGE plpgsql AS $f$
DECLARE
  v_t    UUID := (SELECT tenant FROM _t_env);
  v_op   UUID := pg_temp._t_op();
  v_camp BIGINT;
  v_pr   BIGINT;
BEGIN
  INSERT INTO public.group_buy_campaigns(tenant_id, campaign_no, name, status)
  VALUES (v_t, 'T-' || p_key, '測試團' || p_key, 'closed') RETURNING id INTO v_camp;
  INSERT INTO public.campaign_items(tenant_id, campaign_id, sku_id, unit_price)
  SELECT v_t, v_camp, pg_temp._t_id('sku' || s), 100 FROM unnest(ARRAY['1','2','3']) s;

  INSERT INTO public.purchase_requests(tenant_id, pr_no, status, review_status, total_amount, submitted_at, created_by, updated_by)
  VALUES (v_t, 'PR-T-' || p_key, p_status, p_review, 840, NOW(), v_op, v_op) RETURNING id INTO v_pr;
  INSERT INTO public.purchase_request_items(pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, source_campaign_id, created_by, updated_by)
  VALUES (v_pr, pg_temp._t_id('sku1'), 10, pg_temp._t_id('supA'), 50, v_camp, v_op, v_op),
         (v_pr, pg_temp._t_id('sku2'),  5, pg_temp._t_id('supA'), 20, v_camp, v_op, v_op),
         (v_pr, pg_temp._t_id('sku3'),  8, pg_temp._t_id('supB'), 30, v_camp, v_op, v_op);
  INSERT INTO public.purchase_request_campaigns(pr_id, campaign_id, tenant_id) VALUES (v_pr, v_camp, v_t);

  PERFORM pg_temp._t_put(p_key || '.camp', v_camp);
  PERFORM pg_temp._t_put(p_key || '.pr', v_pr);
  RETURN v_pr;
END $f$;

-- 一張「斷貨拆出來的斷貨單」＋ 被它連動取消的下游（照 _stockout_po_items v3 會寫的欄位）：
--   團：S1 斷貨、S2 正常；請購單（已核准、已拆）S1×6、S2×4 都是廠商A
--   來源採購單（已發送）留 S2；斷貨單（cancelled＋stockout_at、拆自來源單）S1×6
--   訂單 O1（會員A、整單因斷貨取消）／O2（會員B、S2 已取、因「剩下都斷貨」收尾成 completed）／
--        O3（沒綁會員、S1 是舊資料：只有 stockout_at 沒有 stockout_po_id）／
--        O4（會員A、已整單轉出 transferred_out → 回復不應該動它）
--   補貨申請（連到這張請購單）＋ 明細 S1 ＋ RR- 內部單，都因斷貨取消
CREATE FUNCTION pg_temp._t_make_stockout(p_key TEXT, p_received NUMERIC DEFAULT 0, p_with_gr BOOLEAN DEFAULT FALSE)
RETURNS BIGINT
LANGUAGE plpgsql AS $f$
DECLARE
  v_t    UUID := (SELECT tenant FROM _t_env);
  v_op   UUID := pg_temp._t_op();
  v_ts   TIMESTAMPTZ := date_trunc('second', NOW()) - INTERVAL '1 day';
  v_camp BIGINT; v_ci1 BIGINT; v_ci2 BIGINT;
  v_pr   BIGINT; v_pri1 BIGINT; v_pri2 BIGINT;
  v_src  BIGINT; v_src2 BIGINT;
  v_so   BIGINT; v_so1 BIGINT;
  v_o    BIGINT;
  v_rr   BIGINT;
BEGIN
  INSERT INTO public.group_buy_campaigns(tenant_id, campaign_no, name, status)
  VALUES (v_t, 'T-' || p_key, '測試團' || p_key, 'closed') RETURNING id INTO v_camp;
  INSERT INTO public.campaign_items(tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_t, v_camp, pg_temp._t_id('sku1'), 100) RETURNING id INTO v_ci1;
  INSERT INTO public.campaign_items(tenant_id, campaign_id, sku_id, unit_price)
  VALUES (v_t, v_camp, pg_temp._t_id('sku2'), 100) RETURNING id INTO v_ci2;

  INSERT INTO public.purchase_requests(tenant_id, pr_no, status, review_status, total_amount, submitted_at, created_by, updated_by)
  VALUES (v_t, 'PR-T-' || p_key, 'fully_ordered', 'approved', 380, v_ts - INTERVAL '3 day', v_op, v_op) RETURNING id INTO v_pr;
  INSERT INTO public.purchase_request_items(pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, source_campaign_id, created_by, updated_by)
  VALUES (v_pr, pg_temp._t_id('sku1'), 6, pg_temp._t_id('supA'), 50, v_camp, v_op, v_op) RETURNING id INTO v_pri1;
  INSERT INTO public.purchase_request_items(pr_id, sku_id, qty_requested, suggested_supplier_id, unit_cost, source_campaign_id, created_by, updated_by)
  VALUES (v_pr, pg_temp._t_id('sku2'), 4, pg_temp._t_id('supA'), 20, v_camp, v_op, v_op) RETURNING id INTO v_pri2;
  INSERT INTO public.purchase_request_campaigns(pr_id, campaign_id, tenant_id) VALUES (v_pr, v_camp, v_t);

  INSERT INTO public.purchase_orders(tenant_id, po_no, supplier_id, dest_location_id, status, subtotal, total,
                                     created_by, updated_by, sent_at, sent_by, sent_channel)
  VALUES (v_t, 'PO-T-' || p_key || '-SRC', pg_temp._t_id('supA'), pg_temp._t_id('loc'), 'sent', 80, 80,
          v_op, v_op, v_ts - INTERVAL '2 day', v_op, 'line') RETURNING id INTO v_src;
  INSERT INTO public.purchase_order_items(po_id, sku_id, qty_ordered, unit_cost, created_by, updated_by)
  VALUES (v_src, pg_temp._t_id('sku2'), 4, 20, v_op, v_op) RETURNING id INTO v_src2;

  INSERT INTO public.purchase_orders(tenant_id, po_no, supplier_id, dest_location_id, status, subtotal, total,
                                     created_by, updated_by, stockout_at, stockout_by, stockout_reason,
                                     stockout_split_from_po_id)
  VALUES (v_t, 'PO-T-' || p_key || '-SO', pg_temp._t_id('supA'), pg_temp._t_id('loc'), 'cancelled', 300, 300,
          v_op, v_op, v_ts, v_op, '測試斷貨', v_src) RETURNING id INTO v_so;
  INSERT INTO public.purchase_order_items(po_id, sku_id, qty_ordered, qty_received, unit_cost,
                                          stockout_at, stockout_by, stockout_reason, created_by, updated_by)
  VALUES (v_so, pg_temp._t_id('sku1'), 6, p_received, 50, v_ts, v_op, '測試斷貨', v_op, v_op) RETURNING id INTO v_so1;

  UPDATE public.purchase_request_items SET po_item_id = v_so1  WHERE id = v_pri1;
  UPDATE public.purchase_request_items SET po_item_id = v_src2 WHERE id = v_pri2;
  UPDATE public.campaign_items SET stockout_at = v_ts, stockout_po_id = v_so WHERE id = v_ci1;

  -- O1：會員A、整單因斷貨取消（取消前是 confirmed）
  INSERT INTO public.customer_orders(tenant_id, order_no, campaign_id, member_id, pickup_store_id, status,
                                     confirmed_at, cancelled_at, stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, 'T-' || p_key || '-O1', v_camp, pg_temp._t_id('memA'), pg_temp._t_id('storeA'), 'cancelled',
          v_ts - INTERVAL '2 day', v_ts, v_ts, v_so, v_op) RETURNING id INTO v_o;
  INSERT INTO public.customer_order_items(tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status,
                                          stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_o, v_ci1, pg_temp._t_id('sku1'), 2, 100, 'cancelled', v_ts, v_so, v_op);
  PERFORM pg_temp._t_put(p_key || '.o1', v_o);

  -- O2：會員B、S2 已取、S1 斷貨 → 收尾成 completed
  INSERT INTO public.customer_orders(tenant_id, order_no, campaign_id, member_id, pickup_store_id, status,
                                     confirmed_at, completed_at, updated_by)
  VALUES (v_t, 'T-' || p_key || '-O2', v_camp, pg_temp._t_id('memB'), pg_temp._t_id('storeB'), 'completed',
          v_ts - INTERVAL '2 day', v_ts, v_op) RETURNING id INTO v_o;
  INSERT INTO public.customer_order_items(tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status,
                                          stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_o, v_ci1, pg_temp._t_id('sku1'), 1, 100, 'cancelled', v_ts, v_so, v_op),
         (v_t, v_o, v_ci2, pg_temp._t_id('sku2'), 1, 100, 'picked_up', NULL, NULL, v_op);
  PERFORM pg_temp._t_put(p_key || '.o2', v_o);

  -- O3：沒綁會員；S1 是舊資料（只有斷貨時間、沒有 stockout_po_id → 走「時間＋SKU＋團」fallback）
  INSERT INTO public.customer_orders(tenant_id, order_no, campaign_id, member_id, pickup_store_id, status,
                                     confirmed_at, updated_by)
  VALUES (v_t, 'T-' || p_key || '-O3', v_camp, NULL, pg_temp._t_id('storeA'), 'confirmed',
          v_ts - INTERVAL '2 day', v_op) RETURNING id INTO v_o;
  INSERT INTO public.customer_order_items(tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status,
                                          stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_o, v_ci1, pg_temp._t_id('sku1'), 1, 100, 'cancelled', v_ts, NULL, v_op),
         (v_t, v_o, v_ci2, pg_temp._t_id('sku2'), 1, 100, 'pending', NULL, NULL, v_op);
  PERFORM pg_temp._t_put(p_key || '.o3', v_o);

  -- O4：會員A、已整單轉出 → 回復不應該動它
  INSERT INTO public.customer_orders(tenant_id, order_no, campaign_id, member_id, pickup_store_id, status,
                                     confirmed_at, updated_by)
  VALUES (v_t, 'T-' || p_key || '-O4', v_camp, pg_temp._t_id('memA'), pg_temp._t_id('storeB'), 'transferred_out',
          v_ts - INTERVAL '2 day', v_op) RETURNING id INTO v_o;
  INSERT INTO public.customer_order_items(tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status,
                                          stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_o, v_ci1, pg_temp._t_id('sku1'), 1, 100, 'cancelled', v_ts, v_so, v_op);
  PERFORM pg_temp._t_put(p_key || '.o4', v_o);

  -- 補貨申請（連到這張請購單）＋ 明細 ＋ RR- 內部單，都因斷貨取消
  INSERT INTO public.restock_requests(tenant_id, requesting_store_id, status, linked_pr_id, stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, pg_temp._t_id('storeA'), 'cancelled', v_pr, v_ts, v_so, v_op) RETURNING id INTO v_rr;
  INSERT INTO public.restock_request_lines(tenant_id, request_id, sku_id, qty, cancelled_at, cancelled_by,
                                           stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_rr, pg_temp._t_id('sku1'), 2, v_ts, v_op, v_ts, v_so, v_op);
  INSERT INTO public.customer_orders(tenant_id, order_no, campaign_id, member_id, pickup_store_id, status, order_kind,
                                     cancelled_at, stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, 'RR-' || v_rr, pg_temp._t_id('campInternal'), pg_temp._t_id('memInternalA'), pg_temp._t_id('storeA'),
          'cancelled', 'restock', v_ts, v_ts, v_so, v_op) RETURNING id INTO v_o;
  INSERT INTO public.customer_order_items(tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price, status,
                                          stockout_at, stockout_po_id, updated_by)
  VALUES (v_t, v_o, pg_temp._t_id('ciInternal1'), pg_temp._t_id('sku1'), 2, 100, 'cancelled', v_ts, v_so, v_op);
  PERFORM pg_temp._t_put(p_key || '.rr', v_rr);
  PERFORM pg_temp._t_put(p_key || '.rro', v_o);

  IF p_with_gr THEN
    INSERT INTO public.goods_receipts(tenant_id, po_id, status) VALUES (v_t, v_so, 'confirmed');
  END IF;

  PERFORM pg_temp._t_put(p_key || '.camp', v_camp);
  PERFORM pg_temp._t_put(p_key || '.pr', v_pr);
  PERFORM pg_temp._t_put(p_key || '.src', v_src);
  PERFORM pg_temp._t_put(p_key || '.so', v_so);
  RETURN v_so;
END $f$;


-- ----------------------------------------------------------------------------
-- 測 0：夾具前提
-- ----------------------------------------------------------------------------
DO $t0$
DECLARE v_missing TEXT;
BEGIN
  SELECT string_agg(x, ', ') INTO v_missing
    FROM unnest(ARRAY[
      'public.rpc_split_pr_to_pos(bigint,bigint,uuid)',
      'public.rpc_send_purchase_order(bigint,text,uuid)',
      'public.rpc_restore_stockout_po(bigint,uuid)',
      'public.rpc_split_pr_to_pos_and_mark_sent(bigint,bigint,uuid)',
      'public.rpc_restore_stockout_po_and_mark_sent(bigint,uuid)'
    ]) x
   WHERE to_regprocedure(x) IS NULL;
  INSERT INTO _t_result VALUES (0, '夾具前提：既有三支、新的兩支都在', v_missing IS NULL,
    COALESCE('缺：' || v_missing, '五支都在'));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (0, '夾具前提', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t0$;


-- ----------------------------------------------------------------------------
-- 測 1：（①）兩家廠商 → 2 張、都是已發送／manual
-- ----------------------------------------------------------------------------
DO $t1$
DECLARE
  v_pr   BIGINT := pg_temp._t_make_pr('p1', 'approved', 'submitted');
  v_op   UUID := pg_temp._t_op();
  v_ret  BIGINT[];
  v_pos  BIGINT[];
  v_bad  TEXT;
  v_pr_status TEXT;
BEGIN
  v_ret := public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), v_op);
  v_pos := pg_temp._t_pos_of(v_pr);

  SELECT string_agg(format('%s:%s/%s/%s/%s/%s/%s', po.po_no, po.status, po.sent_channel,
                           po.sent_at = NOW(), po.sent_by = v_op, po.subtotal, po.total), '；')
    INTO v_bad
    FROM public.purchase_orders po
   WHERE po.id = ANY (v_pos)
     AND NOT (po.status = 'sent' AND po.sent_channel = 'manual' AND po.sent_at = NOW()
              AND po.sent_by = v_op AND po.updated_by = v_op
              AND ((po.supplier_id = pg_temp._t_id('supA') AND po.subtotal = 600 AND po.total = 600
                    AND (SELECT COUNT(*) FROM public.purchase_order_items WHERE po_id = po.id) = 2)
                OR (po.supplier_id = pg_temp._t_id('supB') AND po.subtotal = 240 AND po.total = 240
                    AND (SELECT COUNT(*) FROM public.purchase_order_items WHERE po_id = po.id) = 1)));

  SELECT status INTO v_pr_status FROM public.purchase_requests WHERE id = v_pr;

  INSERT INTO _t_result VALUES (1,
    '（①）核准的請購單、兩家廠商 → 2 張採購單都是已發送、管道 manual、sent_at／sent_by 有值；品項金額照舊',
    COALESCE(
      cardinality(v_ret) = 2
      AND (SELECT array_agg(x ORDER BY x) FROM unnest(v_ret) x) = v_pos
      AND v_bad IS NULL
      AND v_pr_status = 'fully_ordered'
      AND NOT EXISTS (SELECT 1 FROM public.purchase_request_items WHERE pr_id = v_pr AND po_item_id IS NULL),
      FALSE),
    format('回傳 %s 張｜連到的採購單 %s｜不合格：%s｜請購單狀態 %s｜各張：%s',
           cardinality(v_ret), v_pos, COALESCE(v_bad, '無'), v_pr_status,
           (SELECT string_agg(format('%s=%s/%s/%s', po.supplier_id, po.status, po.sent_channel, po.subtotal), ' ')
              FROM public.purchase_orders po WHERE po.id = ANY (v_pos))));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (1, '（①）兩家廠商 → 2 張已發送', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t1$;


-- ----------------------------------------------------------------------------
-- 測 2：（①）對照原本的拆單：差別只有 status／sent_at／sent_by／sent_channel
-- ----------------------------------------------------------------------------
DO $t2$
DECLARE
  v_pr   BIGINT := pg_temp._t_make_pr('p2', 'approved', 'submitted');
  v_op   UUID := pg_temp._t_op();
  v_orig JSONB;
  v_new  JSONB;
  v_cols TEXT[];
  v_n    INT;
  v_ok   BOOLEAN;
BEGIN
  -- 先用原本的拆單跑一次、記下結果，再整段退回（變數留著）
  BEGIN
    PERFORM public.rpc_split_pr_to_pos(v_pr, pg_temp._t_id('loc'), v_op);
    v_orig := pg_temp._t_po_norm(v_pr);
    RAISE EXCEPTION '__probe_rollback__';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> '__probe_rollback__' THEN RAISE; END IF;
  END;

  PERFORM public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), v_op);
  v_new := pg_temp._t_po_norm(v_pr);

  SELECT array_agg(DISTINCT d.tbl || '.' || d.col ORDER BY d.tbl || '.' || d.col), COUNT(*)
    INTO v_cols, v_n
    FROM pg_temp._t_diff(v_orig, v_new) d;

  SELECT bool_and(
           CASE d.col
             WHEN 'status'       THEN d.va = '"draft"'::JSONB AND d.vb = '"sent"'::JSONB
             WHEN 'sent_channel' THEN d.va = 'null'::JSONB AND d.vb = '"manual"'::JSONB
             WHEN 'sent_by'      THEN d.va = 'null'::JSONB AND d.vb = to_jsonb(v_op)
             WHEN 'sent_at'      THEN d.va = 'null'::JSONB AND d.vb IS NOT NULL AND d.vb <> 'null'::JSONB
             ELSE FALSE
           END)
    INTO v_ok
    FROM pg_temp._t_diff(v_orig, v_new) d;

  INSERT INTO _t_result VALUES (2,
    '（①）跟原本的拆單逐欄比（採購單、品項、請購單、請購品項）：差別只有兩張採購單的 status／sent_at／sent_by／sent_channel',
    COALESCE(v_n = 8
             AND v_cols = ARRAY['po.sent_at', 'po.sent_by', 'po.sent_channel', 'po.status']
             AND v_ok
             AND jsonb_typeof(v_orig -> 'po') = 'object'
             AND (SELECT COUNT(*) FROM jsonb_object_keys(v_orig -> 'po')) = 2, FALSE),
    format('不一樣的欄位 %s 個：%s', v_n, pg_temp._t_diff_txt(v_orig, v_new)));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (2, '（①）跟原本的拆單逐欄比', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t2$;


-- ----------------------------------------------------------------------------
-- 測 3／4：（②）rpc_send_purchase_order 會丟錯 → 新程式整筆失敗
--   換函式這件事本身在「試跑區塊」裡，區塊結束就跟著退回（測完再驗原本的函式一字不差）
-- ----------------------------------------------------------------------------
DO $t34$
DECLARE
  v_fail_at INT;
  v_seq     INT;
  v_pr      BIGINT;
  v_op      UUID := pg_temp._t_op();
  v_md5     TEXT := pg_temp._t_send_md5();
  v_before  JSONB;
  v_after   JSONB;
  v_raised  BOOLEAN;
  v_msg     TEXT;
  v_detail  TEXT;
  v_state   TEXT;
  v_diff    TEXT;
BEGIN
  FOREACH v_fail_at IN ARRAY ARRAY[2, 1] LOOP
    v_seq := CASE v_fail_at WHEN 2 THEN 3 ELSE 4 END;
    v_raised := FALSE; v_msg := NULL; v_detail := NULL; v_diff := NULL;
    BEGIN
      v_pr := pg_temp._t_make_pr('p' || v_seq, 'approved', 'submitted');
      BEGIN
        PERFORM pg_temp._t_install_failing_send(v_fail_at);
        v_before := pg_temp._t_snapshot();
        BEGIN
          PERFORM public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), v_op);
        EXCEPTION WHEN OTHERS THEN
          v_raised := TRUE;
          GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL, v_state = RETURNED_SQLSTATE;
        END;
        v_after := pg_temp._t_snapshot();
        v_diff := pg_temp._t_diff_txt(v_before, v_after);
        RAISE EXCEPTION '__probe_rollback__';
      EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> '__probe_rollback__' THEN RAISE; END IF;
      END;

      INSERT INTO _t_result VALUES (v_seq,
        format('（②）rpc_send_purchase_order 第 %s 次呼叫起丟錯 → 新程式整筆失敗：一張採購單都沒建、請購單不變、訊息白話',
               v_fail_at),
        COALESCE(v_raised
                 AND v_msg LIKE '採購單建好後要直接標成「已發送」時失敗，所以整筆都沒有做：一張採購單都沒有建立，請購單維持原狀。原因：測試用：第 '
                                || v_fail_at || ' 次標已發送故意失敗'
                 AND v_detail LIKE 'rpc_send_purchase_order(%): 測試用：第 ' || v_fail_at || ' 次標已發送故意失敗'
                 AND v_diff IS NULL
                 AND cardinality(pg_temp._t_pos_of(v_pr)) = 0
                 AND (SELECT status FROM public.purchase_requests WHERE id = v_pr) = 'submitted'
                 AND NOT EXISTS (SELECT 1 FROM public.purchase_request_items WHERE pr_id = v_pr AND po_item_id IS NOT NULL)
                 AND pg_temp._t_send_md5() = v_md5, FALSE),
        format('有丟錯=%s｜SQLSTATE=%s｜訊息=%s｜DETAIL=%s｜前後差異=%s｜原本的 send 一字不差=%s',
               v_raised, v_state, v_msg, v_detail, COALESCE(v_diff, '無'), pg_temp._t_send_md5() = v_md5));
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO _t_result VALUES (v_seq, format('（②）第 %s 次呼叫起丟錯', v_fail_at), FALSE, 'EXCEPTION: ' || SQLERRM);
    END;
  END LOOP;
END
$t34$;


-- ----------------------------------------------------------------------------
-- 測 5／6：（③）請購單沒核准 → 照舊擋
-- ----------------------------------------------------------------------------
DO $t56$
DECLARE
  v_review TEXT;
  v_seq    INT;
  v_pr     BIGINT;
  v_before JSONB;
  v_raised BOOLEAN;
  v_msg    TEXT;
BEGIN
  FOREACH v_review IN ARRAY ARRAY['pending_review', 'rejected'] LOOP
    v_seq := CASE v_review WHEN 'pending_review' THEN 5 ELSE 6 END;
    v_raised := FALSE; v_msg := NULL;
    BEGIN
      v_pr := pg_temp._t_make_pr('p' || v_seq, v_review, 'submitted');
      v_before := pg_temp._t_snapshot();
      BEGIN
        PERFORM public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), pg_temp._t_op());
      EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
        v_msg := SQLERRM;
      END;
      INSERT INTO _t_result VALUES (v_seq,
        format('（③）請購單 review_status=%s → 照舊擋（原本 rpc_split_pr_to_pos 的訊息原封不動）、什麼都沒變', v_review),
        COALESCE(v_raised
                 AND v_msg = format('PR %s not approved (current: %s)', v_pr, v_review)
                 AND pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot()) IS NULL
                 AND cardinality(pg_temp._t_pos_of(v_pr)) = 0, FALSE),
        format('有擋=%s｜訊息=%s', v_raised, v_msg));
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO _t_result VALUES (v_seq, format('（③）review_status=%s', v_review), FALSE, 'EXCEPTION: ' || SQLERRM);
    END;
  END LOOP;
END
$t56$;


-- ----------------------------------------------------------------------------
-- 測 7：（③）重複按（已拆過）→ 照舊擋，第一次建的不動
-- ----------------------------------------------------------------------------
DO $t7$
DECLARE
  v_pr     BIGINT := pg_temp._t_make_pr('p7', 'approved', 'submitted');
  v_op     UUID := pg_temp._t_op();
  v_first  BIGINT[];
  v_before JSONB;
  v_raised BOOLEAN := FALSE;
  v_msg    TEXT;
BEGIN
  v_first := public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), v_op);
  v_before := pg_temp._t_snapshot();
  BEGIN
    PERFORM public.rpc_split_pr_to_pos_and_mark_sent(v_pr, pg_temp._t_id('loc'), v_op);
  EXCEPTION WHEN OTHERS THEN
    v_raised := TRUE;
    v_msg := SQLERRM;
  END;
  INSERT INTO _t_result VALUES (7,
    '（③）同一張請購單再按一次 → 照舊擋（already split），第一次建的採購單一個字都沒變',
    COALESCE(v_raised
             AND v_msg = format('PR %s already split (status: fully_ordered)', v_pr)
             AND pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot()) IS NULL
             AND pg_temp._t_pos_of(v_pr) = (SELECT array_agg(x ORDER BY x) FROM unnest(v_first) x), FALSE),
    format('有擋=%s｜訊息=%s｜第一次 %s 張', v_raised, v_msg, cardinality(v_first)));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (7, '（③）重複按', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t7$;


-- ----------------------------------------------------------------------------
-- 測 8：（④）回復斷貨 → 已發送；跟「只呼叫原本 restore」逐欄比對
-- ----------------------------------------------------------------------------
DO $t8$
DECLARE
  v_so       BIGINT := pg_temp._t_make_stockout('r8');
  v_op       UUID := pg_temp._t_op();
  v_before   JSONB;
  v_orig     JSONB;
  v_new      JSONB;
  v_ret_orig JSONB;
  v_ret_new  JSONB;
  v_back     TEXT;
  v_cols     TEXT[];
  v_n        INT;
  v_ok       BOOLEAN;
  v_orig_n   INT;
  v_po       RECORD;
  v_state    TEXT;
  v_notif    INT;
BEGIN
  v_before := pg_temp._t_snapshot();

  -- 先用原本的 restore 跑一次、記下全部相關表與回傳，再整段退回（變數留著）
  BEGIN
    v_ret_orig := public.rpc_restore_stockout_po(v_so, v_op);
    v_orig := pg_temp._t_snapshot();
    RAISE EXCEPTION '__probe_rollback__';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> '__probe_rollback__' THEN RAISE; END IF;
  END;
  v_back := pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot());   -- 退回後必須跟開始時一樣

  v_ret_new := public.rpc_restore_stockout_po_and_mark_sent(v_so, v_op);
  v_new := pg_temp._t_snapshot();

  SELECT array_agg(DISTINCT d.tbl || '.' || d.col ORDER BY d.tbl || '.' || d.col), COUNT(*)
    INTO v_cols, v_n
    FROM pg_temp._t_diff(v_orig, v_new) d;
  SELECT bool_and(d.tbl = 'purchase_orders' AND d.rk = v_so::TEXT
                  AND CASE d.col
                        WHEN 'status'       THEN d.va = '"draft"'::JSONB AND d.vb = '"sent"'::JSONB
                        WHEN 'sent_channel' THEN d.va = 'null'::JSONB AND d.vb = '"manual"'::JSONB
                        WHEN 'sent_by'      THEN d.va = 'null'::JSONB AND d.vb = to_jsonb(v_op)
                        WHEN 'sent_at'      THEN d.va = 'null'::JSONB AND d.vb IS NOT NULL AND d.vb <> 'null'::JSONB
                        ELSE FALSE
                      END)
    INTO v_ok
    FROM pg_temp._t_diff(v_orig, v_new) d;
  SELECT COUNT(*) INTO v_orig_n FROM pg_temp._t_diff(v_before, v_orig);
  SELECT * INTO v_po FROM public.purchase_orders WHERE id = v_so;

  -- 還原面（原本 restore 該做的事，新程式照樣做到）
  v_state := concat_ws(' ',
    'O1=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r8.o1')),
    'O2=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r8.o2')),
    'O3=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r8.o3')),
    'O4=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r8.o4')),
    'S1待取=' || (SELECT COUNT(*) FROM public.customer_order_items coi
                    WHERE coi.order_id IN (pg_temp._t_id('r8.o1'), pg_temp._t_id('r8.o2'), pg_temp._t_id('r8.o3'))
                      AND coi.sku_id = pg_temp._t_id('sku1') AND coi.status = 'pending'
                      AND coi.stockout_at IS NULL AND coi.stockout_po_id IS NULL),
    'O4的S1=' || (SELECT string_agg(status, ',') FROM public.customer_order_items WHERE order_id = pg_temp._t_id('r8.o4')),
    'RR=' || (SELECT status FROM public.restock_requests WHERE id = pg_temp._t_id('r8.rr')),
    'RR明細取消=' || (SELECT COUNT(*) FROM public.restock_request_lines WHERE request_id = pg_temp._t_id('r8.rr') AND cancelled_at IS NOT NULL),
    'RR單=' || (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r8.rro')),
    'RR單品項=' || (SELECT string_agg(status, ',') FROM public.customer_order_items WHERE order_id = pg_temp._t_id('r8.rro')),
    '團商品斷貨=' || (SELECT COUNT(*) FROM public.campaign_items WHERE campaign_id = pg_temp._t_id('r8.camp') AND stockout_at IS NOT NULL));
  SELECT COUNT(*) INTO v_notif FROM pg_temp._t_diff(v_before, v_new) d WHERE d.tbl = 'notifications' AND d.col = 'title';

  INSERT INTO _t_result VALUES (8,
    '（④）斷貨單 → 新的回復 → 已發送／manual；客人訂單照舊還原；跟只呼叫原本 restore 逐欄比，只差採購單 4 欄；回傳只差 po_status',
    COALESCE(
      v_back IS NULL
      AND v_orig_n > 0
      AND v_n = 4
      AND v_cols = ARRAY['purchase_orders.sent_at', 'purchase_orders.sent_by', 'purchase_orders.sent_channel',
                         'purchase_orders.status']
      AND v_ok
      AND v_po.status = 'sent' AND v_po.sent_channel = 'manual' AND v_po.sent_at = NOW() AND v_po.sent_by = v_op
      AND v_po.stockout_at IS NULL AND v_po.stockout_restored_at = NOW()
      AND v_state = 'O1=confirmed O2=partially_completed O3=confirmed O4=transferred_out S1待取=3 O4的S1=cancelled '
                    || 'RR=approved_pr RR明細取消=0 RR單=pending RR單品項=pending 團商品斷貨=0'
      AND v_notif = 2
      AND v_ret_orig ->> 'po_status' = 'draft'
      AND v_ret_new = v_ret_orig || jsonb_build_object('po_status', 'sent')
      AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_ret_new) k)
          = (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(v_ret_orig) k), FALSE),
    format('退回後跟開始時一樣=%s｜原本 restore 改了 %s 欄｜新舊差 %s 欄：%s｜採購單=%s/%s｜還原面：%s｜新通知 %s 則｜原本回傳=%s｜新回傳=%s',
           v_back IS NULL, v_orig_n, v_n, pg_temp._t_diff_txt(v_orig, v_new), v_po.status, v_po.sent_channel,
           v_state, v_notif, v_ret_orig, v_ret_new));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (8, '（④）回復斷貨 → 已發送', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t8$;


-- ----------------------------------------------------------------------------
-- 測 9／10：（⑤）有到貨量／有未取消的進貨單 → 照舊擋、什麼都沒變
-- ----------------------------------------------------------------------------
DO $t910$
DECLARE
  v_case   INT;
  v_so     BIGINT;
  v_before JSONB;
  v_raised BOOLEAN;
  v_msg    TEXT;
  v_want   TEXT;
BEGIN
  FOREACH v_case IN ARRAY ARRAY[9, 10] LOOP
    v_raised := FALSE; v_msg := NULL;
    BEGIN
      IF v_case = 9 THEN
        v_so := pg_temp._t_make_stockout('r9', 2, FALSE);
        v_want := format('採購單 %s 已有到貨量、不可整張回復（請另開採購單補訂未到的量）', 'PO-T-r9-SO');
      ELSE
        v_so := pg_temp._t_make_stockout('r10', 0, TRUE);
        v_want := format('採購單 %s 已有進貨單、不可回復', 'PO-T-r10-SO');
      END IF;
      v_before := pg_temp._t_snapshot();
      BEGIN
        PERFORM public.rpc_restore_stockout_po_and_mark_sent(v_so, pg_temp._t_op());
      EXCEPTION WHEN OTHERS THEN
        v_raised := TRUE;
        v_msg := SQLERRM;
      END;
      INSERT INTO _t_result VALUES (v_case,
        CASE v_case WHEN 9 THEN '（⑤）斷貨單有到貨量 → 照舊擋（原本的訊息）、什麼都沒變'
                    ELSE '（⑤）斷貨單有未取消的進貨單 → 照舊擋（原本的訊息）、什麼都沒變' END,
        COALESCE(v_raised AND v_msg = v_want
                 AND pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot()) IS NULL
                 AND (SELECT status FROM public.purchase_orders WHERE id = v_so) = 'cancelled', FALSE),
        format('有擋=%s｜訊息=%s', v_raised, v_msg));
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO _t_result VALUES (v_case, '（⑤）照舊擋', FALSE, 'EXCEPTION: ' || SQLERRM);
    END;
  END LOOP;
END
$t910$;


-- ----------------------------------------------------------------------------
-- 測 11：（⑥）來源請購單被改成「已退回」→ 原本 restore 自己會成功，新程式在第 2 步被真的 send 擋下 → 整筆不做
-- ----------------------------------------------------------------------------
DO $t11$
DECLARE
  v_so       BIGINT := pg_temp._t_make_stockout('r11');
  v_op       UUID := pg_temp._t_op();
  v_step1_ok BOOLEAN := FALSE;
  v_before   JSONB;
  v_raised   BOOLEAN := FALSE;
  v_msg      TEXT;
  v_detail   TEXT;
  v_diff     TEXT;
BEGIN
  UPDATE public.purchase_requests SET review_status = 'rejected' WHERE id = pg_temp._t_id('r11.pr');

  -- 證明第 1 步本身過得了（試跑後退回）
  BEGIN
    PERFORM public.rpc_restore_stockout_po(v_so, v_op);
    v_step1_ok := TRUE;
    RAISE EXCEPTION '__probe_rollback__';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> '__probe_rollback__' THEN RAISE; END IF;
  END;

  v_before := pg_temp._t_snapshot();
  BEGIN
    PERFORM public.rpc_restore_stockout_po_and_mark_sent(v_so, v_op);
  EXCEPTION WHEN OTHERS THEN
    v_raised := TRUE;
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL;
  END;
  v_diff := pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot());

  INSERT INTO _t_result VALUES (11,
    '（⑥）來源請購單已退回 → 原本 restore 自己會成功，但新程式第 2 步被 rpc_send_purchase_order 擋 → 整筆不做（還是斷貨單、訂單沒還原、沒發通知）、訊息白話',
    COALESCE(v_step1_ok AND v_raised
             AND v_msg = '斷貨回復後要直接標成「已發送」時失敗，所以整筆都沒有做：這張單還是斷貨單，客人訂單、開團商品、補貨申請都沒有還原，也沒有發出「已恢復」通知。原因：來源請購單已被退回（審核不通過）'
             AND v_detail = format('rpc_send_purchase_order(%s): PO has 1 rejected PR', v_so)
             AND v_diff IS NULL
             AND (SELECT status = 'cancelled' AND stockout_at IS NOT NULL FROM public.purchase_orders WHERE id = v_so)
             AND (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r11.o1')) = 'cancelled', FALSE),
    format('第 1 步自己過得了=%s｜有丟錯=%s｜訊息=%s｜DETAIL=%s｜前後差異=%s', v_step1_ok, v_raised, v_msg, v_detail, COALESCE(v_diff, '無')));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (11, '（⑥）來源請購單已退回', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t11$;


-- ----------------------------------------------------------------------------
-- 測 12：（⑥）rpc_send_purchase_order 換成會丟錯的版本 → 回復整筆不做
-- ----------------------------------------------------------------------------
DO $t12$
DECLARE
  v_so     BIGINT := pg_temp._t_make_stockout('r12');
  v_md5    TEXT := pg_temp._t_send_md5();
  v_before JSONB;
  v_raised BOOLEAN := FALSE;
  v_msg    TEXT;
  v_diff   TEXT;
BEGIN
  BEGIN
    PERFORM pg_temp._t_install_failing_send(1);
    v_before := pg_temp._t_snapshot();
    BEGIN
      PERFORM public.rpc_restore_stockout_po_and_mark_sent(v_so, pg_temp._t_op());
    EXCEPTION WHEN OTHERS THEN
      v_raised := TRUE;
      v_msg := SQLERRM;
    END;
    v_diff := pg_temp._t_diff_txt(v_before, pg_temp._t_snapshot());
    RAISE EXCEPTION '__probe_rollback__';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> '__probe_rollback__' THEN RAISE; END IF;
  END;

  INSERT INTO _t_result VALUES (12,
    '（⑥）rpc_send_purchase_order 丟錯 → 回復整筆不做、訊息白話',
    COALESCE(v_raised
             AND v_msg = '斷貨回復後要直接標成「已發送」時失敗，所以整筆都沒有做：這張單還是斷貨單，客人訂單、開團商品、補貨申請都沒有還原，也沒有發出「已恢復」通知。原因：測試用：第 1 次標已發送故意失敗'
             AND v_diff IS NULL
             AND (SELECT status FROM public.purchase_orders WHERE id = v_so) = 'cancelled'
             AND pg_temp._t_send_md5() = v_md5, FALSE),
    format('有丟錯=%s｜訊息=%s｜前後差異=%s｜原本的 send 一字不差=%s', v_raised, v_msg, COALESCE(v_diff, '無'),
           pg_temp._t_send_md5() = v_md5));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (12, '（⑥）send 丟錯 → 回復整筆不做', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t12$;


-- ----------------------------------------------------------------------------
-- 測 13／14：（⑦）改版前留下的草稿單 → 原本的 rpc_send_purchase_order 照樣能送
-- ----------------------------------------------------------------------------
DO $t13$
DECLARE
  v_pr  BIGINT := pg_temp._t_make_pr('p13', 'approved', 'submitted');
  v_op  UUID := pg_temp._t_op();
  v_ids BIGINT[];
  v_got TEXT;
BEGIN
  v_ids := public.rpc_split_pr_to_pos(v_pr, pg_temp._t_id('loc'), v_op);   -- 舊的拆單：草稿
  IF (SELECT bool_and(status = 'draft') FROM public.purchase_orders WHERE id = ANY (v_ids)) IS NOT TRUE THEN
    RAISE EXCEPTION '夾具不對：舊的拆單應該建出草稿';
  END IF;
  PERFORM public.rpc_send_purchase_order(v_ids[1], 'line', v_op);
  PERFORM public.rpc_send_purchase_order(v_ids[2], 'manual', v_op);
  SELECT string_agg(status || '/' || sent_channel || '/' || (sent_by = v_op), ',' ORDER BY id) INTO v_got
    FROM public.purchase_orders WHERE id = ANY (v_ids);
  INSERT INTO _t_result VALUES (13,
    '（⑦）改版前的草稿單（原本的拆單建的）→ 原本的「📤 發送」照樣能送（line、manual）',
    COALESCE(cardinality(v_ids) = 2 AND v_got = 'sent/line/true,sent/manual/true', FALSE),
    format('結果：%s', v_got));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (13, '（⑦）舊草稿單照樣能送', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t13$;

DO $t14$
DECLARE
  v_so  BIGINT := pg_temp._t_make_stockout('r14');
  v_op  UUID := pg_temp._t_op();
  v_ret JSONB;
  v_got TEXT;
BEGIN
  v_ret := public.rpc_restore_stockout_po(v_so, v_op);                     -- 舊的回復：變回草稿
  PERFORM public.rpc_send_purchase_order(v_so, 'phone', v_op);
  SELECT status || '/' || sent_channel INTO v_got FROM public.purchase_orders WHERE id = v_so;
  INSERT INTO _t_result VALUES (14,
    '（⑦）改版前「回復成草稿」的單（原本的 restore）→ 原本的「📤 發送」照樣能送',
    COALESCE(v_ret ->> 'po_status' = 'draft' AND v_got = 'sent/phone', FALSE),
    format('舊回復回傳 po_status=%s｜發送後：%s', v_ret ->> 'po_status', v_got));
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (14, '（⑦）舊的已回復草稿單照樣能送', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t14$;


-- ----------------------------------------------------------------------------
-- 測 15：（⑧）權限
-- ----------------------------------------------------------------------------
DO $t15$
DECLARE
  v_split   REGPROCEDURE := 'public.rpc_split_pr_to_pos_and_mark_sent(bigint,bigint,uuid)'::REGPROCEDURE;
  v_restore REGPROCEDURE := 'public.rpc_restore_stockout_po_and_mark_sent(bigint,uuid)'::REGPROCEDURE;
  v_pr      BIGINT := pg_temp._t_make_pr('p15', 'approved', 'submitted');
  v_so      BIGINT := pg_temp._t_make_stockout('r15');
  v_loc     BIGINT := pg_temp._t_id('loc');
  v_op      UUID := pg_temp._t_op();
  v_bad     TEXT := '';
  v_state1  TEXT;
  v_state2  TEXT;
BEGIN
  IF has_function_privilege('anon', v_split, 'EXECUTE') THEN v_bad := v_bad || ' anon可執行建立'; END IF;
  IF has_function_privilege('anon', v_restore, 'EXECUTE') THEN v_bad := v_bad || ' anon可執行回復'; END IF;
  IF NOT has_function_privilege('authenticated', v_split, 'EXECUTE') THEN v_bad := v_bad || ' authenticated不能執行建立'; END IF;
  IF NOT has_function_privilege('authenticated', v_restore, 'EXECUTE') THEN v_bad := v_bad || ' authenticated不能執行回復'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.oid IN (v_split, v_restore) AND p.proacl IS NULL) THEN
    v_bad := v_bad || ' proacl是NULL（＝預設給PUBLIC）';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
              WHERE p.oid IN (v_split, v_restore) AND a.grantee = 0) THEN
    v_bad := v_bad || ' PUBLIC有執行權';
  END IF;

  -- 實際用 anon 身分呼叫：要拿到 42501（insufficient_privilege）
  BEGIN
    EXECUTE 'SET ROLE anon';
    PERFORM public.rpc_split_pr_to_pos_and_mark_sent(v_pr, v_loc, v_op);
    v_state1 := '居然成功';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state1 := '42501';
  WHEN OTHERS THEN
    v_state1 := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  BEGIN
    EXECUTE 'SET ROLE anon';
    PERFORM public.rpc_restore_stockout_po_and_mark_sent(v_so, v_op);
    v_state2 := '居然成功';
  EXCEPTION WHEN insufficient_privilege THEN
    v_state2 := '42501';
  WHEN OTHERS THEN
    v_state2 := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';

  INSERT INTO _t_result VALUES (15,
    '（⑧）權限：anon 不能執行兩支新函式（實際呼叫拿到 42501）、PUBLIC 沒有執行權、authenticated 有',
    COALESCE(v_bad = '' AND v_state1 = '42501' AND v_state2 = '42501'
             AND cardinality(pg_temp._t_pos_of(v_pr)) = 0
             AND (SELECT status FROM public.purchase_orders WHERE id = v_so) = 'cancelled', FALSE),
    format('問題：%s｜anon 呼叫建立=%s｜anon 呼叫回復=%s',
           CASE WHEN v_bad = '' THEN '無' ELSE v_bad END, v_state1, v_state2));
EXCEPTION WHEN OTHERS THEN
  EXECUTE 'RESET ROLE';
  INSERT INTO _t_result VALUES (15, '（⑧）權限', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t15$;


-- ----------------------------------------------------------------------------
-- 測 16／17：（⑧）用 authenticated 身分實際跑新程式 → 成功（SECURITY INVOKER 走得通）
--   ⚠️ authenticated 讀不到暫存表，id 先拿到變數裡、跑完 RESET ROLE 才寫結果
-- ----------------------------------------------------------------------------
DO $t16$
DECLARE
  v_pr  BIGINT := pg_temp._t_make_pr('p16', 'approved', 'submitted');
  v_loc BIGINT := pg_temp._t_id('loc');
  v_op  UUID := pg_temp._t_op();
  v_ids BIGINT[];
  v_err TEXT;
  v_got TEXT;
BEGIN
  BEGIN
    EXECUTE 'SET ROLE authenticated';
    v_ids := public.rpc_split_pr_to_pos_and_mark_sent(v_pr, v_loc, v_op);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT string_agg(status || '/' || COALESCE(sent_channel, '∅'), ',' ORDER BY id) INTO v_got
    FROM public.purchase_orders WHERE id = ANY (pg_temp._t_pos_of(v_pr));
  INSERT INTO _t_result VALUES (16,
    '（⑧）authenticated 身分實際按「建立採購單」新程式 → 成功、2 張都已發送',
    COALESCE(v_err IS NULL AND cardinality(v_ids) = 2 AND v_got = 'sent/manual,sent/manual', FALSE),
    format('錯誤=%s｜結果=%s', COALESCE(v_err, '無'), v_got));
EXCEPTION WHEN OTHERS THEN
  EXECUTE 'RESET ROLE';
  INSERT INTO _t_result VALUES (16, '（⑧）authenticated 建立採購單', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t16$;

DO $t17$
DECLARE
  v_so  BIGINT := pg_temp._t_make_stockout('r17');
  v_op  UUID := pg_temp._t_op();
  v_ret JSONB;
  v_err TEXT;
  v_got TEXT;
BEGIN
  BEGIN
    EXECUTE 'SET ROLE authenticated';
    v_ret := public.rpc_restore_stockout_po_and_mark_sent(v_so, v_op);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  SELECT status || '/' || COALESCE(sent_channel, '∅') INTO v_got FROM public.purchase_orders WHERE id = v_so;
  INSERT INTO _t_result VALUES (17,
    '（⑧）authenticated 身分實際按「回復斷貨」新程式 → 成功、已發送',
    COALESCE(v_err IS NULL AND v_ret ->> 'po_status' = 'sent' AND v_got = 'sent/manual'
             AND (SELECT status FROM public.customer_orders WHERE id = pg_temp._t_id('r17.o1')) = 'confirmed', FALSE),
    format('錯誤=%s｜回傳 po_status=%s｜採購單=%s', COALESCE(v_err, '無'), v_ret ->> 'po_status', v_got));
EXCEPTION WHEN OTHERS THEN
  EXECUTE 'RESET ROLE';
  INSERT INTO _t_result VALUES (17, '（⑧）authenticated 回復斷貨', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t17$;


-- ----------------------------------------------------------------------------
-- 測 18：函式屬性
-- ----------------------------------------------------------------------------
DO $t18$
DECLARE v_got TEXT;
BEGIN
  SELECT string_agg(format('%s(%s)->%s definer=%s config=%s mark=%s',
                           p.proname, pg_get_function_identity_arguments(p.oid), pg_get_function_result(p.oid),
                           p.prosecdef, p.proconfig, p.prosrc LIKE '%po_auto_mark_sent:20261002010000%'),
                    ' | ' ORDER BY p.proname)
    INTO v_got
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname IN ('rpc_split_pr_to_pos_and_mark_sent', 'rpc_restore_stockout_po_and_mark_sent');
  INSERT INTO _t_result VALUES (18,
    '函式屬性：SECURITY INVOKER、search_path=public、帶本檔記號、參數與回傳跟被包的那支一樣',
    COALESCE(v_got =
      'rpc_restore_stockout_po_and_mark_sent(p_po_id bigint, p_operator uuid)->jsonb definer=f config={search_path=public} mark=t'
      || ' | rpc_split_pr_to_pos_and_mark_sent(p_pr_id bigint, p_dest_location_id bigint, p_operator uuid)->bigint[] definer=f config={search_path=public} mark=t',
      FALSE),
    v_got);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO _t_result VALUES (18, '函式屬性', FALSE, 'EXCEPTION: ' || SQLERRM);
END
$t18$;


TABLE _t_result ORDER BY seq;

DO $$
DECLARE
  v_bad TEXT;
  v_n   INTEGER;
BEGIN
  SELECT string_agg(seq || ' ' || item || ' :: ' || detail, E'\n' ORDER BY seq)
    INTO v_bad
    FROM _t_result
   WHERE NOT pass OR pass IS NULL;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'po_auto_mark_sent_verification failed:%', E'\n' || v_bad;
  END IF;

  -- 結果必須剛好 19 條（測 0～18）；少一條就算失敗，防止某條測試被跳過還顯示綠
  SELECT COUNT(DISTINCT seq) INTO v_n FROM _t_result;
  IF v_n <> 19 OR (SELECT COUNT(*) FROM _t_result) <> 19 THEN
    RAISE EXCEPTION 'po_auto_mark_sent_verification：應該有 19 條結果（測 0～18），實際 % 條', v_n;
  END IF;

  RAISE NOTICE 'po_auto_mark_sent_verification: 19/19 PASS';
END $$;

ROLLBACK;
