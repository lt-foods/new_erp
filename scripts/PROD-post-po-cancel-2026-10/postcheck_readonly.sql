-- ============================================================================
-- 只查不改：20261016000000（派車照採購單數量：叫貨後才取消的件數照派原店）貼完後的確認
-- ----------------------------------------------------------------------------
-- 用法：貼完 migration 之後，整段貼上 → 按一次 Run → 看最後一列「總結」。
-- 整份只有一句查詢、一個分號；不寫資料、不鎖表，貼幾次都可以。
--
-- 怎麼看「結果」欄
--   ✅ 符合預期　❌ 不符合（請先貼 kill_switch 或 rollback，並通知工程師）
--   ⚠️ 派貨表的印法跟本機不同（內容對、只是資料庫版本的印法不一樣），不算錯
--   ℹ️ 只是給人看的數字，不判對錯
--
-- 如果整句跳錯、說找不到 _picking_po_rule_cutover 或 v_picking_po_rule_items
--   ＝ migration 那一步沒有貼成功。
--
-- 對正式庫的負擔（請看完再按）
--   第 13、14 列會把派貨工作台那張表「改前的算法」與「現在的算法」各算一次
--   （跟打開兩次派貨工作台差不多重）。請挑沒人在派貨、收貨的時候跑。
-- ============================================================================
WITH
fn AS (
  SELECT p.proname,
         string_agg(md5(replace(p.prosrc, chr(13), '')), ',' ORDER BY p.oid) AS sig,
         bool_and(position('post_po_cancel_to_store:20261016000000' IN p.prosrc) > 0) AS marked,
         string_agg(pg_get_function_identity_arguments(p.oid), ' | ' ORDER BY p.oid) AS args
    FROM pg_proc p
    JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname = 'public'
     AND p.proname IN ('rpc_create_wave_from_po', 'rpc_add_po_store_demands', '_picking_po_rule_cutover',
                       'rpc_preview_po_store_addition_extra', 'rpc_order_cancel_po_notice')
   GROUP BY p.proname
),
vinfo AS (
  SELECT x.n,
         to_regclass('public.' || x.n) AS oid,
         (SELECT c.relkind FROM pg_class c WHERE c.oid = to_regclass('public.' || x.n)) AS relkind,
         COALESCE(obj_description(to_regclass('public.' || x.n), 'pg_class'), '') AS note,
         pg_get_viewdef(to_regclass('public.' || x.n), true) AS def
    FROM (VALUES ('v_picking_demand_by_po'), ('v_picking_po_rule_items'), ('v_picking_post_po_cancelled')) AS x(n)
),
col AS (
  SELECT format_type(a.atttypid, a.atttypmod) AS typ,
         COALESCE(col_description(a.attrelid, a.attnum), '') AS note
    FROM pg_attribute a
   WHERE a.attrelid = to_regclass('public.purchase_request_store_additions')
     AND a.attname = 'po_delta_qty'
     AND a.attnum > 0
     AND NOT a.attisdropped
),
cutover AS (
  SELECT public._picking_po_rule_cutover() AS ts
),
old_v AS MATERIALIZED (
  -- 改前的派貨表：20260818000030:61-267 逐字（只拿來比，不改任何東西）
  SELECT * FROM (
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
        ), gr_qty AS (
         SELECT gri.po_item_id,
            sum(gri.qty_received) AS gr_qty
           FROM goods_receipt_items gri
             JOIN goods_receipts gr ON gr.id = gri.gr_id
          WHERE gr.status = 'confirmed'::text
          GROUP BY gri.po_item_id
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
        ), po_campaign_po AS (
         SELECT DISTINCT poi.po_id,
            pc0.campaign_id
           FROM po_campaigns pc0
             JOIN purchase_order_items poi ON poi.id = pc0.po_item_id
        ), campaign_demand AS (
         SELECT pc.po_item_id,
            co.pickup_store_id AS store_id,
            sum(coi.qty) AS demand_qty
           FROM po_campaigns pc
             JOIN customer_orders co ON co.campaign_id = pc.campaign_id AND (co.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text])) AND (co.transferred_from_order_id IS NULL OR (EXISTS ( SELECT 1
                   FROM customer_orders src
                  WHERE src.id = co.transferred_from_order_id AND src.pickup_store_id = co.pickup_store_id)))
             JOIN customer_order_items coi ON coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))
             JOIN purchase_order_items poi ON poi.id = pc.po_item_id AND poi.sku_id = coi.sku_id
          GROUP BY pc.po_item_id, co.pickup_store_id
        ), restock_demand AS (
         SELECT poi.id AS po_item_id,
            rr.requesting_store_id AS store_id,
            sum(rrl.qty) AS demand_qty
           FROM purchase_order_items poi
             JOIN purchase_request_items pri ON pri.po_item_id = poi.id
             JOIN restock_requests rr ON rr.linked_pr_id = pri.pr_id AND (rr.status <> ALL (ARRAY['cancelled'::text, 'rejected'::text]))
             JOIN restock_request_lines rrl ON rrl.request_id = rr.id AND rrl.sku_id = poi.sku_id
          GROUP BY poi.id, rr.requesting_store_id
        ), store_demand AS (
         SELECT u.po_item_id,
            u.store_id,
            sum(u.demand_qty) AS demand_qty
           FROM ( SELECT campaign_demand.po_item_id,
                    campaign_demand.store_id,
                    campaign_demand.demand_qty
                   FROM campaign_demand
                UNION ALL
                 SELECT restock_demand.po_item_id,
                    restock_demand.store_id,
                    restock_demand.demand_qty
                   FROM restock_demand) u
          GROUP BY u.po_item_id, u.store_id
        ), wave_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty) AS wave_qty
           FROM ( SELECT pw.source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_requested
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text
                UNION ALL
                 SELECT pcp.po_id AS source_po_id,
                    pwi.sku_id,
                    pwi.store_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                     JOIN po_campaign_po pcp ON pcp.campaign_id = pwi.campaign_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL AND pwi.campaign_id IS NOT NULL AND pcp.po_id <> pw.source_po_id AND NOT (EXISTS ( SELECT 1
                           FROM po_campaign_po own
                          WHERE own.po_id = pw.source_po_id AND own.campaign_id = pwi.campaign_id))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        ), po_sku_already_wave AS (
         SELECT u.po_id,
            u.sku_id,
            sum(u.qty) AS already_wave
           FROM ( SELECT pw.source_po_id AS po_id,
                    pwi.sku_id,
                    pwi.qty
                   FROM picking_wave_items pwi
                     JOIN picking_waves pw ON pw.id = pwi.wave_id
                  WHERE pw.status <> 'cancelled'::text AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id,
                    ti.sku_id,
                    ti.qty_requested AS qty
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND t.status <> 'cancelled'::text) u
          GROUP BY u.po_id, u.sku_id
        ), po_sku_demand_left AS (
         SELECT ps_1.po_id,
            ps_1.sku_id,
            sum(GREATEST(0::numeric, COALESCE(sd_1.demand_qty, 0::numeric) - COALESCE(wq_1.wave_qty, 0::numeric))) AS demand_left
           FROM po_skus ps_1
             JOIN store_demand sd_1 ON sd_1.po_item_id = ps_1.po_item_id
             LEFT JOIN wave_qty wq_1 ON wq_1.source_po_id = ps_1.po_id AND wq_1.sku_id = ps_1.sku_id AND wq_1.store_id = sd_1.store_id
          GROUP BY ps_1.po_id, ps_1.sku_id
        ), shipped_qty AS (
         SELECT u.source_po_id,
            u.sku_id,
            u.store_id,
            sum(u.qty_received) AS shipped_qty
           FROM ( SELECT pw.source_po_id,
                    ti.sku_id,
                    "substring"(t.transfer_no, 'WAVE-\d+-S(\d+)'::text)::bigint AS store_id,
                    ti.qty_received
                   FROM transfers t
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN picking_waves pw ON pw.id = ("substring"(t.transfer_no, '^WAVE-(\d+)-S'::text))::bigint
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text])) AND pw.source_po_id IS NOT NULL
                UNION ALL
                 SELECT poi.po_id AS source_po_id,
                    ti.sku_id,
                    rr.requesting_store_id AS store_id,
                    ti.qty_received
                   FROM restock_requests rr
                     JOIN transfers t ON t.id = rr.linked_transfer_id
                     JOIN transfer_items ti ON ti.transfer_id = t.id
                     JOIN purchase_request_items pri ON pri.pr_id = rr.linked_pr_id
                     JOIN purchase_order_items poi ON poi.id = pri.po_item_id AND poi.sku_id = ti.sku_id
                  WHERE t.transfer_type = 'hq_to_store'::text AND (t.status = ANY (ARRAY['received'::text, 'closed'::text]))) u
          GROUP BY u.source_po_id, u.sku_id, u.store_id
        )
 SELECT ps.tenant_id,
    ps.po_id,
    ps.po_no,
    ps.po_status,
    ps.supplier_id,
    ps.po_item_id,
    ps.sku_id,
    s.sku_code,
    COALESCE(s.product_name, ''::text) || COALESCE(' '::text || NULLIF(s.variant_name, ''::text), ''::text) AS sku_label,
    ps.qty_ordered,
    COALESCE(g.gr_qty, 0::numeric) AS gr_qty,
        CASE
            WHEN ps.po_status <> 'fully_received'::text THEN GREATEST(0::numeric, ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric))
            ELSE 0::numeric
        END AS qty_in_transit,
        CASE
            WHEN ps.po_status = 'fully_received'::text AND COALESCE(g.gr_qty, 0::numeric) < ps.qty_ordered THEN ps.qty_ordered - COALESCE(g.gr_qty, 0::numeric)
            ELSE 0::numeric
        END AS qty_shortage,
    sd.store_id,
    st.code AS store_code,
    st.name AS store_name,
    COALESCE(sd.demand_qty, 0::numeric) AS demand_qty,
    COALESCE(wq.wave_qty, 0::numeric) AS wave_qty,
    COALESCE(sq.shipped_qty, 0::numeric) AS shipped_qty,
    ps.is_restock_sourced,
    COALESCE(psaw.already_wave, 0::numeric) AS po_sku_already_wave,
    COALESCE(g.gr_qty, 0::numeric) > COALESCE(psaw.already_wave, 0::numeric) AS has_stock_left,
    COALESCE(dl.demand_left, 0::numeric) > 0::numeric AS has_demand_left
   FROM po_skus ps
     JOIN skus s ON s.id = ps.sku_id
     LEFT JOIN gr_qty g ON g.po_item_id = ps.po_item_id
     LEFT JOIN store_demand sd ON sd.po_item_id = ps.po_item_id
     LEFT JOIN stores st ON st.id = sd.store_id
     LEFT JOIN wave_qty wq ON wq.source_po_id = ps.po_id AND wq.sku_id = ps.sku_id AND wq.store_id = sd.store_id
     LEFT JOIN shipped_qty sq ON sq.source_po_id = ps.po_id AND sq.sku_id = ps.sku_id AND sq.store_id = sd.store_id
     LEFT JOIN po_sku_already_wave psaw ON psaw.po_id = ps.po_id AND psaw.sku_id = ps.sku_id
     LEFT JOIN po_sku_demand_left dl ON dl.po_id = ps.po_id AND dl.sku_id = ps.sku_id
  WHERE COALESCE(sq.shipped_qty, 0::numeric) < GREATEST(COALESCE(g.gr_qty, 0::numeric), 1::numeric) AND (COALESCE(g.gr_qty, 0::numeric) > 0::numeric OR COALESCE(sd.demand_qty, 0::numeric) > 0::numeric)
  ) o
),
new_v AS MATERIALIZED (
  SELECT * FROM public.v_picking_demand_by_po
),
only_new AS (
  SELECT * FROM new_v
  EXCEPT ALL
  SELECT * FROM old_v
),
only_old AS (
  SELECT * FROM old_v
  EXCEPT ALL
  SELECT * FROM new_v
),
rule AS (
  SELECT DISTINCT r.po_item_id FROM public.v_picking_po_rule_items r
),
diff AS (
  SELECT n.po_item_id FROM only_new n
  UNION ALL
  SELECT o.po_item_id FROM only_old o
),
diff_sum AS (
  SELECT count(*) AS n_all,
         count(*) FILTER (WHERE r.po_item_id IS NULL) AS n_outside,
         count(*) FILTER (WHERE r.po_item_id IS NOT NULL) AS n_inside
    FROM diff d
    LEFT JOIN rule r ON r.po_item_id = d.po_item_id
),
dup AS (
  SELECT count(*) AS n
    FROM (SELECT 1 FROM new_v GROUP BY po_item_id, store_id HAVING count(*) > 1) x
),
ppc_sum AS (
  SELECT count(*) AS n_rows,
         COALESCE(sum(p.qty) FILTER (WHERE p.store_active), 0) AS qty_active,
         COALESCE(sum(p.qty) FILTER (WHERE NOT p.store_active), 0) AS qty_inactive
    FROM public.v_picking_post_po_cancelled p
),
rule_sum AS (
  SELECT count(*) AS n FROM public.v_picking_po_rule_items
),
checks(seq, status, item, detail) AS (
  SELECT 1,
         CASE WHEN (SELECT f.marked FROM fn f WHERE f.proname = '_picking_po_rule_cutover') THEN '✅' ELSE '❌' END,
         '分界時間 _picking_po_rule_cutover() 是本檔建的',
         (SELECT CASE WHEN c.ts = 'infinity'::timestamptz THEN '目前：已一鍵關掉（infinity）'
                      ELSE '目前：' || to_char(c.ts AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '（台北）起成立的採購單品項套用' END
            FROM cutover c)
  UNION ALL
  SELECT 2,
         CASE WHEN (SELECT v.relkind = 'v' AND position('post_po_cancel_to_store:20261016000000' IN v.note) > 0
                      FROM vinfo v WHERE v.n = 'v_picking_po_rule_items') THEN '✅' ELSE '❌' END,
         '新 view v_picking_po_rule_items 在、而且是本檔的版本',
         (SELECT CASE WHEN v.oid IS NULL THEN '找不到' ELSE '在' END FROM vinfo v WHERE v.n = 'v_picking_po_rule_items')
  UNION ALL
  SELECT 3,
         CASE WHEN (SELECT v.relkind = 'v' AND position('post_po_cancel_to_store:20261016000000' IN v.note) > 0
                      FROM vinfo v WHERE v.n = 'v_picking_post_po_cancelled') THEN '✅' ELSE '❌' END,
         '新 view v_picking_post_po_cancelled 在、而且是本檔的版本',
         (SELECT CASE WHEN v.oid IS NULL THEN '找不到' ELSE '在' END FROM vinfo v WHERE v.n = 'v_picking_post_po_cancelled')
  UNION ALL
  SELECT 4,
         CASE WHEN (SELECT f.marked AND f.args = 'p_po_id bigint' FROM fn f
                     WHERE f.proname = 'rpc_preview_po_store_addition_extra') THEN '✅' ELSE '❌' END,
         '新查詢 rpc_preview_po_store_addition_extra(p_po_id) 在、而且是本檔的版本',
         COALESCE((SELECT f.args FROM fn f WHERE f.proname = 'rpc_preview_po_store_addition_extra'), '找不到')
  UNION ALL
  SELECT 5,
         CASE WHEN (SELECT f.marked AND f.args = 'p_order_id bigint, p_item_id bigint' FROM fn f
                     WHERE f.proname = 'rpc_order_cancel_po_notice') THEN '✅' ELSE '❌' END,
         '新查詢 rpc_order_cancel_po_notice(p_order_id, p_item_id) 在、而且是本檔的版本',
         COALESCE((SELECT f.args FROM fn f WHERE f.proname = 'rpc_order_cancel_po_notice'), '找不到')
  UNION ALL
  SELECT 6,
         CASE WHEN (SELECT c.typ = 'numeric(18,3)' AND position('post_po_cancel_to_store:20261016000000' IN c.note) > 0
                      FROM col c) THEN '✅' ELSE '❌' END,
         '分店加單紀錄表多了一欄 po_delta_qty（採購單實際加幾件）',
         COALESCE((SELECT c.typ FROM col c), '找不到這一欄')
  UNION ALL
  SELECT 7,
         (SELECT CASE WHEN v.def IS NULL THEN '❌'
                      WHEN md5(regexp_replace(v.def, '\s+', '', 'g')) = '6b8fd6c1912717b8aee2a948fed275e5' THEN '✅'
                      WHEN position('v_picking_post_po_cancelled' IN v.def) > 0
                       AND position('picked_qty' IN v.def) = 0 THEN '⚠️'
                      ELSE '❌' END
            FROM vinfo v WHERE v.n = 'v_picking_demand_by_po'),
         '派貨表 v_picking_demand_by_po 是本檔新版（8/18 版多一段、沒有 9/08 #917）',
         (SELECT CASE WHEN v.def IS NULL THEN '找不到'
                      WHEN position('v_picking_post_po_cancelled' IN v.def) = 0 THEN '沒有新的那一段（還是改前，或被別的版本蓋掉）'
                      ELSE 'md5 去空白 ' || md5(regexp_replace(v.def, '\s+', '', 'g')) END
            FROM vinfo v WHERE v.n = 'v_picking_demand_by_po')
  UNION ALL
  SELECT 8,
         CASE WHEN (SELECT f.sig FROM fn f WHERE f.proname = 'rpc_create_wave_from_po') = 'cb6be9654963d06a9a4e06ca12ca471a'
              THEN '✅' ELSE '❌' END,
         '建撿貨單 rpc_create_wave_from_po 是本檔新版',
         (SELECT CASE WHEN f.sig = 'cb6be9654963d06a9a4e06ca12ca471a' THEN '本檔新版'
                      WHEN f.sig = 'ea371af8434804c43a043334602f4205' THEN '還是改前那一版'
                      ELSE '不認得：' || COALESCE(f.sig, '找不到') END
            FROM (SELECT (SELECT f2.sig FROM fn f2 WHERE f2.proname = 'rpc_create_wave_from_po') AS sig) f)
  UNION ALL
  SELECT 9,
         CASE WHEN (SELECT f.sig FROM fn f WHERE f.proname = 'rpc_add_po_store_demands') = '87dfda93e5c1a54dc5ae8c8fd05dca44'
              THEN '✅' ELSE '❌' END,
         '分店追加寫入 rpc_add_po_store_demands 是本檔新版',
         (SELECT CASE WHEN f.sig = '87dfda93e5c1a54dc5ae8c8fd05dca44' THEN '本檔新版'
                      WHEN f.sig = '220befc9d94d5e1c0aab37f41b627612' THEN '還是改前那一版'
                      ELSE '不認得：' || COALESCE(f.sig, '找不到') END
            FROM (SELECT (SELECT f2.sig FROM fn f2 WHERE f2.proname = 'rpc_add_po_store_demands') AS sig) f)
  UNION ALL
  SELECT 10,
         CASE WHEN has_table_privilege('authenticated', 'public.v_picking_po_rule_items', 'SELECT')
               AND has_table_privilege('authenticated', 'public.v_picking_post_po_cancelled', 'SELECT')
               AND NOT has_table_privilege('anon', 'public.v_picking_po_rule_items', 'SELECT')
               AND NOT has_table_privilege('anon', 'public.v_picking_post_po_cancelled', 'SELECT')
               AND NOT has_table_privilege('public', 'public.v_picking_po_rule_items', 'SELECT')
               AND NOT has_table_privilege('public', 'public.v_picking_post_po_cancelled', 'SELECT')
              THEN '✅' ELSE '❌' END,
         '兩支新 view：只有登入後台的人讀得到（沒登入的、所有人共用的 PUBLIC 都讀不到）',
         ''
  UNION ALL
  SELECT 11,
         CASE WHEN has_function_privilege('authenticated', 'public.rpc_preview_po_store_addition_extra(bigint)', 'EXECUTE')
               AND has_function_privilege('authenticated', 'public.rpc_order_cancel_po_notice(bigint,bigint)', 'EXECUTE')
               AND NOT has_function_privilege('anon', 'public.rpc_preview_po_store_addition_extra(bigint)', 'EXECUTE')
               AND NOT has_function_privilege('anon', 'public.rpc_order_cancel_po_notice(bigint,bigint)', 'EXECUTE')
               AND NOT has_function_privilege('public', 'public.rpc_preview_po_store_addition_extra(bigint)', 'EXECUTE')
               AND NOT has_function_privilege('public', 'public.rpc_order_cancel_po_notice(bigint,bigint)', 'EXECUTE')
              THEN '✅' ELSE '❌' END,
         '兩支新查詢：只有登入後台的人能用',
         ''
  UNION ALL
  SELECT 12,
         CASE WHEN has_function_privilege('authenticated', 'public._picking_po_rule_cutover()', 'EXECUTE')
              THEN '✅' ELSE '❌' END,
         '登入後台的人能用分界時間（派貨表會用到它，用不了派貨工作台會整個讀不出來）',
         ''
  UNION ALL
  SELECT 13,
         CASE WHEN (SELECT d.n_outside FROM diff_sum d) = 0 THEN '✅' ELSE '❌' END,
         '舊數字不變：派貨表跟改前的算法逐列比，差異只能出現在「套新規則」的採購單品項（貼上當天應該 0 筆）',
         (SELECT '差異 ' || d.n_all || ' 列：套新規則的採購單品項 ' || d.n_inside || ' 列、其他 ' || d.n_outside || ' 列'
            FROM diff_sum d)
  UNION ALL
  SELECT 14,
         CASE WHEN (SELECT x.n FROM dup x) = 0 THEN '✅' ELSE '❌' END,
         '派貨表每個（採購單品項, 店）只有一列（不會重複算已撿／已派）',
         (SELECT x.n || ' 組重複' FROM dup x)
  UNION ALL
  SELECT 15,
         NULL,
         '現在套新規則的採購單品項、叫貨後才取消的件數',
         (SELECT r.n || ' 個（採購單品項, 團）；叫貨後取消 ' || p.n_rows || ' 列，照派原店 '
                 || trim_scale(p.qty_active) || ' 件、停用店留總倉 ' || trim_scale(p.qty_inactive) || ' 件'
            FROM rule_sum r, ppc_sum p)
)
SELECT c.seq AS "序",
       COALESCE(c.status, 'ℹ️') AS "結果",
       c.item AS "檢查項目",
       c.detail AS "內容"
  FROM checks c
UNION ALL
SELECT 99,
       CASE WHEN (SELECT bool_and(c.status IN ('✅', '⚠️')) FROM checks c WHERE c.seq BETWEEN 1 AND 14)
            THEN '✅' ELSE '❌' END,
       '總結（第 1～14 列全部 ✅ 或 ⚠️ 才算貼對）',
       ''
 ORDER BY 1;
