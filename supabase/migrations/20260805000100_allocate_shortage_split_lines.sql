-- ============================================================
-- 少發配貨支援拆行：一筆訂單可以「部分配到、部分待補」
--
-- 動機：20260805000060 的配貨是整行為單位，一筆 3 件的訂單為了補 1 件的缺口
--   就整行被擋，回頭配貨因此標了 212 件、實際缺口只有 185 件。
--
-- 做法：沿用這個 codebase 既有的「拆列」慣例 —— rpc_record_pickup 部分取貨時
--   就是把 customer_order_items 拆成 picked_up 行 + 殘行
--   （20260801000000:755 起）。配貨照做：一筆 3 件只配到 2 件時，
--   原行改成 2（可取），另插一行 1（backorder_at 有值）。
--
--   這樣取貨閘門、rpc_record_pickup、取貨頁全部不用改 —— 它們看到的永遠是
--   「整行可取」或「整行待補」，跟改成數量比較相比少掉一整圈迴歸風險。
--   line-level 折扣按數量比例分攤，兩行小計加總 = 原行（與拆行取貨同一套算法）。
--
-- p_allocations 從 BIGINT[] 換成 jsonb {"<item_id>": <配到的數量>}，
--   所以是 DROP + CREATE（參數型別變了，CREATE OR REPLACE 只會多一個 overload）。
--
-- 基底版本：20260805000060_shortage_allocation 的 rpc_allocate_shortage
-- rollback: DROP FUNCTION IF EXISTS public.rpc_allocate_shortage(bigint,bigint,jsonb,uuid);
--           並重跑 20260805000060 的 rpc_allocate_shortage。
-- ============================================================

DROP FUNCTION IF EXISTS public.rpc_allocate_shortage(BIGINT, BIGINT, BIGINT[], UUID);

CREATE OR REPLACE FUNCTION public.rpc_allocate_shortage(
  p_transfer_id BIGINT,
  p_sku_id      BIGINT,
  p_allocations jsonb,     -- {"<order_item_id>": <配到的數量>}；沒列到的視為 0
  p_operator    UUID
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_ctx        RECORD;
  r            RECORD;
  v_alloc      NUMERIC;
  v_freed      INT := 0;
  v_blocked    INT := 0;
  v_split      INT := 0;
  v_new_disc   NUMERIC;
BEGIN
  SELECT pwi.tenant_id, pwi.campaign_id, pwi.store_id, pwi.sku_id
    INTO v_ctx
    FROM picking_wave_items pwi
   WHERE pwi.generated_transfer_id = p_transfer_id
     AND pwi.sku_id = p_sku_id
     AND pwi.campaign_id IS NOT NULL
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION '這張派貨單的該品項查不到對應的撿貨波次（可能是補貨或自由轉貨），無法配貨';
  END IF;

  FOR r IN
    SELECT coi.id, coi.qty, coi.tenant_id, coi.order_id, coi.campaign_item_id,
           coi.sku_id, coi.unit_price, coi.status, coi.source, coi.notes,
           coi.discount_amount, coi.discount_percent, coi.backorder_at
      FROM customer_orders co
      JOIN customer_order_items coi ON coi.order_id = co.id AND coi.sku_id = v_ctx.sku_id
     WHERE co.tenant_id       = v_ctx.tenant_id
       AND co.campaign_id     = v_ctx.campaign_id
       AND co.pickup_store_id = v_ctx.store_id
       AND co.status NOT IN ('cancelled', 'expired', 'transferred_out')
       AND co.transferred_from_order_id IS NULL
       AND (co.order_kind = 'normal' OR co.order_kind IS NULL)
       AND coi.status IN ('pending', 'reserved', 'ready')
     ORDER BY coi.id
     FOR UPDATE OF coi
  LOOP
    v_alloc := COALESCE((p_allocations ->> r.id::text)::numeric, 0);
    v_alloc := GREATEST(LEAST(v_alloc, r.qty), 0);

    IF v_alloc >= r.qty THEN
      -- 全部配到：解除待補貨
      IF r.backorder_at IS NOT NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NULL, backorder_by = NULL,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_freed := v_freed + 1;
      END IF;

    ELSIF v_alloc <= 0 THEN
      -- 完全沒配到：整行待補貨
      IF r.backorder_at IS NULL THEN
        UPDATE customer_order_items
           SET backorder_at = NOW(), backorder_by = p_operator,
               updated_by = p_operator, updated_at = NOW()
         WHERE id = r.id;
        v_blocked := v_blocked + 1;
      END IF;

    ELSE
      -- 部分配到 → 拆行：原行留可取的量，另開一行掛待補貨
      -- 折扣按數量比例分攤（與 rpc_record_pickup 拆行同一套算法）
      v_new_disc := COALESCE(r.discount_amount, 0)
                    - round(COALESCE(r.discount_amount, 0) * v_alloc / r.qty);

      INSERT INTO customer_order_items (
        tenant_id, order_id, campaign_item_id, sku_id, qty, unit_price,
        status, source, notes, discount_amount, discount_percent,
        backorder_at, backorder_by,
        created_by, updated_by, created_at, updated_at
      ) VALUES (
        r.tenant_id, r.order_id, r.campaign_item_id, r.sku_id, r.qty - v_alloc, r.unit_price,
        r.status, r.source, r.notes, v_new_disc, r.discount_percent,
        NOW(), p_operator,
        p_operator, p_operator, NOW(), NOW()
      );

      UPDATE customer_order_items
         SET qty = v_alloc,
             discount_amount = COALESCE(r.discount_amount, 0)
                               - v_new_disc,
             backorder_at = NULL,
             backorder_by = NULL,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE id = r.id;

      v_split := v_split + 1;
      v_blocked := v_blocked + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('freed', v_freed, 'backordered', v_blocked, 'split', v_split);
END;
$$;

COMMENT ON FUNCTION public.rpc_allocate_shortage(BIGINT, BIGINT, jsonb, UUID) IS
  '少發配貨：p_allocations={"<order_item_id>":<配到的數量>}。'
  '部分配到時把 customer_order_items 拆成「可取行 + 待補行」，'
  '取貨閘門與 rpc_record_pickup 因此不必改（它們看到的永遠是整行可取或整行待補）。';

REVOKE ALL ON FUNCTION public.rpc_allocate_shortage(BIGINT, BIGINT, jsonb, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_allocate_shortage(BIGINT, BIGINT, jsonb, UUID) TO authenticated;
