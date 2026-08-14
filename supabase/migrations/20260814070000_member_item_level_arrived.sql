-- ============================================================
-- 2026-08-14 (7)：會員端 items[] 加品項層級 arrived —— App 分頁要能依「行」分桶
--
-- 承 20260814060000（取貨閘門加數量守衛）。那一版只修好店員端：
--   /pickup 不再讓店員發出沒到的貨。但**會員 App 完全沒修到** ——
--   線上實測 80 張被守衛擋下的單，v_customer_order_summary.arrived
--   仍然 80/80 都是 true。
--
-- 原因是 arrived 有快路徑：
--   co.status IN ('reserved','ready','partially_ready','partially_completed','completed')
--   → 一律 true，閘門**只對 'shipping' 的單呼叫**。
-- 所以單頭一旦被推到 ready / partially_completed，會員端就無條件顯示到貨。
--
-- 災情面（GRP-20260805-006-0026 忠順）：客人訂 2 件、店只收 1 件、取走 1 件。
--   剩下那件根本沒到，但 App 上：
--     * 單頭寫「部分已取」（orderPhase 的 partially_completed 分支先短路，沒問 arrived）
--     * 行級 chip 寫「未取」（pickChip 只看品項 status，跟到貨無關）
--     * 未結 $139
--   合起來就是在跟客人說「還有一件在店裡等你拿」—— 客人照樣跑一趟撲空。
--
-- 修法：items[] jsonb 每一行加 'arrived'，讓前端能依**行**分桶
--   （未到貨的行 → 待到貨、已取的行 → 已完成），不再整張單擠在同一個分頁。
--
--   成本控制：只有 active 行（pending/reserved/ready）才呼叫閘門，
--   picked_up / cancelled / expired 一律回 NULL 不呼叫 —— 那些行的分桶
--   看 status 就決定了，沒必要付錢。實測最重的會員（407 張單 / 684 個品項、
--   其中 322 個 active）逐項跑閘門約 750ms，一般會員（144 單 / 204 品項）約 150ms。
--
--   單頭的 arrived 逐字不動（含快路徑）—— 它還有別的消費者，這一版只加不減。
--
-- 基底版本（append-only）：線上現行 v_customer_order_summary
--   （= 20260811000050_order_summary_campaign_no.sql 之後的累積版，
--     本檔以 pg_get_viewdef 實際 dump 為基底，逐字保留只加 'arrived' 一個 key）
--
-- Rollback：把 items 的 jsonb_build_object 裡
--   "'arrived', CASE WHEN ... END," 這一段拿掉再 CREATE OR REPLACE 即可。
-- ============================================================

