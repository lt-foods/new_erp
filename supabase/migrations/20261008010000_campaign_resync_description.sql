-- ============================================================================
-- 開團「重新同步商品/價格」也把商品文案帶進團
--
-- 解決的問題
--   團文案（group_buy_campaigns.description）＝開團那一刻從商品複製的一份
--   （rpc_create_campaign_from_product：COALESCE(p_description, products.description)）。
--   之後商品文案改了（加規格、改價錢說明），開團頁按「重新同步商品/價格」只同步品名、
--   單價、新規格、待確認訂單金額，**不碰文案**；開團後後台也沒有地方改團文案。
--   ⇒ LINE 記事本按「更新貼文」印出來的還是舊文案（貼文讀的是團文案），會員 App 的團介紹也是舊的。
--
-- 做法（只加不改）
--   rpc_resync_campaign_from_product 多做一件事：
--     - 預覽（p_dry_run = TRUE）多回三個欄位：
--         description_changed  這團有 product_id、商品文案有字、且商品文案 IS DISTINCT FROM 團文案
--         description_before   團文案（完整）
--         description_after    套用後的團文案（完整；有變＝商品文案；沒變＝原團文案）
--       完整回傳、不截字：新加的規格行常在第 5 行以後，只給開頭就正好看不到要確認的那一行。
--     - 套用（p_dry_run = FALSE）時 description_changed 才把這一團的 description 改成完整的商品文案
--       （另一句 UPDATE，只動 description，WHERE 跟改團名那句一樣：id = p_campaign_id AND tenant_id）。
--   「商品文案有字」的判準：去掉 HTML 標籤、&nbsp;、空白之後還有東西。
--     商品文案編輯器（TipTap）清空後存的是 '<p></p>'，不是 NULL；只用 btrim 判會把團文案清成空的。
--     沒有字 → 不動團文案。
--   LINE 貼文不會自動更新（照現行做法，同步完自己到 LINE 記事本按「更新貼文」）：
--     group_buy_campaigns 上的觸發器只有 trg_touch_gbc（BEFORE UPDATE，只蓋 updated_at）跟
--     UPDATE OF status／end_at, customer_end_at 那幾支，改 description 一支都不會觸發。
--
-- 基底版本（逐字保留，只在上面幾處插入新行，沒有改掉或刪掉任何一行）
--   rpc_resync_campaign_from_product ← 20260819000000_gift_exempt_zero_price_guard.sql:782
--   （全 repo 定義只有 4 支：20260620000010 / 20260620000020 / 20260620000060 / 20260819000000，最後一支是它）
--   線上版指紋 md5(prosrc) = aef48bcdb89939e8408997129c8686a2（2026-10-08 實測，
--   與該檔 $$…$$ 內文逐字一致）。前置檢查會再比一次。
--   簽名 (BIGINT, BOOLEAN, UUID) RETURNS JSONB 不變 → CREATE OR REPLACE，不需要 DROP。
--
-- 其他行為一字不改：權限（僅管理員）、狀態守門（只 draft／open）、零售價守門、改團名、
--   改單價、補新規格、移除停售規格、待確認訂單回填與稽核紀錄、贈品全程跳過。
--
-- 已知要注意
--   - 員工建立開團時若在視窗裡特別改過團文案，按重新同步會被換回商品文案；
--     預覽會先列出改前／改後的完整文案，看了不想換就按取消。
--   - 上線順序：先合併前端、等 GitHub Pages 部署完成（新畫面已上線），再貼本檔。
--     理由：
--       ・新畫面＋本檔還沒貼：新畫面把「沒有 description_* 欄位」當作文案沒變 →
--         預覽不出現文案那一項、文案也不會動，其他同步行為跟現在一樣。這段期間是安全的。
--       ・反過來（舊畫面＋本檔已貼）會出事：舊畫面判斷「有沒有變更」只看名稱／單價／規格／
--         待確認訂單，預覽裡沒有文案那一項。只有文案變的團不會出現「確認同步」（看起來沒變更）；
--         但只要同一團同時有改名、改價等其他變更，按「確認同步」就會在預覽**看不到**的情況下
--         把團文案一起換掉。
--     ⇒ 一定要確認新畫面已經部署上線之後才貼本檔。
--
-- 整份可重貼：前置檢查認得「20260819000000 那一版」（第一次貼）和「本檔建的版本」（重貼），
--   其餘一律停下來、一行都不執行。CREATE OR REPLACE／GRANT／COMMENT 重跑結果一樣。
--
-- Rollback：只重跑 20260819000000 第 7 段（:776 起的 CREATE OR REPLACE、:1091 GRANT、
--   :1094 COMMENT），不要整份重跑那支檔案。
--   ⚠ 已經被同步換掉的團文案不會自己變回來（舊文案沒有另外存）。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— 放在所有 DDL 之前、唯讀
--    這份 SQL 是貼進 SQL Editor 執行的，前提不成立時要在「還沒動任何東西」的階段就停下來。
-- ----------------------------------------------------------------------------
DO $precheck$
DECLARE
  v_missing TEXT[] := ARRAY[]::TEXT[];
  v_name    TEXT;
  v_cnt     INT;
  v_src     TEXT;
