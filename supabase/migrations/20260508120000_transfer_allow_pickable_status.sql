-- ============================================================================
-- 放寬轉單 RPC 守衛：允許 status='pickable' 的訂單轉單
--
-- 原本 rpc_transfer_order_to_store / rpc_transfer_order_partial 限制 source 訂單
-- 必須是 pending / confirmed / reserved。實務上「商品已到店、客戶還沒取」
-- (status='pickable') 也常需要轉單（換取貨人 / 換取貨店）。
--
-- 改用 pg_get_functiondef + regexp_replace 動態替換守衛，避免重貼長函式 body。
-- ============================================================================

DO $$
DECLARE
  v_def TEXT;
BEGIN
  -- 整單轉店
  v_def := pg_get_functiondef(
    'rpc_transfer_order_to_store(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT)'::regprocedure
  );
  v_def := regexp_replace(
    v_def,
    'status NOT IN \(''pending'',''confirmed'',''reserved''\)',
    'status NOT IN (''pending'',''confirmed'',''reserved'',''pickable'')',
    'g'
  );
  v_def := regexp_replace(
    v_def,
    'only pending/confirmed/reserved can be transferred',
    'only pending/confirmed/reserved/pickable can be transferred',
    'g'
  );
  EXECUTE v_def;

  -- 拆單（partial）
  v_def := pg_get_functiondef(
    'rpc_transfer_order_partial(BIGINT, BIGINT, BIGINT, BIGINT, UUID, TEXT, JSONB, BOOLEAN)'::regprocedure
  );
  v_def := regexp_replace(
    v_def,
    'status NOT IN \(''pending'',''confirmed'',''reserved''\)',
    'status NOT IN (''pending'',''confirmed'',''reserved'',''pickable'')',
    'g'
  );
  v_def := regexp_replace(
    v_def,
    'only pending/confirmed/reserved can be transferred',
    'only pending/confirmed/reserved/pickable can be transferred',
    'g'
  );
  EXECUTE v_def;
END$$;