CREATE OR REPLACE VIEW public.v_customer_order_summary AS
 SELECT co.id,
    co.tenant_id,
    co.order_no,
    co.member_id,
    co.pickup_store_id AS store_id,
    co.campaign_id,
    co.channel_id,
    co.status,
    co.payment_status,
    co.payment_method,
    co.paid_at,
    co.shipping_method,
    co.shipping_address,
    co.shipping_phone,
    co.shipping_note,
    co.remit_amount,
    co.remit_at,
    co.remit_note,
    co.shipping_fee,
    co.discount_amount,
    co.discount_percent,
    co.wallet_paid_amount,
    co.pickup_deadline,
    co.notes,
    co.created_at,
    co.confirmed_at,
    co.shipping_at,
    co.ready_at,
    co.completed_at,
    co.cancelled_at,
    co.stockout_at,
    agg.items_total,
    agg.unpicked_total,
    ret.returned_qty,
    ret.returned_deduction,
    GREATEST(0::numeric, round(GREATEST(0::numeric, agg.items_total - ret.returned_deduction) * (1::numeric - co.discount_percent / 100::numeric) + co.shipping_fee - co.discount_amount, 0)) AS payable_amount,
    GREATEST(0::numeric, GREATEST(0::numeric, round(GREATEST(0::numeric, agg.items_total - ret.returned_deduction) * (1::numeric - co.discount_percent / 100::numeric) + co.shipping_fee - co.discount_amount, 0)) - co.wallet_paid_amount) AS balance_due,
        CASE
            WHEN co.status = ANY (ARRAY['cancelled'::text, 'expired'::text, 'transferred_out'::text]) THEN 0::numeric
            WHEN agg.unpicked_total <= 0::numeric THEN 0::numeric
            ELSE GREATEST(0::numeric, GREATEST(0::numeric, round(GREATEST(0::numeric, agg.unpicked_total - ret.returned_deduction) * (1::numeric - co.discount_percent / 100::numeric) + co.shipping_fee - co.discount_amount, 0)) - co.wallet_paid_amount)
        END AS outstanding_amount,
    agg.items,
    (co.status = ANY (ARRAY['reserved'::text, 'ready'::text, 'partially_ready'::text, 'partially_completed'::text, 'completed'::text])) OR co.status = 'shipping'::text AND (EXISTS ( SELECT 1
           FROM customer_order_items coi
          WHERE coi.order_id = co.id AND (coi.status = ANY (ARRAY['pending'::text, 'reserved'::text, 'ready'::text])) AND is_order_item_pickup_ready(coi.id))) AS arrived,
    co.confirmed_at IS NOT NULL OR (co.status = ANY (ARRAY['reserved'::text, 'ready'::text, 'partially_ready'::text, 'partially_completed'::text, 'shipping'::text, 'completed'::text])) AS settled,
    co.payment_status = 'paid'::text AS paid,
    co.status = ANY (ARRAY['shipping'::text, 'completed'::text]) AS shipped,
    (('S-'::text || lpad(co.id::text, 8, '0'::text)) || '-'::text) || COALESCE(s.store_short_code, 'XX'::text) AS settlement_no,
    s.name AS store_name,
    s.code AS store_code,
    gbc.campaign_no,
    gbc.name AS campaign_name,
    gbc.cover_image_url AS campaign_cover_url,
    gbc.end_at AS campaign_end_at,
    gbc.cutoff_date AS campaign_cutoff_date
   FROM customer_orders co
     LEFT JOIN stores s ON s.id = co.pickup_store_id
     LEFT JOIN group_buy_campaigns gbc ON gbc.id = co.campaign_id
     LEFT JOIN LATERAL ( SELECT COALESCE(sum(coi.qty * coi.unit_price) FILTER (WHERE coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text])), 0::numeric) AS items_total,
            COALESCE(sum(coi.qty * coi.unit_price) FILTER (WHERE coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text, 'picked_up'::text])), 0::numeric) AS unpicked_total,
            COALESCE(jsonb_agg(jsonb_build_object('id', coi.id, 'sku_id', coi.sku_id, 'sku_code', sk.sku_code, 'product_name', sk.product_name, 'variant_name', sk.variant_name, 'campaign_item_id', coi.campaign_item_id, 'qty', coi.qty, 'unit_price', coi.unit_price, 'subtotal', coi.qty * coi.unit_price, 'status', coi.status, 'stockout', coi.stockout_at IS NOT NULL, 'arrived', CASE WHEN coi.status = ANY (ARRAY['pending'::text, 'reserved'::text, 'ready'::text]) THEN is_order_item_pickup_ready(coi.id) ELSE NULL::boolean END, 'notes', coi.notes, 'image_url',
                CASE
                    WHEN jsonb_typeof(p.images) = 'array'::text AND jsonb_array_length(p.images) > 0 THEN COALESCE((p.images -> 0) ->> 'url'::text, p.images ->> 0)
                    ELSE NULL::text
                END) ORDER BY coi.id), '[]'::jsonb) AS items
           FROM customer_order_items coi
             LEFT JOIN skus sk ON sk.id = coi.sku_id
             LEFT JOIN products p ON p.id = sk.product_id
          WHERE coi.order_id = co.id) agg ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(sum(a.alloc_qty), 0::numeric) AS returned_qty,
            COALESCE(sum(a.alloc_qty * a.unit_price), 0::numeric) AS returned_deduction
           FROM ( SELECT i.unit_price,
                    LEAST(i.qty, GREATEST(r.ret_qty - i.prior_qty, 0::numeric)) AS alloc_qty
                   FROM ( SELECT ti.sku_id,
                            sum(ti.qty_shipped) AS ret_qty
                           FROM transfers t
                             JOIN transfer_items ti ON ti.transfer_id = t.id
                          WHERE t.customer_order_id = co.id AND t.tenant_id = co.tenant_id AND t.transfer_type = 'return_to_hq'::text AND (t.status = ANY (ARRAY['shipped'::text, 'received'::text])) AND COALESCE("substring"(t.notes, '^\[order return([^\]:]*)'::text), ''::text) !~~ '%取貨後退回%'::text
                          GROUP BY ti.sku_id) r
                     JOIN ( SELECT coi.sku_id,
                            coi.qty,
                            coi.unit_price,
                            COALESCE(sum(coi.qty) OVER (PARTITION BY coi.sku_id ORDER BY coi.id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0::numeric) AS prior_qty
                           FROM customer_order_items coi
                          WHERE coi.order_id = co.id AND (coi.status <> ALL (ARRAY['cancelled'::text, 'expired'::text]))) i ON i.sku_id = r.sku_id) a) ret ON true;

GRANT SELECT ON public.v_customer_order_summary TO authenticated;