BEGIN
  -- 依賴的既有欄位（本檔新加的文案段要讀寫的 ＋ 基底本來就在用的贈品欄位）
  FOREACH v_name IN ARRAY ARRAY[
    'group_buy_campaigns.description',
    'group_buy_campaigns.product_id',
    'group_buy_campaigns.name',
    'group_buy_campaigns.updated_at',
    'products.description',
    'products.name',
    'campaign_items.is_gift',
    'customer_order_items.is_gift'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_attribute a
       WHERE a.attrelid = to_regclass('public.' || split_part(v_name, '.', 1))
         AND a.attname = split_part(v_name, '.', 2)
         AND a.attnum > 0
         AND NOT a.attisdropped
    ) THEN
      v_missing := v_missing || ('column public.' || v_name);
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION E'前置檢查未通過，本檔一行都沒有執行。缺少：\n%',
      array_to_string(v_missing, E'\n');
  END IF;

  -- 同名只能有一支，而且簽名要一模一樣
  SELECT COUNT(*) INTO v_cnt
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'rpc_resync_campaign_from_product';
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。public.rpc_resync_campaign_from_product 應該剛好 1 支，現在有 % 支', v_cnt;
  END IF;

  SELECT p.prosrc INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'rpc_resync_campaign_from_product'
     AND pg_get_function_identity_arguments(p.oid) = 'p_campaign_id bigint, p_dry_run boolean, p_operator uuid'
     AND pg_get_function_result(p.oid) = 'jsonb';
  IF v_src IS NULL THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。public.rpc_resync_campaign_from_product 的參數或回傳型別跟預期 (p_campaign_id bigint, p_dry_run boolean, p_operator uuid) RETURNS jsonb 不一樣';
  END IF;

  -- 線上這支必須是基底那一版（第一次貼），或是本檔建的版本（重貼）；
  -- 其他版本＝有人改過，照本檔貼下去會把那次修改蓋掉 → 停。
  IF md5(v_src) <> 'aef48bcdb89939e8408997129c8686a2'
     AND position('campaign_resync_description:20261008010000' IN v_src) = 0 THEN
    RAISE EXCEPTION '前置檢查未通過，本檔一行都沒有執行。線上 rpc_resync_campaign_from_product 不是 20260819000000 那一版（md5=%），也不是本檔建的版本；可能有人改過，請先比對再決定',
      md5(v_src);
  END IF;
END;
$precheck$;


