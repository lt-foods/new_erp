-- ============================================================
-- customer_orders.status: 加 CHECK constraint 鎖死合法值
--
-- 對齊 apps/admin/src/lib/orderStatus.ts ORDER_STATUSES (single source of truth)
-- 砍掉的 reserved / partially_ready / partially_completed / picked_up
-- 從未寫進 DB（生產確認 0 筆），不需 backfill。
--
-- 之前 status 是 free TEXT，導致：
--   - 各檔案 STATUS_LABEL 不一致（reserved/shipping/expired 翻譯歧義）
--   - 寫錯字串會悄悄混進去
--
-- 加完此 constraint 之後，新增 status 必須：
--   1. 改 ORDER_STATUSES tuple（lib/orderStatus.ts）
--   2. 寫一支 ALTER 改 CHECK
-- ============================================================

-- 防禦性：先檢查現有資料是否全在白名單內（理論應該都在）
DO $$
DECLARE
  v_bad_count INT;
  v_bad_samples TEXT;
BEGIN
  SELECT count(*), string_agg(DISTINCT status, ',')
    INTO v_bad_count, v_bad_samples
    FROM customer_orders
   WHERE status NOT IN (
     'pending','confirmed','ready','shipping',
     'completed','cancelled','transferred_out','expired'
   );
  IF v_bad_count > 0 THEN
    RAISE EXCEPTION 'cannot apply CHECK: % rows have status NOT IN whitelist (samples: %)',
      v_bad_count, v_bad_samples;
  END IF;
END $$;

-- 既有 customer_orders_status_check 涵蓋 11 個 status（含 reserved /
-- partially_ready / partially_completed 三個從未寫進 DB 的）；
-- DROP 重建為更窄的 8 個（對齊 lib/orderStatus.ts ORDER_STATUSES）
ALTER TABLE customer_orders DROP CONSTRAINT IF EXISTS customer_orders_status_check;

ALTER TABLE customer_orders
  ADD CONSTRAINT customer_orders_status_check
  CHECK (status IN (
    'pending','confirmed','ready','shipping',
    'completed','cancelled','transferred_out','expired'
  ));

COMMENT ON CONSTRAINT customer_orders_status_check ON customer_orders IS
  '對齊 apps/admin/src/lib/orderStatus.ts ORDER_STATUSES；新增 status 須同步改此 constraint + lib';
