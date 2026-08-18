-- ============================================================
-- 2026-08-18: rpc_open_campaign_from_candidate —— 候選池「一鍵建商品＋開團」（B-4 後端）
--
-- ⚠️⚠️⚠️ 為什麼需要這一支，而不是前端直接串兩支既有 RPC
--     （原計畫寫的是「rpc_schedule_candidate → rpc_create_campaign_from_product」）
--
--   照原計畫串起來，**每一筆都會建出一個沒有任何商品明細的空團**，而且不會報錯：
--
--     rpc_schedule_candidate（20260630000010:78,86）建的 product 與 sku
--       p_status := 'draft'
--     rpc_create_campaign_from_product（20260703000010）只認 active：
--       - 缺價守衛：  FROM skus s WHERE ... AND s.status = 'active'
--                     → draft sku 不在集合裡 → string_agg 對空集合回 NULL
--                     → v_missing IS NULL → **守衛整個不會觸發**
--       - 塞明細迴圈：FROM skus s WHERE ... AND s.status = 'active'
--                     → 0 列 → **campaign_items 一筆都沒有**
--
--   結果：group_buy_campaigns 有一列（status='open'、is_for_shop 預設 TRUE），
--   客人連結打得開，但裡面什麼都沒有；而 customer_order_items.campaign_item_id 是
--   NOT NULL（20260423120000:206），所以那個團**永遠不可能有人下單**。
--   老闆拿到連結、貼出去、客人說「點進去是空的」才會發現。
--
--   （對照組：既有「建立新開團」按鈕沒事，因為它開的是商品頁上已經 active 的商品。
--     候選池排程出來的是 draft，這條路徑從來沒有人走過。）
--
--   → 所以「一鍵開團」必須自己負責把商品／規格啟用，並且在建團前把
--     「沒有 active SKU」「沒有現售價或現售價是 0」這兩件事擋掉。
--     這些守衛放 DB 不放前端（機制索引 §七.3：前端驗證任何新入口都繞得過）。
--
-- ⭐ 為什麼包成一支 RPC 而不是前端呼叫三次：
--   一支 RPC ＝ 一個交易。中間任何一步失敗，這一筆候選整個回滾成原樣
--   （候選不會停在 scheduled、商品不會停在半啟用、不會留下空團）。
--   批次時每一筆各自是獨立交易 → 前面成功的照樣保留、失敗的乾淨回滾，
--   正是計畫 §B-4 要的「部分失敗」語意。
--
-- ⛔ 這支「不是」把 PR #374 拿掉的自動建團加回去：
--   rpc_schedule_candidate 本身完全沒變（排程仍然不建團），
--   本函式是老闆自己按第二顆鈕才會走到的另一條路徑。
--
-- 品牌從哪來：
--   由本函式自己查 community_channel_brands（20260818000120），不收前端傳的品牌。
--   → 畫面上的「來源篩選」與「開團標的品牌」讀的是同一張對應表，
--     不可能一邊算漂漂館、另一邊算找貨群。
--
-- 相依：
--   20260818000110（rpc_schedule_candidate 4 參數版）
--   20260818000120（community_channel_brands）
--
-- Rollback：
--   DROP FUNCTION IF EXISTS public.rpc_open_campaign_from_candidate(BIGINT, DATE, TEXT, TIMESTAMPTZ, DATE);
--   （前端的「建商品＋開團」按鈕要一起拿掉；「批次排日期」不受影響）
--
-- Scope：只新增一支 RPC。不動任何既有函式、view、表。
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_open_campaign_from_candidate(
  p_candidate_id    BIGINT,
  p_scheduled_date  DATE,
  p_product_name    TEXT,
  p_end_at          TIMESTAMPTZ,
  p_pickup_deadline DATE DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant       UUID := public._current_tenant_id();
  v_user         UUID := auth.uid();
  v_role         TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_source_ch    TEXT;
  v_brand_id     BIGINT;
  v_brand_name   TEXT;
  v_sched        JSONB;
  v_product_id   BIGINT;
  v_product_code TEXT;
  v_sku_id       BIGINT;
  v_active_skus  INT;
  v_missing      TEXT;
  v_campaign_id  BIGINT;
  v_campaign_no  TEXT;
  v_existing_no  TEXT;
BEGIN
  -- ── 權限：與 rpc_schedule_candidate / ccp_hq_all 同一份名單 ───────────────
  IF v_role NOT IN ('owner','admin','hq_manager','assistant','') THEN
    RAISE EXCEPTION 'permission denied: role % cannot open campaign from candidate', v_role;
  END IF;

  -- ── 收單時間：⛔ 不自作主張給預設值，沒給就擋下（計畫 §B-4 第 1 點）─────────
  IF p_end_at IS NULL THEN
    RAISE EXCEPTION '請先指定收單時間';
  END IF;
  IF p_end_at <= NOW() THEN
    RAISE EXCEPTION '收單時間必須晚於現在';
  END IF;
  -- ⚠️ 一定要指定 Asia/Taipei：裸的 p_end_at::DATE 吃 session 時區（線上是 UTC），
  --    台北凌晨 00:00–07:59 收單的團會被算成前一天，這道守衛就會鬆掉一天。
  --    全 repo 對 group_buy_campaigns.end_at 一律用這個寫法（65 支 migration / 90 處），照抄不自創。
  IF p_pickup_deadline IS NOT NULL
     AND p_pickup_deadline < DATE(p_end_at AT TIME ZONE 'Asia/Taipei') THEN
    RAISE EXCEPTION '取貨截止日不可早於收單日';
  END IF;

  -- ── 來源 → 品牌（查對應表，不收前端傳值）────────────────────────────────
  SELECT c.source_channel
    INTO v_source_ch
    FROM community_product_candidates c
   WHERE c.id = p_candidate_id AND c.tenant_id = v_tenant;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'candidate % not found or cross-tenant', p_candidate_id;
  END IF;

  IF v_source_ch IS NOT NULL THEN
    SELECT m.brand_id, b.name
      INTO v_brand_id, v_brand_name
      FROM community_channel_brands m
      JOIN brands b ON b.id = m.brand_id AND b.tenant_id = m.tenant_id
     WHERE m.tenant_id = v_tenant AND m.source_channel = v_source_ch;
  END IF;

  -- ── 1. 排程：建 draft product + sku（+ retail price）、標記候選 scheduled ──
  --    完全沿用既有那一支，不重寫它的邏輯。
  v_sched := public.rpc_schedule_candidate(
    p_candidate_id   => p_candidate_id,
    p_scheduled_date => p_scheduled_date,
    p_product_name   => p_product_name,
    p_brand_id       => v_brand_id
  );

  v_product_id   := (v_sched ->> 'product_id')::BIGINT;
  v_product_code :=  v_sched ->> 'product_code';
  v_sku_id       := (v_sched ->> 'sku_id')::BIGINT;

  IF v_product_id IS NULL THEN
    RAISE EXCEPTION '排程沒有回傳商品 id，無法開團（候選 #%）', p_candidate_id;
  END IF;

  -- ── 2. 防重：這個商品已經有團，就不要再開第二個 ──────────────────────────
  --   ⚠️⚠️ 這道守衛「必須」在 DB 裡，不能只靠畫面。
  --     view 的 has_campaign + 前端的 canOpen 只做到「看不到就選不到」——
  --     開兩個分頁、或畫面沒重新整理就連按兩次，同一個商品照樣會被開出第二個團。
  --     這正是機制索引 §七.3 記過的老坑：「驗證寫在前端 ＝ 每開一個新入口就開一個新洞」
  --     （請購單價格驗證只寫在 React 的 submitForReview()，換個入口就穿透）。
  --
  --   判定條件與 v_community_product_candidates.has_campaign 逐字相同
  --   （同 tenant + 同 product_id + status <> 'cancelled'），
  --   ⛔ 不要在這裡另外發明一套，否則畫面與後端會漂移。
  --
  --   先鎖商品列再檢查：READ COMMITTED 下光做 EXISTS 擋不住並行——
  --   兩個交易都看不到對方尚未 commit 的團。鎖住 products 這一列之後，
  --   同一個商品的第二個呼叫會等第一個 commit 完才往下走，那時就看得到那個團了。
  --   鎖的順序固定是「候選列（rpc_schedule_candidate 內的 FOR UPDATE）→ 商品列」，
  --   所有呼叫端一致，不會形成循環等待。
  PERFORM 1 FROM products
   WHERE id = v_product_id AND tenant_id = v_tenant
     FOR UPDATE;

  SELECT g.campaign_no
    INTO v_existing_no
    FROM group_buy_campaigns g
   WHERE g.tenant_id  = v_tenant
     AND g.product_id = v_product_id
     AND g.status <> 'cancelled'
   ORDER BY g.id DESC
   LIMIT 1;

  IF v_existing_no IS NOT NULL THEN
    RAISE EXCEPTION '這個商品已經有一個進行中的團（團號 %），不會重複開。要重開請先取消原本那個團。', v_existing_no;
  END IF;

  -- ── 3. 啟用：draft → active ─────────────────────────────────────────────
  --    ⚠️ 只升 'draft'。inactive / discontinued 是有人刻意下架的，
  --      ⛔ 不可以被候選池悄悄復活 —— 那種情況會落到下面的守衛、明確報錯給老闆看。
  UPDATE products
     SET status = 'active', updated_by = v_user, updated_at = NOW()
   WHERE id = v_product_id AND tenant_id = v_tenant AND status = 'draft';

  IF FOUND THEN
    PERFORM public._log_product_audit(
      v_tenant, 'product', v_product_id, 'status_change',
      jsonb_build_object('status','draft'), jsonb_build_object('status','active'),
      'open campaign from candidate #' || p_candidate_id::TEXT
    );
  END IF;

  -- ⚠️⚠️ 只啟用「這次候選關聯到的那一個 SKU」，⛔ 不是整個商品底下所有 draft 規格。
  --   候選可以接到既有商品（見上面 rpc_schedule_candidate 的 adopted_product_id 分支），
  --   而既有商品很可能有老闆「故意留著沒上架」的 draft 規格（某口味還沒進貨、某規格還沒定價）。
  --   整批啟用會讓它們變成可販售、被 rpc_create_campaign_from_product 塞進團
  --   → 客人買得到但實際上沒貨。
  --   v_sku_id 來自 rpc_schedule_candidate 的回傳：
  --     新建商品 → 就是剛建的那一個 SKU
  --     既有商品 → 該商品 id 最小的那一個 SKU（該函式自己選的，這裡沿用同一個對象）
  --   已經是 active 的其他規格照舊會被塞進團 —— 那是既有行為，不動。
  UPDATE skus
     SET status = 'active', updated_by = v_user, updated_at = NOW()
   WHERE id = v_sku_id AND tenant_id = v_tenant AND status = 'draft';

  IF FOUND THEN
    PERFORM public._log_product_audit(
      v_tenant, 'sku', v_sku_id, 'status_change',
      jsonb_build_object('status','draft'), jsonb_build_object('status','active'),
      'open campaign from candidate #' || p_candidate_id::TEXT
    );
  END IF;

  -- ── 4. 守衛 A：一定要有 active SKU ───────────────────────────────────────
  --    ⚠️ 這就是本檔存在的理由：少了這道，rpc_create_campaign_from_product
  --      會靜默建出一個沒有任何 campaign_items 的空團。
  SELECT COUNT(*) INTO v_active_skus
    FROM skus
   WHERE product_id = v_product_id AND tenant_id = v_tenant AND status = 'active';

  IF v_active_skus = 0 THEN
    RAISE EXCEPTION '無法開團：商品 % 沒有任何可販售的規格（可能已被下架或停產）', v_product_code;
  END IF;

  -- ── 5. 守衛 B：每個 active SKU 都要有「現行零售價且大於 0」───────────────
  --    比 rpc_create_campaign_from_product 的守衛多了「> 0」：
  --    它只檢查價格「有沒有這一列」，而 rpc_set_retail_price 不擋 0，
  --    候選的 adopted_sale_price 填 0 也存得進去
  --    → 會生出 unit_price = 0 的 campaign_items，也就是 20260815000000 在收拾的
  --      那批「$0 品項」（線上 233 列 / 194 張單，其中 111 列貨已經白送出去）。
  --    價格口徑對齊 rpc_quick_create_campaign_from_product（20260813001000）。
  SELECT string_agg(
           s.sku_code || COALESCE(' (' || NULLIF(btrim(s.variant_name), '') || ')', ''),
           '、' ORDER BY s.id)
    INTO v_missing
    FROM skus s
   WHERE s.product_id = v_product_id
     AND s.tenant_id  = v_tenant
     AND s.status     = 'active'
     AND NOT EXISTS (
       SELECT 1
         FROM prices p
        WHERE p.sku_id       = s.id
          AND p.tenant_id    = v_tenant
          AND p.scope        = 'retail'
          AND p.effective_to IS NULL
          AND p.price        > 0
     );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION '無法開團：請先在候選池「補資料」填好售價（需大於 0）→ %', v_missing;
  END IF;

  -- ── 6. 開團（沿用既有 RPC，團號／文案／塞明細都由它負責）─────────────────
  v_campaign_id := public.rpc_create_campaign_from_product(
    p_name            => p_product_name,
    p_end_at          => p_end_at,
    p_pickup_deadline => p_pickup_deadline,
    p_product_id      => v_product_id,
    p_description     => NULL          -- NULL ＝ 退回商品本身的 description（候選的 raw_text）
  );

  SELECT g.campaign_no INTO v_campaign_no
    FROM group_buy_campaigns g
   WHERE g.id = v_campaign_id AND g.tenant_id = v_tenant;

  -- ── 7. 收尾自檢：真的有明細才算成功 ─────────────────────────────────────
  --    守衛 A/B 都過了理論上不會走到這裡；留著是因為「空團」是本案最貴的失敗模式，
  --    寧可整筆回滾也不要交一個打得開但買不了的連結給老闆。
  IF NOT EXISTS (
    SELECT 1 FROM campaign_items ci
     WHERE ci.campaign_id = v_campaign_id AND ci.tenant_id = v_tenant
  ) THEN
    RAISE EXCEPTION '開團失敗：團 % 沒有任何商品明細，已取消（商品 %）', v_campaign_no, v_product_code;
  END IF;

  RETURN jsonb_build_object(
    'candidate_id',  p_candidate_id,
    'product_id',    v_product_id,
    'product_code',  v_product_code,
    'sku_id',        v_sku_id,
    'campaign_id',   v_campaign_id,
    'campaign_no',   v_campaign_no,
    'brand_id',      v_brand_id,
    'brand_name',    v_brand_name
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_open_campaign_from_candidate(BIGINT, DATE, TEXT, TIMESTAMPTZ, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_open_campaign_from_candidate(BIGINT, DATE, TEXT, TIMESTAMPTZ, DATE) TO authenticated;

COMMENT ON FUNCTION public.rpc_open_campaign_from_candidate(BIGINT, DATE, TEXT, TIMESTAMPTZ, DATE) IS
  '候選池一鍵開團：排程（帶來源品牌）→ 啟用商品/規格 → 守衛（要有 active SKU、每個都要有 > 0 的現售價）→ 建團。'
  '整支是一個交易，任一步失敗該筆完整回滾；品牌由 community_channel_brands 於伺服器端解析，不收前端傳值。';
