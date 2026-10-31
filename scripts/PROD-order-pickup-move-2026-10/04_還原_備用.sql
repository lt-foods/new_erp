-- ============================================================================
--  04 還原（備用，✅ 會改資料）：把 02 改到中和的 4 張單，取貨店改回萬華
--  日期：2026-10-31　阿寫寫　⛔ 平常不用貼；要撤回 02 時才貼，貼前先問 CEO
-- ============================================================================
--  ★ 整份一個 DO 區塊＝同一次；任何一步不對就整筆退回、一張都沒改。
--    ① 先全部檢查：4 張都找得到、屬於這位會員（或合併編號）、取貨店是中和、備註有 02 那一句、
--       狀態仍是 待確認／已確認、品項全部「等貨中」且跟 10/31 確認的一樣、
--       沒有任何沒取消的派車單綁著這張單、02 之後沒有沒取消的派車單派往中和且含這些商品、
--       02 之後總倉撿貨單上沒有新排出中和這一團這商品那一列。萬華、中和店名各剛好 1 家。
--       （「02 之後」＝備註那一行寫的時間；那一行只記到分鐘，所以從那一分鐘開頭算起，寧可多擋。）
--    ② 取貨店改回萬華；備註再加一行「[改取貨店] 門市 #中和 → #萬華（時間）還原：撤回…」（不刪 02 那一行）。
--    ③ 自我驗算：剛好 4 張、除了 取貨店／備註／修改時間 以外整列不變、品項不變、沒改到別張單。
--  ★ 重貼：4 張都已經在萬華、備註最後一行是本次還原那句 → 顯示「已經還原過」，什麼都不改。
--  ★ 還原後再貼 02，可以再改回中和。
--  ★ 萬華已停業：還原只是把帳放回 02 之前的樣子，派貨需求會回到萬華那一家；要不要真的派貨由老闆決定。
-- ============================================================================

DO $pickup_restore$
DECLARE
  c_member_no CONSTANT text := 'M20260810082311747';
  c_tag       CONSTANT text := '萬華店停業，2026-10-31 老闆核准改中和取貨';           -- 02 寫的那一句，逐字相同
  c_undo      CONSTANT text := '還原：撤回 10/31 萬華改中和取貨';
  c_want      CONSTANT jsonb := '[
    {"order_no":"GRP-20261007-053-0030","sku_code":"G03109-01","qty":4},
    {"order_no":"GRP-20261007-063-0034","sku_code":"G03119-01","qty":1},
    {"order_no":"GRP-20261008-018-0038","sku_code":"G03131-03","qty":2},
    {"order_no":"GRP-20261011-043-0010","sku_code":"G03177-01","qty":12}
  ]';
  v_now       timestamptz := now();
  v_tenant    uuid;
  v_member    bigint;
  v_old       bigint;
  v_new       bigint;
  v_new_loc   bigint;
  v_cnt       int;
  v_nos       text[];
  v_ids       bigint[];
  v_at_old    int;
  v_at_new    int;
  v_moved_at  timestamptz;
  v_before    jsonb;
  v_items_b   jsonb;
  v_after     jsonb;
  v_items_a   jsonb;
  v_line      text;
  r           record;
