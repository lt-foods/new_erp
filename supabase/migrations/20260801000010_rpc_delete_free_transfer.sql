-- ============================================================================
-- 2026-08-01: rpc_delete_free_transfer — 自由轉貨刪除（限 draft、實體硬刪、門市可自刪）
-- ----------------------------------------------------------------------------
-- 需求：店家建錯自由轉貨（store_to_store、MISC 虛擬 SKU + description + 估價）
--   要能自己刪掉。現況唯一的刪法是總倉收件匣的 rpc_transfer_batch_delete
--   （20260508000000），但該支完全沒有 role / tenant / 店別守門，
--   不適合開放給分店前台呼叫；分店頁（/wms/transfers）也沒有刪除入口。
--
-- 設計（守門順序，對齊 rpc_delete_restock_request 20260714000030 的門市放行做法）：
--   role 守門（HQ 職能 + 門市職能；空字串放行，對齊既有 restock RPC）→
--   not found / 跨 tenant → 非自由轉貨擋（type 非 store_to_store、綁訂單的
--   aid 接力單、有 next_transfer_id 鏈的一律不收）→ 門市角色限自己店
--   （source 或 dest 在 _jwt_store_location_ids() 內，見 20260707000070）→
--   非 draft 擋（HQ 配送後貨已在途，走拒收 / 收貨流程）→
--   撿貨波引用擋（draft 自由轉貨理論上不會有，防資料不一致的雙重保險）→
--   實體刪 transfers（transfer_items 為 ON DELETE CASCADE）。
--
-- 為何限 draft：自由轉貨由分店建立即為 draft，總倉收件匣配送
--   （rpc_transfer_distribute_batch）後轉 shipped 才有在途貨；draft 無任何
--   stock movement / 下游單據，硬刪安全。月結（20260715000120）只計
--   received/closed，draft 不入帳。
--
-- 本 function 為新建（無歷史版本；grep migrations 確認無同名）。
-- 基底慣例：rpc_delete_restock_request（20260714000030 門市守門）＋
--           rpc_transfer_batch_delete（20260508000000 僅 draft 可刪）。
-- 依賴：transfer_items.transfer_id ON DELETE CASCADE（20260422120003）；
--       picking_wave_items.generated_transfer_id 無 CASCADE（20260423120002）；
--       _jwt_store_location_ids()（20260707000070）。
-- Rollback：DROP FUNCTION public.rpc_delete_free_transfer(BIGINT);
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_delete_free_transfer(
  p_transfer_id BIGINT
) RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant UUID := public._current_tenant_id();
  v_role   TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_xfer   RECORD;
  v_waves  INTEGER;
BEGIN
  -- role 守門：HQ 職能 + 門市職能（空字串放行 — 對齊既有 restock RPC）
  IF v_role NOT IN ('owner','admin','hq_manager','store_manager','store_staff','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot delete free transfer', v_role;
  END IF;

  SELECT * INTO v_xfer FROM transfers
   WHERE id = p_transfer_id AND tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'transfer % not found', p_transfer_id;
  END IF;

  -- 只收自由轉貨：店↔店、無訂單 FK（綁訂單的是互助接力單）、無接力鏈
  IF v_xfer.transfer_type <> 'store_to_store'
     OR v_xfer.customer_order_id IS NOT NULL
     OR v_xfer.next_transfer_id IS NOT NULL THEN
    RAISE EXCEPTION 'transfer % is not a free transfer (type=%), cannot delete',
      p_transfer_id, v_xfer.transfer_type;
  END IF;

  -- 門市角色只能刪自己店參與的單（店名 claim → location，見 20260707000070）
  IF v_role IN ('store_manager','store_staff')
     AND NOT (v_xfer.source_location = ANY (public._jwt_store_location_ids())
              OR v_xfer.dest_location = ANY (public._jwt_store_location_ids())) THEN
    RAISE EXCEPTION 'store role can only delete free transfer involving own store';
  END IF;

  -- 守門 1：只有 draft 可刪 — 配送後貨已在途，走拒收 / 收貨流程
  IF v_xfer.status <> 'draft' THEN
    RAISE EXCEPTION 'transfer % is %, only draft can be deleted',
      p_transfer_id, v_xfer.status;
  END IF;

  -- 守門 2：雙重保險 — 已有撿貨波引用（自由轉貨不走 wave；防資料不一致）
  SELECT COUNT(*) INTO v_waves
    FROM picking_wave_items
   WHERE generated_transfer_id = p_transfer_id;
  IF v_waves > 0 THEN
    RAISE EXCEPTION 'transfer % already referenced by picking waves, cannot delete', p_transfer_id;
  END IF;

  -- 實體硬刪：transfer_items 為 ON DELETE CASCADE
  BEGIN
    DELETE FROM transfers
     WHERE id = p_transfer_id AND tenant_id = v_tenant;
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE EXCEPTION 'transfer % still referenced by other records, cannot delete', p_transfer_id;
  END;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_delete_free_transfer(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_delete_free_transfer(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_delete_free_transfer(BIGINT) IS
  '自由轉貨刪除（硬刪）：限 store_to_store 且無訂單 FK / 接力鏈的 draft；'
  'transfer_items 由 ON DELETE CASCADE 連帶刪；同 tenant；'
  'HQ 職能全刪、門市職能限自己店參與的單（_jwt_store_location_ids）。';
