-- ============================================================================
-- 一次性資料清理：刪除測試團 GRP-20260910-041
-- ============================================================================
-- 需求（Alex 2026-09-10）：「GRP-20260910-041 這個團刪除」。
--   GRP-20260910-041「中華一番・中式職人料理 350克+-10%test」（id 5050）是 09-10 17:50
--   誤開的測試團，兩分鐘後整團取消（status='cancelled'）。底下唯一一張客人訂單已經在
--   20260910030000_move_orders_test_campaign_041_to_021（#943）搬到正式團
--   GRP-20260910-021，所以這團現在只剩一個沒有訂單的空殼。
--
-- 做法：直接呼叫既有的 rpc_delete_campaign（20260831000080 版），不另寫一套刪除 ——
--   守衛（非 open、沒有訂單）、append-only 表暫停保護、campaign_items / channels
--   由 CASCADE 帶走、殘參照轉成 FK 錯誤整支中止，都跟後台按「刪除」是同一條路。
--   pooler / Management API 連線沒有 JWT，_current_tenant_id() 會是 NULL，
--   所以在交易內灌 admin claims（set_config(..., true) 只活在這個交易）。
--
-- 本檔自己的守衛（任一不成立就整支 RAISE，什麼都不刪）：
--   - campaign_no + name 都要對得上、status 必須還是 cancelled
--   - 這團沒有任何 customer_orders（#943 之後應該是 0）
--   - 沒有任何訂單品項還掛在這團的 campaign_items 上（#943 已把品項改掛 021）
--   - LINE 記事本沒有這團的貼文紀錄：刪團會把 line_note_posts CASCADE 掉，
--     之後後台就刪不到 LINE 上那篇 —— 有的話先到開團的記事本彈窗刪貼文再來。
--
-- 備份：刪之前把團頭 + 所有 FK 指向它的列（含 CASCADE 下一層）以 jsonb 存進
--   public._backup_20260910_deleted_campaign_041（RLS 開、anon/authenticated 無權限）。
--   確認不需要還原後可直接 DROP TABLE。
--
-- 冪等：團已經不存在 → NOTICE 跳過（從零重跑時也走這條，不會建備份表）。
-- Rollback：依 src_table 從備份表 jsonb_populate_record 塞回去，順序
--   group_buy_campaigns → campaign_items / campaign_channels → 其餘。
-- ============================================================================

DO $$
DECLARE
  v_tenant CONSTANT UUID := '00000000-0000-0000-0000-000000000001';
  v_no     CONSTANT TEXT := 'GRP-20260910-041';
  v_id     BIGINT;
  v_status TEXT;
  v_cnt    INT;
  r        RECORD;
  r2       RECORD;
BEGIN
  SELECT id, status INTO v_id, v_status
    FROM group_buy_campaigns
   WHERE tenant_id = v_tenant AND campaign_no = v_no
     AND name = '中華一番・中式職人料理 350克+-10%test'
   FOR UPDATE;

  IF v_id IS NULL THEN
    RAISE NOTICE '[skip] 團 % 不存在（已刪除）', v_no;
    RETURN;
  END IF;
  IF v_status <> 'cancelled' THEN
    RAISE EXCEPTION '團 % 不是 cancelled（現在是 %），中止', v_no, v_status;
  END IF;

  -- ── 守衛 ────────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_cnt FROM customer_orders WHERE campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 還有 % 張訂單，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM customer_order_items coi
    JOIN campaign_items ci ON ci.id = coi.campaign_item_id
   WHERE ci.campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '還有 % 個訂單品項掛在團 % 的商品上，中止', v_cnt, v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM line_note_posts WHERE campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 在 LINE 記事本還有 % 篇貼文紀錄，先到開團的記事本彈窗把貼文刪掉再刪團',
                    v_no, v_cnt;
  END IF;

  -- ── 備份 ────────────────────────────────────────────────────────────────
  CREATE TABLE IF NOT EXISTS public._backup_20260910_deleted_campaign_041 (
    id           BIGSERIAL PRIMARY KEY,
    src_table    TEXT        NOT NULL,
    row_data     JSONB       NOT NULL,
    backed_up_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  ALTER TABLE public._backup_20260910_deleted_campaign_041 ENABLE ROW LEVEL SECURITY;
  REVOKE ALL ON public._backup_20260910_deleted_campaign_041 FROM anon, authenticated;
  REVOKE ALL ON SEQUENCE public._backup_20260910_deleted_campaign_041_id_seq FROM anon, authenticated;

  INSERT INTO public._backup_20260910_deleted_campaign_041 (src_table, row_data)
  SELECT 'group_buy_campaigns', to_jsonb(g) FROM group_buy_campaigns g WHERE g.id = v_id;

  -- 每一條指向 group_buy_campaigns 的 FK；CASCADE 的再往下一層
  FOR r IN
    SELECT con.conrelid AS rel, a.attname AS col, con.confdeltype AS deltype
      FROM pg_constraint con
      JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = con.conkey[1]
     WHERE con.contype = 'f'
       AND con.confrelid = 'public.group_buy_campaigns'::regclass
       AND array_length(con.conkey, 1) = 1
  LOOP
    EXECUTE format(
      'INSERT INTO public._backup_20260910_deleted_campaign_041 (src_table, row_data)
       SELECT %L, to_jsonb(t) FROM %s t WHERE t.%I = $1',
      r.rel::regclass::text, r.rel::regclass, r.col) USING v_id;

    CONTINUE WHEN r.deltype <> 'c';

    FOR r2 IN
      SELECT con2.conrelid AS rel, a2.attname AS col, af.attname AS ref_col
        FROM pg_constraint con2
        JOIN pg_attribute a2 ON a2.attrelid = con2.conrelid AND a2.attnum = con2.conkey[1]
        JOIN pg_attribute af ON af.attrelid = con2.confrelid AND af.attnum = con2.confkey[1]
       WHERE con2.contype = 'f'
         AND con2.confrelid = r.rel
         AND array_length(con2.conkey, 1) = 1
    LOOP
      EXECUTE format(
        'INSERT INTO public._backup_20260910_deleted_campaign_041 (src_table, row_data)
         SELECT %L, to_jsonb(g) FROM %s g
          WHERE g.%I IN (SELECT x.%I FROM %s x WHERE x.%I = $1)',
        r2.rel::regclass::text, r2.rel::regclass, r2.col,
        r2.ref_col, r.rel::regclass, r.col) USING v_id;
    END LOOP;
  END LOOP;

  -- ── 刪除：走後台「刪除」同一支 RPC ─────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object(
      'tenant_id', v_tenant,
      'role', 'authenticated',
      'app_metadata', json_build_object('tenant_id', v_tenant, 'role', 'admin')
    )::text,
    true);
  PERFORM public.rpc_delete_campaign(v_id, NULL::UUID);
  PERFORM set_config('request.jwt.claims', '', true);

  IF EXISTS (SELECT 1 FROM group_buy_campaigns WHERE id = v_id) THEN
    RAISE EXCEPTION '刪除後團 % 還在，中止', v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM public._backup_20260910_deleted_campaign_041;
  RAISE NOTICE '完成：已刪除 %（id %），備份 % 列', v_no, v_id, v_cnt;
END $$;
