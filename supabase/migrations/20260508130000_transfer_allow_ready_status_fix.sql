-- ============================================================================
-- 修正：上一個 migration 用了不存在的 'pickable'，實際 enum 是 'ready'。
-- 把 transfer RPC 守衛改成 pending/confirmed/reserved/ready。
-- ============================================================================

DO $$
DECLARE
  v_def TEXT;
BEGIN
  v_def := pg_get_functiondef(
    'rpc_transfer_order_to_store(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT)'::regprocedure
  );
  v_def := regexp_replace(
    v_def,
    'status NOT IN \(''pending'',''confirmed'',''reserved'',''pickable''\)',
    'status NOT IN (''pending'',''confirmed'',''reserved'',''ready'')',
    'g'
  );
  v_def := regexp_replace(
    v_def,
    'only pending/confirmed/reserved/pickable can be transferred',
    'only pending/confirmed/reserved/ready can be transferred',
    'g'
  );
  EXECUTE v_def;

  v_def := pg_get_functiondef(
    'rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN)'::regprocedure
  );
  v_def := regexp_replace(
    v_def,
    'status NOT IN \(''pending'',''confirmed'',''reserved'',''pickable''\)',
    'status NOT IN (''pending'',''confirmed'',''reserved'',''ready'')',
    'g'
  );
  v_def := regexp_replace(
    v_def,
    'only pending/confirmed/reserved/pickable can be transferred',
    'only pending/confirmed/reserved/ready can be transferred',
    'g'
  );
  EXECUTE v_def;
END$$;
