-- ============================================================
-- 2026-10-02: 會員端「未結金額」—— 已扣儲值金不能在每一批取貨都再抵一次
--
-- 症狀（2026-10-01 古華 小倩回報「同品項分批領、用儲值金結帳，每次都會重複扣儲值金」）：
--   GRP-20260917-023-0007 黃淑惠 白斬雞 6 隻半 × $456，分 4 批領。
--   第 3 批用儲值金扣 $79（餘額歸 0），第 4 批取 1 隻 $456 時，結帳視窗 / 取貨單 /
--   會員端未結金額全部把那 $79 再抵一次 → 「應付 $377」。餘額其實早就 0。
--   同款：文山 GRP-20260926-010-0031 少收 $58、永和 GRP-20260810-015-0020 少收 $632。
--
-- 根因：customer_orders.wallet_paid_amount 是整張單**累計**扣過的儲值金，
--   outstanding_amount 卻寫成「未取品項應收 − 整個 wallet_paid_amount」——
--   前幾批取貨時已經被那些品項用掉的錢，在每一批都再抵一次。
--
-- 修法：outstanding_amount = LEAST(未取品項應收, balance_due)
--   balance_due（= 整單應收 − 已扣）本來就是「整張單還欠多少」，未結不可能比它多；
--   也不可能比「還沒領走的貨」多。兩者取小等價於
--     未取應收 − max(0, 已扣 − 已取品項應收)
--   即只抵「還沒被已取品項用掉」的那部分儲值金。
--   整張單一次取完 / 還沒取過任何品項：已取應收 = 0 → 跟舊算法一樣。
--   先用儲值金付清再分批取：balance_due = 0 → 一路 0，跟舊算法一樣。
--   只有「分批取、中途才扣儲值金」才會變：少抵掉前幾批已用掉的部分。
--
-- 前端同一條規則（同一個 PR）：apps/admin/src/lib/walletCredit.ts
--   PickupDialog（結帳視窗）、/pickup 一次全取、/pickup/print（取貨單）、
--   /pickup/print-list（小白單）。
--
-- payable_amount / balance_due / 其餘欄位逐字不動。
--
-- 基底版本（append-only）：線上現行 v_customer_order_summary
--   （2026-10-01 以 pg_get_viewdef 實際 dump，與 20260814070000_member_item_level_arrived.sql
--     逐字一致），本檔只改 outstanding_amount 的 ELSE 分支。
-- Rollback：重跑 20260814070000 的 CREATE OR REPLACE VIEW。
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
            -- 20261002010000：未取品項應收，但不超過整張單的 balance_due。
            -- 已扣儲值金是整張單累計的，先被已取品項用掉的部分不能再抵未取品項
            -- （舊式「未取應收 − 整個 wallet_paid_amount」會把前幾批扣過的錢再抵一次）。
            ELSE LEAST(
                   GREATEST(0::numeric, round(GREATEST(0::numeric, agg.unpicked_total - ret.returned_deduction) * (1::numeric - co.discount_percent / 100::numeric) + co.shipping_fee - co.discount_amount, 0)),
                   GREATEST(0::numeric, GREATEST(0::numeric, round(GREATEST(0::numeric, agg.items_total - ret.returned_deduction) * (1::numeric - co.discount_percent / 100::numeric) + co.shipping_fee - co.discount_amount, 0)) - co.wallet_paid_amount)
                 )
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
            COALESCE(jsonb_agg(jsonb_build_object('id', coi.id, 'sku_id', coi.sku_id, 'sku_code', sk.sku_code, 'product_name', sk.product_name, 'variant_name', sk.variant_name, 'campaign_item_id', coi.campaign_item_id, 'qty', coi.qty, 'unit_price', coi.unit_price, 'subtotal', coi.qty * coi.unit_price, 'status', coi.status, 'stockout', coi.stockout_at IS NOT NULL, 'arrived',
                CASE
                    WHEN coi.status = ANY (ARRAY['pending'::text, 'reserved'::text, 'ready'::text]) THEN is_order_item_pickup_ready(coi.id)
                    ELSE NULL::boolean
                END, 'notes', coi.notes, 'image_url',
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
