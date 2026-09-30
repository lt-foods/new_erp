-- ============================================================================
-- 請購單草稿「同步最新開團數量」（精簡版）
--
-- 解決的問題
--   客人取消訂單後，請購單草稿還停在舊數字，沒有任何入口讓它往下修。
--   ⚠️ 只有「純取消不會往下修」這半是 bug。
--      「原本 10、取消 1、再加 2 → 11」**11 才是正確答案**，那半沒有壞：
--      需求 11、已請購 10、正差額 1 ⇒ 補 1 變 11。變 12 才是多叫一件。
--      出處：`★主檔_NEW-ERP出貨鏈.md` 現場紀錄、
--            `需求暨實作計畫_NEWERP取消訂單同步請購草稿數量_2026-09-30.md`:56、:203，
--            兩邊都寫 11。
--   附帶：草稿改數量跳紅字（item_qty / detail_qty 不一致）也一起收乾淨。
--
-- 根因
--   既有的 `_pr_campaign_sku_remaining_rows` 算得出負差額（需求 9、已請購 10 → -1），
--   但**所有補單入口都 `WHERE delta_qty > 0`**，負差額一路被丟掉 ——
--   全站沒有任何入口會把草稿往下修。
--   ⇒ 所以本檔要做的只有一件事：**加一個不過濾正負的新入口**。
--     那支共用 helper 一個字都不用改。
--
-- 本檔的範圍（刻意縮到最小：沒有測試庫，貼下去就是第一次真的執行）
--   🔒 **100% 只新增，不碰任何既有物件。**
--      6 支函式全部是新名字；0 張表、0 個索引、0 條 policy、0 個觸發器、0 個 ALTER、
--      0 個 CREATE OR REPLACE 打在既有函式上。
--   ⛔ 不碰 rpc_split_pr_to_pos / rpc_merge_prs_to_po / rpc_submit_pr /
--      rpc_delete_pr / rpc_create_partial_pr_from_items / rpc_add_pr_store_demands。
--   ⛔ 不加任何觸發器，不建待同步表，不拆 #982 防重守衛，不批次洗歷史資料。
--   ⛔ **不改 `_pr_campaign_sku_remaining_rows`**（現行唯一版本 20260921001000:240）——
--      只當唯讀依賴。2026-10-01 CEO 更正：計畫原本寫「唯一例外是那支共用零件」是寫錯的，
--      歸零既然交給斷貨流程，那個 LEFT JOIN → FULL OUTER JOIN 就用不到了
--      （需求 > 0 時舊版本來就回得到負差額）。少動它 = 少掉 8 個呼叫點的風險。
--
--   🪓 2026-10-01 老闆裁示「砍到最小」，以下三樣**刻意不做**（不是忘了）：
--     ⛔ 不建追溯紀錄表（purchase_request_qty_sync_log）——
--        這案子的起點只是一行紅字，不需要自己的帳本；誰改了什麼看
--        purchase_request_items.updated_by / updated_at。
--     ⛔ 不自己加 (團, 商品) 的 advisory lock —— 只有總部一個人在用，
--        而且 #982 守衛在觸發器裡本來就有鎖並重算一次，最壞情況是跳錯誤重按一次。
--        詳細理由寫在 _pr_apply_qty_sync 裡「刻意不加鎖」那段。
--     ⛔ 沒有 p_request_key 參數 —— 它原本只是寫給那張紀錄表的，表拿掉就沒有用途，
--        留一個什麼都不做的參數比沒有更糟。
--     ⛔ 不改共用 helper（理由見上方「本檔的範圍」最後一條）。
--
-- 寫入順序（反了會被 #982 守衛當場退回）
--   來源團明細 purchase_request_item_campaigns
--     → 請購品項總數 purchase_request_items.qty_requested
--       → 請購單總金額 purchase_requests.total_amount
--   理由：`trg_pri_cross_close_date_duplicate_guard` 在品項有綁明細時，
--   要求「品項總數 = 明細加總」完全相等（20260921001000:543-550）。
--
-- 需求歸零怎麼處理（2026-10-01 老闆裁示，已定案）
--   原話：「需求歸零跟這個功能無關，沒有需求我就用斷貨處理就好」。
--   ⇒ **本功能不處理需求歸零**，歸零由斷貨流程處理。
--   ⇒ 本檔的做法：歸零的列不動它，歸類為「需人工確認」並附原因，
--      不刪列、不改成 0、不偷偷跳過不講。
--      刪列會讓 9/23 分店加單紀錄 `purchase_request_store_additions.pr_item_id`
--      追不回來，所以也不刪。
--   （資料庫層本來也擋著：`purchase_request_items.qty_requested` 與
--     `purchase_request_item_campaigns.qty_requested` 兩欄都有
--     `CHECK (qty_requested > 0)`（20260422120004:135、20260921001000:34），
--     從建表到今天沒有任何 migration 拿掉過。）
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前
--    這份 SQL 是貼進 SQL Editor 執行的（autocommit、沒有交易保護），
--    所以前提不成立時要在「還沒動任何東西」的階段就停下來。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- 依賴的既有表
  IF to_regclass('public.purchase_requests') IS NULL THEN
    v_missing := v_missing || 'table public.purchase_requests';
  END IF;
  IF to_regclass('public.purchase_request_items') IS NULL THEN
    v_missing := v_missing || 'table public.purchase_request_items';
  END IF;
  IF to_regclass('public.purchase_request_item_campaigns') IS NULL THEN
    v_missing := v_missing || 'table public.purchase_request_item_campaigns (#982, 20260921001000)';
  END IF;
  IF to_regclass('public.group_buy_campaigns') IS NULL THEN
    v_missing := v_missing || 'table public.group_buy_campaigns';
  END IF;
  IF to_regclass('public.skus') IS NULL THEN
    v_missing := v_missing || 'table public.skus';
  END IF;

  -- 依賴的既有函式（⚠️ 本檔**只讀不改**它們，這裡是確認相依在不在，不是驗版本）
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = '_current_tenant_id'
  ) THEN
    v_missing := v_missing || 'function public._current_tenant_id()';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = '_pr_campaign_sku_remaining_rows'
       AND pg_get_function_identity_arguments(p.oid) = 'p_campaign_ids bigint[]'
  ) THEN
    v_missing := v_missing || 'function public._pr_campaign_sku_remaining_rows(bigint[])';
  END IF;

  -- #982 三個防重守衛必須在（本檔不動它們，但同步後的數字要通得過它們）
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname = 'trg_pri_cross_close_date_duplicate_guard'
  ) THEN
    v_missing := v_missing || 'trigger trg_pri_cross_close_date_duplicate_guard (#982)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname = 'trg_pric_cross_close_date_duplicate_guard'
  ) THEN
    v_missing := v_missing || 'trigger trg_pric_cross_close_date_duplicate_guard (#982)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE NOT tgisinternal
       AND tgname = 'trg_prc_cross_close_date_duplicate_guard'
  ) THEN
    v_missing := v_missing || 'trigger trg_prc_cross_close_date_duplicate_guard (#982)';
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%',
      array_to_string(v_missing, E'\n');
  END IF;
