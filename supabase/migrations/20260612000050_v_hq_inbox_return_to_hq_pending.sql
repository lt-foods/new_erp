-- ============================================================
-- v_hq_inbox: return_to_hq + status=shipped 算「待處理」不是「在途」
--
-- 之前 transfers 的 stage 只看 status,忽略了 transfer_type:
--   - hq_to_store + shipped → 對應店家收貨,從 HQ 看是「在途」 ✓
--   - return_to_hq + shipped → 店家寄回 HQ,從 HQ 看是「HQ 待收」,該是「待處理」
--
-- 同步影響 rpc_inbox_counts(tab 數字)。其他 source 不動。
-- ============================================================

CREATE OR REPLACE VIEW public.v_hq_inbox AS
SELECT
  'restock-' || id::text                                AS row_key,
  'restock'::text                                       AS source,
  CASE
    WHEN status = 'pending'                                                     THEN 'pending'
    WHEN status IN ('approved_transfer','approved_pr','shipped')                THEN 'in_transit'
    WHEN status = 'received'                                                    THEN 'done'
    ELSE 'rejected'
  END                                                   AS stage,
  requested_at                                          AS ts,
  id                                                    AS source_id
FROM public.restock_requests

UNION ALL

SELECT
  'transfer-' || id::text,
  'transfer',
  CASE
    WHEN status IN ('draft','confirmed')                       THEN 'pending'
    WHEN status = 'shipped' AND transfer_type = 'return_to_hq' THEN 'pending'   -- ← 新增
    WHEN status = 'shipped'                                    THEN 'in_transit'
    WHEN status = 'received'                                   THEN 'done'
    ELSE 'rejected'
  END,
  created_at,
  id
FROM public.transfers

UNION ALL

SELECT
  'aid-' || co.id::text,
  'aid',
  CASE
    WHEN co.status IN ('pending','confirmed')                     THEN 'pending'
    WHEN co.status = 'shipping'                                   THEN 'in_transit'
    WHEN co.status IN ('ready','completed','partially_completed') THEN 'done'
    ELSE 'rejected'
  END,
  co.updated_at,
  co.id
FROM public.customer_orders co
WHERE EXISTS (
  SELECT 1 FROM public.customer_order_items coi
  WHERE coi.order_id = co.id AND coi.source = 'aid_transfer'
)

UNION ALL

SELECT DISTINCT
  'shortage-' || order_id::text,
  'shortage',
  CASE
    WHEN shortage_resolution IS NULL                              THEN 'pending'
    WHEN shortage_resolution IN ('notified','waiting_next_po')    THEN 'in_transit'
    WHEN shortage_resolution IN ('cancelled','reallocated')       THEN 'done'
    ELSE 'pending'
  END,
  order_updated_at,
  order_id
FROM public.v_order_shortage;