-- ----------------------------------------------------------------------------
-- 1. rpc_resync_campaign_from_product —— 基底 20260819000000:782 逐字，只加文案預覽與套用
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_resync_campaign_from_product(
  p_campaign_id BIGINT,
  p_dry_run     BOOLEAN DEFAULT TRUE,
  p_operator    UUID    DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
-- campaign_resync_description:20261008010000（本檔記號：前置檢查靠它認出「這是本檔建的版本」，勿刪）
DECLARE
  v_tenant    UUID := (auth.jwt() ->> 'tenant_id')::uuid;
  v_role      TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_op        UUID := COALESCE(p_operator, auth.uid());
  v_camp      group_buy_campaigns%ROWTYPE;
  v_prod_name TEXT;
  v_bad_cnt   INT;
  v_bad_list  TEXT;
  v_name_changed       BOOLEAN := FALSE;
  -- 20261008010000：文案←商品文案
  v_prod_desc          TEXT;
  v_desc_changed       BOOLEAN := FALSE;
  v_items_repriced     INT := 0;
  v_items_removed_cnt  INT := 0;
  v_items_removed_json JSONB;
  v_skus_added         INT := 0;
  v_orders             INT := 0;
  v_lines              INT := 0;
  v_amt_before         NUMERIC := 0;
  v_amt_after          NUMERIC := 0;
  v_items_json         JSONB;
  v_result             JSONB;
BEGIN
  -- ---------- 權限：僅管理員 ----------
  IF v_tenant IS NULL THEN
    RAISE EXCEPTION 'tenant_id missing in JWT';
  END IF;
  IF v_role NOT IN ('owner','admin','') THEN
    RAISE EXCEPTION '權限不足：僅管理員可重新同步開團（role=%）', v_role;
  END IF;

  -- ---------- 開團 + 狀態守門 ----------
  SELECT * INTO v_camp
    FROM group_buy_campaigns
   WHERE id = p_campaign_id AND tenant_id = v_tenant
   FOR UPDATE;
  IF v_camp.id IS NULL THEN
    RAISE EXCEPTION 'campaign % 不在 tenant 內', p_campaign_id;
  END IF;
  IF v_camp.status NOT IN ('draft','open') THEN
    RAISE EXCEPTION '只有草稿/開團中的開團可以重新同步（目前狀態：%）', v_camp.status;
  END IF;

  -- ---------- 守門：已在 campaign_items 的 active SKU 必須都有有效零售價 ----------
  SELECT COUNT(*),
         string_agg(s.sku_code, ', ' ORDER BY s.sku_code)
    INTO v_bad_cnt, v_bad_list
    FROM campaign_items ci
    JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
   WHERE ci.campaign_id = p_campaign_id
     AND ci.tenant_id   = v_tenant
     AND s.status = 'active'
     -- 20260819000000：贈品本來就是 $0、也不跟零售價走，缺價不該擋住整支 resync
     AND NOT COALESCE(ci.is_gift, FALSE)
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) <= 0;
  IF v_bad_cnt > 0 THEN
    RAISE EXCEPTION '仍有 % 個 active SKU 沒有有效零售價，請先到商品頁設定售價（避免回填成 0）：%',
      v_bad_cnt, v_bad_list;
  END IF;

  -- ---------- 名稱 ----------
  IF v_camp.product_id IS NOT NULL THEN
    SELECT name INTO v_prod_name
      FROM products WHERE id = v_camp.product_id AND tenant_id = v_tenant;
  END IF;
  v_name_changed := (v_prod_name IS NOT NULL AND v_prod_name IS DISTINCT FROM v_camp.name);

  -- ---------- 文案（20261008010000）----------
  -- 團文案＝開團那一刻從商品複製的一份；之後商品文案改了，靠這裡帶進團。
  -- 商品文案沒有字（NULL／空字串／編輯器清空後留下的 <p></p>）→ 不動團文案，避免把團文案清掉。
  IF v_camp.product_id IS NOT NULL THEN
    SELECT description INTO v_prod_desc
      FROM products WHERE id = v_camp.product_id AND tenant_id = v_tenant;
  END IF;
  v_desc_changed := (
    v_prod_desc IS NOT NULL
    AND regexp_replace(v_prod_desc, '<[^>]*>|&nbsp;|[[:space:]]', '', 'gi') <> ''
    AND v_prod_desc IS DISTINCT FROM v_camp.description
  );

  -- ---------- 預覽：reprice 列表 ----------
  SELECT COUNT(*),
         jsonb_agg(jsonb_build_object(
           'sku_id', t.sku_id, 'sku_code', t.sku_code,
           'old_price', t.old_price, 'new_price', t.new_price
         ) ORDER BY t.sku_code)
    INTO v_items_repriced, v_items_json
    FROM (
      SELECT ci.sku_id, s.sku_code, ci.unit_price AS old_price,
             (SELECT pr.price FROM prices pr
               WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                 AND pr.scope = 'retail' AND pr.effective_to IS NULL
               ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
        FROM campaign_items ci
        JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
       WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
         AND s.status = 'active'
         -- 20260819000000：贈品的 $0 是刻意的，不列入重新定價
         AND NOT COALESCE(ci.is_gift, FALSE)
    ) t
   WHERE t.old_price IS DISTINCT FROM t.new_price;

  -- ---------- 預覽：將被移除的 discontinued SKU items（無訂單引用）----------
  SELECT COUNT(*),
         jsonb_agg(jsonb_build_object(
           'ci_id', t.ci_id, 'sku_id', t.sku_id, 'sku_code', t.sku_code,
           'unit_price', t.unit_price
         ) ORDER BY t.sku_code)
    INTO v_items_removed_cnt, v_items_removed_json
    FROM (
      SELECT ci.id AS ci_id, ci.sku_id, s.sku_code, ci.unit_price
        FROM campaign_items ci
        JOIN skus s ON s.id = ci.sku_id AND s.tenant_id = ci.tenant_id
       WHERE ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
         AND s.status = 'discontinued'
         AND NOT EXISTS (
           SELECT 1 FROM customer_order_items coi WHERE coi.campaign_item_id = ci.id
         )
    ) t;

  -- ---------- 預覽：補進的新 active SKU ----------
  SELECT COUNT(*) INTO v_skus_added
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((
           SELECT pr.price FROM prices pr
            WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
              AND pr.scope = 'retail' AND pr.effective_to IS NULL
            ORDER BY pr.effective_from DESC LIMIT 1
         ), 0) > 0;

  -- 受影響的「待確認」訂單
  SELECT COUNT(DISTINCT co.id) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price),
         COUNT(*) FILTER (
           WHERE coi.unit_price IS DISTINCT FROM rc.new_price)
    INTO v_orders, v_lines
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN LATERAL (
      SELECT (SELECT pr.price FROM prices pr
                WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                  AND pr.scope = 'retail' AND pr.effective_to IS NULL
                ORDER BY pr.effective_from DESC LIMIT 1) AS new_price
    ) rc ON TRUE
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE);

  SELECT
    COALESCE(SUM(coi.qty * coi.unit_price), 0),
    COALESCE(SUM(coi.qty * CASE
       -- 20260819000000：贈品列不重新定價，預覽金額也要維持現價
       WHEN COALESCE(coi.is_gift, FALSE) OR COALESCE(gi.is_gift, FALSE) THEN coi.unit_price
       ELSE COALESCE(
         CASE WHEN s.status = 'active' THEN
           (SELECT pr.price FROM prices pr
             WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
               AND pr.scope = 'retail' AND pr.effective_to IS NULL
             ORDER BY pr.effective_from DESC LIMIT 1)
         END, coi.unit_price)
     END), 0)
    INTO v_amt_before, v_amt_after
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id
    LEFT JOIN campaign_items gi ON gi.id = coi.campaign_item_id
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending';

  v_result := jsonb_build_object(
    'dry_run',             p_dry_run,
    'campaign_id',         p_campaign_id,
    'campaign_no',         v_camp.campaign_no,
    'campaign_status',     v_camp.status,
    'name_before',         v_camp.name,
    'name_after',          COALESCE(v_prod_name, v_camp.name),
    'name_changed',        v_name_changed,
    -- 20261008010000：文案。改前／改後都回完整文案（新加的規格行常在後段，只給開頭會看不到）
    'description_changed', v_desc_changed,
    'description_before',  v_camp.description,
    'description_after',   CASE WHEN v_desc_changed THEN v_prod_desc ELSE v_camp.description END,
    'items',               COALESCE(v_items_json, '[]'::jsonb),
    'items_repriced',      v_items_repriced,
    'items_removed',       COALESCE(v_items_removed_json, '[]'::jsonb),
    'items_removed_count', v_items_removed_cnt,
    'skus_added',          v_skus_added,
    'pending_orders',      v_orders,
    'pending_order_lines', v_lines,
    'amount_before',       v_amt_before,
    'amount_after',        v_amt_after
  );

  IF p_dry_run THEN
    RETURN v_result;
  END IF;

  -- ================= 實跑（單一交易，出錯全 rollback）=================

  IF v_name_changed THEN
    UPDATE group_buy_campaigns
       SET name = v_prod_name, updated_at = NOW()
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  END IF;

  -- 20261008010000：團文案←商品文案（只動這一團的 description）
  IF v_desc_changed THEN
    UPDATE group_buy_campaigns
       SET description = v_prod_desc, updated_at = NOW()
     WHERE id = p_campaign_id AND tenant_id = v_tenant;
  END IF;

  -- 移除 discontinued SKU 的 campaign_items（無訂單引用的才動）
  DELETE FROM campaign_items ci
   USING skus s
   WHERE ci.sku_id = s.id AND s.tenant_id = ci.tenant_id
     AND ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
     AND s.status = 'discontinued'
     AND NOT EXISTS (
       SELECT 1 FROM customer_order_items coi WHERE coi.campaign_item_id = ci.id
     );

  UPDATE campaign_items ci
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM skus s
   WHERE ci.sku_id = s.id AND s.tenant_id = ci.tenant_id
     AND ci.campaign_id = p_campaign_id AND ci.tenant_id = v_tenant
     AND s.status = 'active'
     -- 20260819000000：贈品維持 $0，不被同步蓋回零售價
     AND NOT COALESCE(ci.is_gift, FALSE)
     AND ci.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = ci.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  INSERT INTO campaign_items
    (tenant_id, campaign_id, sku_id, unit_price, sort_order, created_by, updated_by)
  SELECT v_tenant, p_campaign_id, s.id,
         (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1),
         999, v_op, v_op
    FROM skus s
   WHERE v_camp.product_id IS NOT NULL
     AND s.tenant_id  = v_tenant
     AND s.product_id = v_camp.product_id
     AND s.status     = 'active'
     AND NOT EXISTS (SELECT 1 FROM campaign_items ci
                      WHERE ci.campaign_id = p_campaign_id
                        AND ci.tenant_id = v_tenant AND ci.sku_id = s.id)
     AND COALESCE((SELECT pr.price FROM prices pr
                    WHERE pr.tenant_id = v_tenant AND pr.sku_id = s.id
                      AND pr.scope = 'retail' AND pr.effective_to IS NULL
                    ORDER BY pr.effective_from DESC LIMIT 1), 0) > 0
  ON CONFLICT (campaign_id, sku_id) DO NOTHING;

  INSERT INTO customer_order_audit_log
    (tenant_id, order_id, entity_type, entity_id, field,
     before_value, after_value, edit_reason, operator_id)
  SELECT co.tenant_id, co.id, 'item', coi.id, 'unit_price',
         to_jsonb(coi.unit_price),
         to_jsonb((SELECT pr.price FROM prices pr
                     WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                       AND pr.scope = 'retail' AND pr.effective_to IS NULL
                     ORDER BY pr.effective_from DESC LIMIT 1)),
         '開團「重新同步商品/價格」批次回填（待確認訂單）',
         COALESCE(v_op, co.updated_by, co.created_by, v_camp.created_by)
    FROM customer_orders co
    JOIN customer_order_items coi ON coi.order_id = co.id
    JOIN skus s ON s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
   WHERE co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE)
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  UPDATE customer_order_items coi
     SET unit_price = (SELECT pr.price FROM prices pr
                         WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
                           AND pr.scope = 'retail' AND pr.effective_to IS NULL
                         ORDER BY pr.effective_from DESC LIMIT 1),
         updated_at = NOW(),
         updated_by = v_op
    FROM customer_orders co, skus s
   WHERE coi.order_id = co.id
     AND s.id = coi.sku_id AND s.tenant_id = co.tenant_id AND s.status = 'active'
     AND co.campaign_id = p_campaign_id AND co.tenant_id = v_tenant
     AND co.status = 'pending'
     -- 20260819000000：贈品列不回填價格
     AND NOT EXISTS (SELECT 1 FROM campaign_items gi
                      WHERE gi.id = coi.campaign_item_id AND gi.is_gift)
     AND NOT COALESCE(coi.is_gift, FALSE)
     AND coi.unit_price IS DISTINCT FROM (SELECT pr.price FROM prices pr
           WHERE pr.tenant_id = v_tenant AND pr.sku_id = coi.sku_id
             AND pr.scope = 'retail' AND pr.effective_to IS NULL
           ORDER BY pr.effective_from DESC LIMIT 1);

  RETURN v_result || jsonb_build_object('applied', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_resync_campaign_from_product(BIGINT, BOOLEAN, UUID) IS
  '開團重新同步：名稱←product、campaign_items 單價←現行零售價、補 active SKU、'
  '移除 discontinued SKU（無訂單引用者）、回填 status=pending 訂單明細並寫 customer_order_audit_log。'
  'draft/open 限定、僅管理員(owner/admin) 限定、active SKU 缺有效零售價則拒跑、p_dry_run 預設只預覽。'
  '20260819000000：贈品（campaign_items.is_gift / customer_order_items.is_gift）全程跳過'
  '——不重新定價、不回填訂單、缺零售價也不擋跑。'
  '20261008010000：團文案←商品文案（商品文案沒有字時不動團文案）；預覽回 description_changed / _before / _after（完整文案）。';