END
$precheck$;


-- 前置檢查（二）：把「數量不可為 0」這件事講明白。
-- 不是擋執行，是在 log 留一行，讓貼的人知道為什麼歸零的列會被標成需人工確認。
DO $precheck_zero$
DECLARE
  v_item_chk BOOLEAN;
  v_pric_chk BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
      FROM pg_constraint c
     WHERE c.conrelid = 'public.purchase_request_items'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) ILIKE '%qty_requested%>%0%'
  ) INTO v_item_chk;

  SELECT EXISTS (
    SELECT 1
      FROM pg_constraint c
     WHERE c.conrelid = 'public.purchase_request_item_campaigns'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) ILIKE '%qty_requested%>%0%'
  ) INTO v_pric_chk;

  IF v_item_chk OR v_pric_chk THEN
    RAISE NOTICE '（預期行為）請購數量有 CHECK (qty_requested > 0)：品項=%、來源團明細=%。歸零的列會被標成「需人工確認」，不會被改成 0、也不會被刪 —— 本功能不處理需求歸零，歸零走斷貨流程（2026-10-01 裁示）。',
      v_item_chk, v_pric_chk;
  ELSE
    RAISE NOTICE '（注意）沒有偵測到 qty_requested > 0 的 CHECK；本檔仍然不會把列改成 0，行為保持保守。';
  END IF;