BEGIN
  PERFORM set_config('lock_timeout', '15s', true);

  v_nos := ARRAY(SELECT DISTINCT e ->> 'order_no' FROM jsonb_array_elements(c_want) e ORDER BY 1);

  v_cnt := (SELECT count(*) FROM public.members WHERE member_no = c_member_no);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】會員編號 % 查到 % 位（要剛好 1 位）。什麼都沒改。', c_member_no, v_cnt;
  END IF;
  v_member := (SELECT id        FROM public.members WHERE member_no = c_member_no);
  v_tenant := (SELECT tenant_id FROM public.members WHERE id = v_member);

  v_cnt := (SELECT count(*) FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%萬華%');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】店名含「萬華」的店查到 % 家（要剛好 1 家）。什麼都沒改。', v_cnt;
  END IF;
  v_cnt := (SELECT count(*) FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%中和%');
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '【停】店名含「中和」的店查到 % 家（要剛好 1 家）。什麼都沒改。', v_cnt;
  END IF;
  v_old     := (SELECT id FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%萬華%');
  v_new     := (SELECT id FROM public.stores WHERE tenant_id = v_tenant AND name LIKE '%中和%');
  v_new_loc := (SELECT location_id FROM public.stores WHERE id = v_new);

  v_ids := ARRAY(
    SELECT co.id FROM public.customer_orders co
     WHERE co.tenant_id = v_tenant AND co.order_no = ANY (v_nos)
     ORDER BY co.id
       FOR UPDATE);
  IF coalesce(array_length(v_ids, 1), 0) <> array_length(v_nos, 1) THEN
    RAISE EXCEPTION '【停】% 張訂單只找到 % 張。什麼都沒改。', array_length(v_nos, 1), coalesce(array_length(v_ids, 1), 0);
  END IF;

  -- 重貼判斷
  v_at_old := (SELECT count(*) FROM public.customer_orders
                WHERE id = ANY (v_ids) AND pickup_store_id = v_old
                  AND right(coalesce(notes, ''), length(c_undo)) = c_undo);   -- 備註最後一行是本次還原那句
  IF v_at_old = array_length(v_ids, 1) THEN
    RAISE NOTICE '已經還原過：% 張都已經在萬華，這次什麼都沒改。', v_at_old;
    RETURN;
  END IF;
  v_at_new := (SELECT count(*) FROM public.customer_orders
                WHERE id = ANY (v_ids) AND pickup_store_id = v_new AND position(c_tag IN coalesce(notes, '')) > 0);
  IF v_at_new <> array_length(v_ids, 1) THEN
    RAISE EXCEPTION '【停】% 張裡只有 % 張是「02 改到中和」的狀態。什麼都沒改，請截圖給 CEO。',
      array_length(v_ids, 1), v_at_new;
  END IF;

  FOR r IN
    SELECT co.* FROM public.customer_orders co WHERE co.id = ANY (v_ids) ORDER BY co.order_no
  LOOP
    IF r.member_id IS NULL OR NOT EXISTS (
         SELECT 1 FROM public.members m
          WHERE m.id = r.member_id AND (m.id = v_member OR m.merged_into_member_id = v_member)) THEN
      RAISE EXCEPTION '【停】訂單 % 不是這位會員的。什麼都沒改。', r.order_no;
    END IF;
    IF r.status NOT IN ('pending', 'confirmed') THEN
      RAISE EXCEPTION '【停】訂單 % 狀態已經是 %，有人動過。什麼都沒改，改人工處理。', r.order_no, r.status;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.customer_order_items WHERE order_id = r.id)
       OR EXISTS (SELECT 1 FROM public.customer_order_items WHERE order_id = r.id AND status <> 'pending') THEN
      RAISE EXCEPTION '【停】訂單 % 的品項不是全部「等貨中」。什麼都沒改。', r.order_no;
    END IF;
    IF (SELECT string_agg((e ->> 'sku_code') || '×' || ((e ->> 'qty')::numeric)::numeric(18,1), '；'
                          ORDER BY e ->> 'sku_code', (e ->> 'qty')::numeric)
          FROM jsonb_array_elements(c_want) e WHERE e ->> 'order_no' = r.order_no)
       IS DISTINCT FROM
       (SELECT string_agg(s.sku_code || '×' || x.qty::numeric(18,1), '；' ORDER BY s.sku_code, x.qty)
          FROM public.customer_order_items x JOIN public.skus s ON s.id = x.sku_id
         WHERE x.order_id = r.id) THEN
      RAISE EXCEPTION '【停】訂單 % 的品項跟 10/31 確認的不一樣。什麼都沒改。', r.order_no;
    END IF;

    -- 02 那一行的時間（最後一次出現的那一行；只記到分鐘、台北時間）
    v_moved_at := (
      SELECT max((m[1] || ':00')::timestamp AT TIME ZONE 'Asia/Taipei')
        FROM regexp_matches(coalesce(r.notes, ''),
                            '（(\d{4}-\d{2}-\d{2} \d{2}:\d{2})）' || c_tag, 'g') AS m);
    IF v_moved_at IS NULL THEN
      RAISE EXCEPTION '【停】訂單 % 備註裡讀不到 02 那一行的時間。什麼都沒改，請截圖給 CEO。', r.order_no;
    END IF;

    IF EXISTS (
         SELECT 1 FROM public.transfers t
          WHERE t.tenant_id = r.tenant_id AND t.status <> 'cancelled'
            AND (t.customer_order_id = r.id
                 OR (t.dest_location = v_new_loc
                     AND t.created_at >= v_moved_at
                     AND EXISTS (SELECT 1 FROM public.transfer_items ti
                                  JOIN public.customer_order_items x ON x.sku_id = ti.sku_id AND x.order_id = r.id
                                 WHERE ti.transfer_id = t.id)))) THEN
      RAISE EXCEPTION '【停】訂單 % 在 02 之後已經有派往中和、含同商品的派車單（或綁這張單的派車單）。什麼都沒改，改人工處理。', r.order_no;
    END IF;
    IF EXISTS (
         SELECT 1 FROM public.picking_wave_items pwi
           JOIN public.picking_waves pw ON pw.id = pwi.wave_id AND pw.status <> 'cancelled'
           JOIN public.customer_order_items x ON x.sku_id = pwi.sku_id AND x.order_id = r.id
          WHERE pwi.tenant_id = r.tenant_id
            AND pwi.campaign_id = r.campaign_id
            AND pwi.store_id = v_new
            AND pwi.created_at >= v_moved_at) THEN
      RAISE EXCEPTION '【停】訂單 % 在 02 之後，總倉撿貨單已經排了中和這一團這商品。什麼都沒改，改人工處理。', r.order_no;
    END IF;
  END LOOP;

  v_before  := (SELECT jsonb_object_agg(id, to_jsonb(co) - 'pickup_store_id' - 'notes' - 'updated_at')
                  FROM public.customer_orders co WHERE id = ANY (v_ids));
  v_items_b := (SELECT jsonb_object_agg(id, to_jsonb(x))
                  FROM public.customer_order_items x WHERE order_id = ANY (v_ids));

  v_line := E'\n[改取貨店] 門市 #' || v_new || ' → #' || v_old
            || '（' || to_char(v_now AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') || '）' || c_undo;
  UPDATE public.customer_orders
     SET pickup_store_id = v_old,
         notes           = coalesce(notes, '') || v_line,
         updated_at      = v_now
   WHERE id = ANY (v_ids)
     AND pickup_store_id = v_new
     AND status IN ('pending', 'confirmed');
  GET DIAGNOSTICS v_cnt = ROW_COUNT;
  IF v_cnt <> array_length(v_ids, 1) THEN
    RAISE EXCEPTION '【停】只改到 % 張（要 % 張），整筆退回、什麼都沒改。', v_cnt, array_length(v_ids, 1);
  END IF;

  v_after   := (SELECT jsonb_object_agg(id, to_jsonb(co) - 'pickup_store_id' - 'notes' - 'updated_at')
                  FROM public.customer_orders co WHERE id = ANY (v_ids));
  v_items_a := (SELECT jsonb_object_agg(id, to_jsonb(x))
                  FROM public.customer_order_items x WHERE order_id = ANY (v_ids));
  IF v_after IS DISTINCT FROM v_before OR v_items_a IS DISTINCT FROM v_items_b THEN
    RAISE EXCEPTION '【停】驗算不過：除了取貨店／備註／修改時間還有別的變動。整筆退回。';
  END IF;
  v_cnt := (SELECT count(*) FROM public.customer_orders
             WHERE id = ANY (v_ids) AND pickup_store_id = v_old AND right(notes, length(v_line)) = v_line);
  IF v_cnt <> 4 THEN
    RAISE EXCEPTION '【停】驗算不過：改回萬華的只有 % 張（要剛好 4 張）。整筆退回。', v_cnt;
  END IF;
  v_cnt := (SELECT count(*) FROM public.customer_orders
             WHERE updated_at = v_now AND NOT (id = ANY (v_ids)) AND tenant_id = v_tenant);
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION '【停】驗算不過：這一刻還有 % 張別的單被改到。整筆退回。', v_cnt;
  END IF;

  RAISE NOTICE '完成：4 張訂單取貨店 中和 → 萬華（還原，備註已加一行）。';
END
$pickup_restore$;
