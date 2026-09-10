-- ============================================================================
-- 一次性資料清理：刪除測試團 GRP-20260910-041「測試」（id 5051）
-- ============================================================================
-- 需求（Alex 2026-09-10）：「GRP-20260910-041 這個團刪除」。
--
-- ⚠ 這個團號今天被用了兩次：
--   - id 5050「中華一番・中式職人料理 350克+-10%test」—— #943
--     （20260910030000_move_orders_test_campaign_041_to_021）搬走訂單的那團，
--     套本檔時已經不在了（之前就被刪掉）。
--   - id 5051「測試」—— 18:57 開的 HQ 團，又拿到 041。本檔刪的是這一團。
--   同號重用的原因：團號取「當天現有最大流水號 + 1」（20260511000001 等），
--   當天最後一號被刪掉之後，下一個開的團會拿回同一號。
--
-- 5051 的狀態（套用前對正式庫查過）：open、0 訂單、0 商品、0 頻道／稽核／候補／
--   上傳紀錄；唯一掛著的是 LINE 記事本貼文 #290（⑦包子媽❤生鮮小舖(松山店)，
--   status=posted，但 line_post_id 是 NULL —— 發文時 LINE 沒回貼文 id）。
--   line-note-worker 的 delete_post 對沒有 line_post_id 的貼文一律回 noLinePost，
--   後台本來就刪不到 LINE 上那篇，所以跟著團一起 CASCADE 掉不會少掉任何補救手段；
--   LINE 上那篇要用發文帳號自己刪。
--
-- 為什麼不走 rpc_delete_campaign：它擋 open 的團；先把 status 改成 cancelled 再刪
--   會觸發 trg_line_note_on_campaign_open / trg_campaigns_lock_on_open（AFTER UPDATE
--   OF status）。這團沒有訂單、商品、稽核、上傳、候補，RPC 其餘的清理步驟全是空轉，
--   所以直接 DELETE 團頭；真的冒出別的參照時，FK（customer_order_sources 等沒有
--   CASCADE）或 append-only trigger（campaign_audit_log）會讓整支中止，不會刪一半。
--
-- 守衛（任一不成立就整支 RAISE，什麼都不刪）：
--   - id + campaign_no + name 三個都要對得上
--   - 沒有訂單、沒有商品、沒有訂單品項掛在它的商品上、沒有掛在它身上的庫存異動
--   - 記事本貼文只能是「沒有 line_post_id」的：有 id 代表後台刪得到 LINE 上那篇，
--     要先在開團的記事本彈窗刪（連 LINE 一起刪）再刪團，否則 CASCADE 之後就刪不到了
--
-- 備份：刪之前把團頭 + 所有 FK 指向它的列（含 CASCADE 下一層，例如記事本留言、
--   發文 job）以 jsonb 存進 public._backup_20260910_deleted_campaign_041
--   （RLS 開、anon/authenticated 無權限）。確認不需要還原後可直接 DROP TABLE。
--
-- 冪等：團已經不存在 → NOTICE 跳過（從零重跑時也走這條，不會建備份表）。
-- Rollback：依 src_table 從備份表 jsonb_populate_record 塞回去，順序
--   group_buy_campaigns → line_note_posts → line_note_comments；
--   line_note_jobs 只要把 post_id 補回（FK 是 ON DELETE SET NULL）。
-- ============================================================================

DO $$
DECLARE
  v_tenant CONSTANT UUID   := '00000000-0000-0000-0000-000000000001';
  v_id     CONSTANT BIGINT := 5051;
  v_no     CONSTANT TEXT   := 'GRP-20260910-041';
  v_found  BIGINT;
  v_cnt    INT;
  r        RECORD;
  r2       RECORD;
BEGIN
  SELECT id INTO v_found
    FROM group_buy_campaigns
   WHERE id = v_id AND tenant_id = v_tenant
     AND campaign_no = v_no AND name = '測試'
   FOR UPDATE;

  IF v_found IS NULL THEN
    RAISE NOTICE '[skip] 團 %（id %「測試」）不存在（已刪除）', v_no, v_id;
    RETURN;
  END IF;

  -- ── 守衛 ────────────────────────────────────────────────────────────────
  SELECT COUNT(*) INTO v_cnt FROM customer_orders WHERE campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 已經有 % 張訂單，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM campaign_items WHERE campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 已經有 % 個商品，中止（套用前查過是 0）', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM customer_order_items coi
    JOIN campaign_items ci ON ci.id = coi.campaign_item_id
   WHERE ci.campaign_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '還有 % 個訂單品項掛在團 % 的商品上，中止', v_cnt, v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM stock_movements
   WHERE source_doc_type = 'campaign' AND source_doc_id = v_id;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 身上掛著 % 筆庫存異動，中止', v_no, v_cnt;
  END IF;

  SELECT COUNT(*) INTO v_cnt
    FROM line_note_posts
   WHERE campaign_id = v_id AND line_post_id IS NOT NULL;
  IF v_cnt > 0 THEN
    RAISE EXCEPTION '團 % 有 % 篇記事本貼文後台刪得到（有 LINE 貼文 id），先到開團的記事本彈窗刪貼文再刪團',
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

  -- ── 刪除 ────────────────────────────────────────────────────────────────
  -- campaign_items / channels / 記事本貼文（→ 留言）由 FK CASCADE 帶走
  DELETE FROM group_buy_campaigns WHERE id = v_id AND tenant_id = v_tenant;

  IF EXISTS (SELECT 1 FROM group_buy_campaigns WHERE id = v_id) THEN
    RAISE EXCEPTION '刪除後團 % 還在，中止', v_no;
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM public._backup_20260910_deleted_campaign_041;
  RAISE NOTICE '完成：已刪除 %（id %「測試」），備份 % 列', v_no, v_id, v_cnt;
END $$;