END
$precheck_zero$;


-- ----------------------------------------------------------------------------
-- 1. 新增：權限判定 helper
--    對齊採購模組口徑（20260502010000_fix_purchase_rls_role_path.sql:18
--    與 20260924010000:47-53）：角色讀 app_metadata.role、白名單一律含空字串，
--    並且明確擋 store_manager / store_staff。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pr_qty_sync_assert_perm()
RETURNS VOID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
BEGIN
  -- 分店角色一律擋掉（先擋，不靠白名單反推）
  IF v_role IN ('store_manager','store_staff') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  -- 空字串代表 JWT 沒帶 app_metadata.role（線上有這種帳號），視為總部端放行
  IF v_role NOT IN ('owner','admin','hq_manager','purchaser','assistant','') THEN
    RAISE EXCEPTION 'permission denied';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._pr_qty_sync_assert_perm() FROM PUBLIC;

COMMENT ON FUNCTION public._pr_qty_sync_assert_perm() IS
  '請購數量同步的角色守衛：擋 store_manager / store_staff，白名單含空字串（JWT 沒帶 role 的總部帳號）。';


-- ----------------------------------------------------------------------------
-- 2. 新增：唯讀預覽（不寫任何資料）
--
--    一列 = 這張請購單的一個 (請購品項, 來源團)。
--    `needs_sync` 代表數字跟現在的需求不一致；`can_sync` 代表可以安全自動改。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pr_qty_sync_preview(
  p_pr_id BIGINT
) RETURNS TABLE(
  pr_id            BIGINT,
  pr_no            TEXT,
  pr_status        TEXT,
  pr_item_id       BIGINT,
  sku_id           BIGINT,
  sku_label        TEXT,
  campaign_id      BIGINT,
  campaign_no      TEXT,
  campaign_name    TEXT,
  attribution      TEXT,
  demand_qty       NUMERIC,
  already_qty      NUMERIC,
  draft_qty        NUMERIC,
  delta_qty        NUMERIC,
  new_campaign_qty NUMERIC,
  item_qty         NUMERIC,
  new_item_qty     NUMERIC,
  needs_sync       BOOLEAN,
  can_sync         BOOLEAN,
  block_reason     TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH t AS (
    SELECT public._current_tenant_id() AS tid
  ),
  pr AS (
    SELECT p.id, p.pr_no, p.status, p.tenant_id
      FROM public.purchase_requests p
      CROSS JOIN t
     WHERE p.id = p_pr_id
       AND p.tenant_id = t.tid
  ),
  it AS (
    SELECT pri.id, pri.sku_id, pri.qty_requested, pri.source_campaign_id, pri.po_item_id
      FROM public.purchase_request_items pri
      JOIN pr ON pr.id = pri.pr_id
  ),
  -- 這張單的來源團歸屬：新資料看明細表，舊資料 fallback 看 source_campaign_id
  attr AS (
    SELECT
      pric.pr_item_id,
      pric.campaign_id,
      it.sku_id,
      it.qty_requested AS item_qty,
      it.po_item_id,
      pric.qty_requested AS draft_qty,
      'detail'::TEXT AS attribution
    FROM public.purchase_request_item_campaigns pric
    JOIN it ON it.id = pric.pr_item_id
    CROSS JOIN t
    WHERE pric.tenant_id = t.tid
    UNION ALL
    SELECT
      it.id,
      it.source_campaign_id,
      it.sku_id,
      it.qty_requested,
      it.po_item_id,
      it.qty_requested,
      'legacy'::TEXT
    FROM it
    WHERE it.source_campaign_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
          FROM public.purchase_request_item_campaigns pric
         WHERE pric.pr_item_id = it.id
      )
  ),
  rem AS (
    SELECT *
      FROM public._pr_campaign_sku_remaining_rows(
             ARRAY(SELECT DISTINCT a.campaign_id FROM attr a ORDER BY a.campaign_id)
           )
  ),
  joined AS (
    SELECT
      a.*,
      -- ⭐ helper 的母體是「需求」（LEFT JOIN，20260921001000:240），所以
      --    **需求歸零時它整列不回** —— 這裡 LEFT JOIN 就會是 NULL。
      --    本功能不處理需求歸零（老闆 2026-10-01：歸零走斷貨流程），
      --    所以這種情況一律**略過**：不當成 0 去算、不噴錯、不列入可同步。
      --    `has_remaining` 就是那個閘門，下面 needs_sync 直接 AND 它。
      (r.campaign_id IS NOT NULL)  AS has_remaining,
      COALESCE(r.demand_qty, 0)  AS demand_qty,
      COALESCE(r.already_qty, 0) AS already_qty,
      COALESCE(r.delta_qty, 0)   AS delta_qty,
      a.draft_qty + COALESCE(r.delta_qty, 0) AS new_campaign_qty
    FROM attr a
    LEFT JOIN rem r
      ON r.campaign_id = a.campaign_id
     AND r.sku_id = a.sku_id
  ),
  -- 品項的新總數 ＝ 該品項所有來源團的新數量加總（沒變化的團照舊值算進來）。
  -- 這樣才會滿足 #982 守衛「品項總數 = 明細加總」的相等要求。
  item_new AS (
    SELECT j.pr_item_id, SUM(j.new_campaign_qty) AS new_item_qty
      FROM joined j
     GROUP BY j.pr_item_id
  ),
  -- 同一個 (團, 商品) 現在被幾張「還可以改的草稿請購單」抓著？
  -- 超過一張就不猜要改哪一張（計畫 §6 第 6 條）。
  holders AS (
    SELECT c.campaign_id, c.sku_id, COUNT(DISTINCT c.pr_id) AS draft_holder_count
      FROM (
        SELECT pric.campaign_id, pri.sku_id, pr2.id AS pr_id
          FROM public.purchase_request_item_campaigns pric
          JOIN public.purchase_request_items pri ON pri.id = pric.pr_item_id
          JOIN public.purchase_requests pr2 ON pr2.id = pri.pr_id
          CROSS JOIN t
         WHERE pr2.tenant_id = t.tid
           AND pric.tenant_id = t.tid
           AND pr2.status = 'draft'
           AND pri.po_item_id IS NULL
        UNION ALL
        SELECT pri.source_campaign_id, pri.sku_id, pr2.id
          FROM public.purchase_request_items pri
          JOIN public.purchase_requests pr2 ON pr2.id = pri.pr_id
          CROSS JOIN t
         WHERE pr2.tenant_id = t.tid
           AND pr2.status = 'draft'
           AND pri.po_item_id IS NULL
           AND pri.source_campaign_id IS NOT NULL
           AND NOT EXISTS (
             SELECT 1
               FROM public.purchase_request_item_campaigns pric
              WHERE pric.pr_item_id = pri.id
           )
      ) c
     GROUP BY c.campaign_id, c.sku_id
  ),
  final AS (
    SELECT
      pr.id   AS pr_id,
      pr.pr_no,
      pr.status AS pr_status,
      j.pr_item_id,
      j.sku_id,
      COALESCE(
        NULLIF(TRIM(COALESCE(s.product_name, '')
          || COALESCE(' / ' || NULLIF(s.variant_name, ''), '')), ''),
        s.sku_code,
        '品項#' || j.sku_id::TEXT
      ) AS sku_label,
      j.campaign_id,
      gbc.campaign_no,
      gbc.name AS campaign_name,
      j.attribution,
      j.demand_qty,
      j.already_qty,
      j.draft_qty,
      j.delta_qty,
      j.new_campaign_qty,
      j.item_qty,
      i.new_item_qty,
      -- ⛔ `has_remaining` 是必要條件：helper 沒回這一列（＝需求歸零）就是略過。
      --    ⚠️ 不要簡化成只看 delta_qty —— 現在 delta 被 COALESCE 成 0 剛好也是 false，
      --    但那是巧合，哪天 COALESCE 的預設值改了就會靜靜把歸零的列當成待同步。
      (j.has_remaining AND j.delta_qty <> 0) AS needs_sync,
      CASE
        WHEN pr.status <> 'draft' THEN
          '整張請購單不是草稿（目前 ' || pr.status || '），不自動改'
        WHEN j.po_item_id IS NOT NULL THEN
          '此品項已建立採購單，不自動改'
        WHEN COALESCE(h.draft_holder_count, 1) > 1 THEN
          '同一個團的同一個商品同時在 ' || COALESCE(h.draft_holder_count, 1)::TEXT
          || ' 張草稿請購單上，不自動猜要改哪一張'
        WHEN j.new_campaign_qty <= 0 THEN
          '同步後這個團的數量會變成 ' || j.new_campaign_qty::TEXT
          || '；請購數量不能是 0 或負數（資料庫 CHECK），請人工取消這一列或整張單'
        WHEN i.new_item_qty <= 0 THEN
          '同步後整個品項的數量會變成 ' || i.new_item_qty::TEXT
          || '；請購數量不能是 0 或負數（資料庫 CHECK），請人工取消這一列或整張單'
        ELSE NULL
      END AS block_reason
    FROM joined j
    JOIN pr ON TRUE
    JOIN item_new i ON i.pr_item_id = j.pr_item_id
    LEFT JOIN holders h
      ON h.campaign_id = j.campaign_id
     AND h.sku_id = j.sku_id
    LEFT JOIN public.group_buy_campaigns gbc
      ON gbc.id = j.campaign_id
    LEFT JOIN public.skus s
      ON s.id = j.sku_id
  )
  SELECT
    f.pr_id,
    f.pr_no,
    f.pr_status,
    f.pr_item_id,
    f.sku_id,
    f.sku_label,
    f.campaign_id,
    f.campaign_no,
    f.campaign_name,
    f.attribution,
    f.demand_qty,
    f.already_qty,
    f.draft_qty,
    f.delta_qty,
    f.new_campaign_qty,
    f.item_qty,
    f.new_item_qty,
    f.needs_sync,
    (f.needs_sync AND f.block_reason IS NULL) AS can_sync,
    f.block_reason
  FROM final f
  ORDER BY f.sku_label, f.campaign_id;
