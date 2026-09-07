\set ON_ERROR_STOP on

-- 阿審用補充斷言：只能在本機測試庫跑。
-- 目的：抓 fixture 過度簡化、未載真函式、漏掉 reserved / p_allow_negative / 直接負異動旁路。

DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(x.name ORDER BY x.name)
    INTO v_missing
    FROM (
      VALUES
        ('locations'),
        ('stock_balances'),
        ('stock_movements'),
        ('transfers'),
        ('transfer_items'),
        ('products'),
        ('skus'),
        ('stores'),
        ('picking_waves'),
        ('picking_wave_items'),
        ('restock_requests'),
        ('restock_request_lines'),
        ('store_monthly_settlements')
    ) AS x(name)
   WHERE to_regclass('public.' || x.name) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'fixture 缺真 schema 表：%', array_to_string(v_missing, ', ');
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'stock_balances'
       AND column_name = 'reserved'
  ) THEN
    RAISE EXCEPTION 'stock_balances.reserved 不存在，無法驗待確認可派量';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger
     WHERE tgname = 'trg_apply_movement'
       AND tgrelid = 'public.stock_movements'::regclass
       AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'stock_movements 缺 trg_apply_movement，fixture 沒跑真庫存餘額機制';
  END IF;
END $$;

DO $$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.rpc_outbound(uuid,bigint,bigint,numeric,text,text,bigint,uuid,boolean,numeric)'::regprocedure)
    INTO v_def;

  IF v_def IS NULL THEN
    RAISE EXCEPTION '缺最新版 10 參數 rpc_outbound';
  END IF;

  IF position('on_hand - reserved' in v_def) = 0 THEN
    RAISE EXCEPTION 'rpc_outbound 沒有使用 on_hand - reserved，fixture 可能載到舊版或假版';
  END IF;

  IF position('p_allow_negative' in v_def) = 0 THEN
    RAISE EXCEPTION 'rpc_outbound 沒有 p_allow_negative，無法驗繞過 reserved 的旁路';
  END IF;
END $$;

DO $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(x.sig ORDER BY x.sig)
    INTO v_missing
    FROM (
      VALUES
        ('public.rpc_receive_transfer(bigint,jsonb,uuid,text,boolean)'),
        ('public.rpc_create_store_return(bigint,jsonb,text,uuid)'),
        ('public.rpc_resolve_transfer_item_shortage(bigint,text,text,uuid)'),
        ('public.rpc_undo_transfer_item_shortage(bigint,uuid,text)'),
        ('public.rpc_adjust_received_transfer(bigint,jsonb,uuid,text)'),
        ('public.rpc_unreceive_transfer(bigint,uuid,text)')
    ) AS x(sig)
   WHERE to_regprocedure(x.sig) IS NULL;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'fixture 缺真正最新版目標函式：%', array_to_string(v_missing, ', ');
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'transfer_items'
       AND column_name = 'shortage_return_transfer_id'
  ) THEN
    RAISE EXCEPTION '缺 shortage_return_transfer_id，無法驗短少沖帳/真回帳分流';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name = 'transfer_items'
       AND column_name = 'shortage_restock_movement_id'
  ) THEN
    RAISE EXCEPTION '缺 shortage_restock_movement_id，無法驗 restock_hq/redispatch 真回帳';
  END IF;
END $$;

DO $$
DECLARE
  v_candidate_tables text[];
BEGIN
  SELECT array_agg(c.relname ORDER BY c.relname)
    INTO v_candidate_tables
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relkind IN ('r','p')
     AND (
       c.relname ILIKE '%return%disposition%'
       OR c.relname ILIKE '%return%pending%'
       OR c.relname ILIKE '%disposition%'
     );

  IF v_candidate_tables IS NULL THEN
    RAISE EXCEPTION '找不到總倉退回貨待處理/處理明細表；若阿寫不用表，需在測試報告明確說明同等追蹤機制';
  END IF;
END $$;

-- 這裡不直接做雙 session；雙 session 必須由兩個 psql 連線測。
SELECT 'review_assertions_ok' AS result;