$$;

REVOKE ALL ON FUNCTION public._pr_qty_sync_preview(BIGINT) FROM PUBLIC;

COMMENT ON FUNCTION public._pr_qty_sync_preview(BIGINT) IS
  '唯讀：算出這張請購單每個 (品項, 來源團) 目前的有效需求、這張單的草稿量、會增減幾件，以及能不能安全自動同步。不寫任何資料。';


-- ----------------------------------------------------------------------------
-- 3. 新增：給畫面用的唯讀預覽
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_preview_pr_qty_sync(
  p_pr_id BIGINT
) RETURNS TABLE(
  pr_id            BIGINT,
  pr_no            TEXT,
  pr_status        TEXT,
  pr_item_id       BIGINT,
  sku_id           BIGINT,
  sku_label        TEXT,
  campaign_id      BIGINT,
  campaign_no      TEXT,
  campaign_name    TEXT,
  attribution      TEXT,
  demand_qty       NUMERIC,
  already_qty      NUMERIC,
  draft_qty        NUMERIC,
  delta_qty        NUMERIC,
  new_campaign_qty NUMERIC,
  item_qty         NUMERIC,
  new_item_qty     NUMERIC,
  needs_sync       BOOLEAN,
  can_sync         BOOLEAN,
  block_reason     TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();

  IF public._current_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  RETURN QUERY SELECT * FROM public._pr_qty_sync_preview(p_pr_id);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.rpc_preview_pr_qty_sync(BIGINT) IS
  '請購單編輯頁用的唯讀預覽：列出每個 (品項, 來源團) 的有效需求／草稿量／增減量／可否安全同步。';


-- ----------------------------------------------------------------------------
-- 4. 新增：真正寫入
--
--    既有的表只改三張，順序寫死：
--      ① purchase_request_item_campaigns.qty_requested
--      ② purchase_request_items.qty_requested（＝該品項所有明細加總）
--      ③ purchase_requests.total_amount
--    順序反了會被 #982 的 trg_pri_..._guard 以
--    「已綁定原團明細，總數不可直接改成和明細不同」擋下來。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync(
  p_pr_id     BIGINT,
  p_operator  UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant     UUID := public._current_tenant_id();
  v_pr         RECORD;
  v_synced     INTEGER := 0;
  v_blocked    INTEGER := 0;
  v_qty_delta  NUMERIC := 0;
  v_total      NUMERIC := 0;
  v_blocked_rows JSONB := '[]'::JSONB;
  v_synced_rows  JSONB := '[]'::JSONB;
  r            RECORD;
BEGIN
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant is required';
  END IF;

  IF p_operator IS NULL THEN
    p_operator := auth.uid();
  END IF;

  IF p_operator IS NULL THEN
    RAISE EXCEPTION 'operator is required';
  END IF;

  IF auth.uid() IS NOT NULL AND p_operator <> auth.uid() THEN
    RAISE EXCEPTION 'operator must match current user';
  END IF;

  -- 整張單先鎖住，避免同一張單被兩個人同時同步
  SELECT pr.id, pr.pr_no, pr.status
    INTO v_pr
    FROM public.purchase_requests pr
   WHERE pr.id = p_pr_id
     AND pr.tenant_id = v_tenant
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '找不到這張請購單';
  END IF;

  IF v_pr.status <> 'draft' THEN
    RAISE EXCEPTION '只有草稿請購單可以同步數量，目前狀態=%', v_pr.status;
  END IF;

  -- 把計畫「先算好定住」，不要邊算邊改（改到一半預覽就會變）
  -- ⭐ 這裡刻意**不**自己加 (團, 商品) 的 advisory lock，所以預覽到寫入之間
  --    需求有可能被別人改動。這樣仍然是安全的，理由是：
  --    ① 需求變少 → 下面的 UPDATE 會踩到 #982 守衛
  --       （20260921001000:534-604，守衛自己在觸發器裡就 pg_advisory_xact_lock(團,商品)
  --        並重算一次 requested > demand），整筆交易直接 RAISE、一個字都沒寫進去，
  --       使用者看到錯誤重按一次就好 —— ⛔ 不會寫出超額請購。
  --    ② 需求變多 → 這次同步到的數字偏小，不是壞帳，再按一次就補上。
  --    ⇒ 正確性完全由守衛保證，不依賴本檔自己拿鎖。
  DROP TABLE IF EXISTS _pr_qty_sync_plan;
  CREATE TEMP TABLE _pr_qty_sync_plan ON COMMIT DROP AS
  SELECT * FROM public._pr_qty_sync_preview(p_pr_id) WHERE needs_sync;

  SELECT COUNT(*) FILTER (WHERE NOT can_sync)
    INTO v_blocked
    FROM _pr_qty_sync_plan;

  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'pr_item_id', pr_item_id,
               'sku_label', sku_label,
               'campaign_no', campaign_no,
               'draft_qty', draft_qty,
               'demand_qty', demand_qty,
               'delta_qty', delta_qty,
               'reason', block_reason
             ) ORDER BY sku_label, campaign_id
           ), '[]'::JSONB)
    INTO v_blocked_rows
    FROM _pr_qty_sync_plan
   WHERE NOT can_sync;

  -- ① 來源團明細
  FOR r IN
    SELECT * FROM _pr_qty_sync_plan
     WHERE can_sync
     -- 固定順序：#982 守衛在觸發器裡會依我們寫入的先後去拿 (團,商品) 的
     -- advisory lock，所有人都按同一個順序寫，併發時才不會互相卡死。
     ORDER BY campaign_id, sku_id
  LOOP
    IF r.attribution = 'detail' THEN
      UPDATE public.purchase_request_item_campaigns
         SET qty_requested = r.new_campaign_qty
       WHERE pr_item_id = r.pr_item_id
         AND campaign_id = r.campaign_id
         AND tenant_id = v_tenant;

      IF NOT FOUND THEN
        RAISE EXCEPTION '來源團明細在同步途中消失了：pr_item_id=%, campaign_id=%',
          r.pr_item_id, r.campaign_id;
      END IF;
    END IF;

    v_synced := v_synced + 1;
    v_qty_delta := v_qty_delta + r.delta_qty;

    v_synced_rows := v_synced_rows || jsonb_build_object(
      'pr_item_id', r.pr_item_id,
      'sku_label', r.sku_label,
      'campaign_no', r.campaign_no,
      'qty_before', r.draft_qty,
      'qty_after', r.new_campaign_qty,
      'delta_qty', r.delta_qty
    );
  END LOOP;

  -- ② 請購品項總數（一定要等明細全部寫完才動，而且必須等於明細加總）
  FOR r IN
    SELECT DISTINCT pr_item_id, new_item_qty, attribution
      FROM _pr_qty_sync_plan
     WHERE can_sync
     ORDER BY pr_item_id
  LOOP
    IF r.attribution = 'detail' THEN
      -- 用資料庫現況重算，不用預覽存的數字，避免任何飄移
      UPDATE public.purchase_request_items pri
         SET qty_requested = (
               SELECT COALESCE(SUM(pric.qty_requested), 0)
                 FROM public.purchase_request_item_campaigns pric
                WHERE pric.pr_item_id = pri.id
             ),
             updated_by = p_operator,
             updated_at = NOW()
       WHERE pri.id = r.pr_item_id;
    ELSE
      -- 舊資料（只有 source_campaign_id、沒有明細列）：直接寫新總數
      UPDATE public.purchase_request_items pri
         SET qty_requested = r.new_item_qty,
             updated_by = p_operator,
             updated_at = NOW()
       WHERE pri.id = r.pr_item_id;
    END IF;
  END LOOP;

  -- ③ 請購單總金額（line_subtotal 是 generated column，會自己跟著數量變）
  UPDATE public.purchase_requests pr
     SET total_amount = COALESCE((
           SELECT SUM(pri.line_subtotal)
             FROM public.purchase_request_items pri
            WHERE pri.pr_id = p_pr_id
         ), 0),
         updated_by = p_operator,
         updated_at = NOW()
   WHERE pr.id = p_pr_id
  RETURNING pr.total_amount INTO v_total;

  RETURN jsonb_build_object(
    'pr_id', p_pr_id,
    'pr_no', v_pr.pr_no,
    'synced_count', v_synced,
    'blocked_count', v_blocked,
    'qty_delta', v_qty_delta,
    'total_amount', v_total,
    'synced', v_synced_rows,
    'blocked', v_blocked_rows
  );
END;
$$;

REVOKE ALL ON FUNCTION public._pr_apply_qty_sync(BIGINT, UUID) FROM PUBLIC;

COMMENT ON FUNCTION public._pr_apply_qty_sync(BIGINT, UUID) IS
  '把請購草稿的數量同步到目前的開團需求。只改 purchase_request_item_campaigns、purchase_request_items.qty_requested、purchase_requests.total_amount 三處，順序固定。不能安全自動改的列一律跳過並回報原因。';


-- ----------------------------------------------------------------------------
-- 5. 新增：畫面按鈕呼叫的入口
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty(
  p_pr_id    BIGINT,
  p_operator UUID DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._pr_qty_sync_assert_perm();
  RETURN public._pr_apply_qty_sync(p_pr_id, p_operator);
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_sync_pr_qty(BIGINT, UUID) IS
  '請購單編輯頁「同步最新開團數量」按鈕：把草稿數量對到目前的有效需求，回報同步了幾筆、幾筆需人工確認。';


-- ----------------------------------------------------------------------------
-- 6. 把內部函式從 anon 收回（rpc_* 只開給 authenticated）
-- ----------------------------------------------------------------------------
DO $revoke_anon$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public._pr_qty_sync_assert_perm() FROM anon;
    REVOKE ALL ON FUNCTION public._pr_qty_sync_preview(BIGINT) FROM anon;
    REVOKE ALL ON FUNCTION public._pr_apply_qty_sync(BIGINT, UUID) FROM anon;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON FUNCTION public._pr_qty_sync_preview(BIGINT) FROM authenticated;
    REVOKE ALL ON FUNCTION public._pr_apply_qty_sync(BIGINT, UUID) FROM authenticated;
  END IF;
END
$revoke_anon$;
