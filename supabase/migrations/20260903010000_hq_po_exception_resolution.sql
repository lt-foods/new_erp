-- ============================================================================
-- 2026-09-02（收件匣減法案 · 刀 1 ＋ 刀 6）：
--   三類「進貨」異常給處理鈕與處理紀錄；⚠️ 徽章不再算「總倉進貨過量」
--
-- 老闆 2026-09-02 逐條裁示（原話整理見 需求暨計畫_收件匣減法案_2026-09-02.md §刀1/§刀6）：
--   進貨短少 → 改叫「總倉進貨少給」，配「廠商補寄」「廠商不補」兩顆，兩顆都要留紀錄；
--              補寄＝記錄追蹤、留在待辦直到補到；不補＝結案消失。
--   進貨破損 → 改叫「總倉進貨破損」，配「通知廠商」一顆＝記錄已通知＋結案。
--   過量進貨 → 改叫「總倉進貨過量」，**無鈕**（純紀錄，錢月結自動多收），
--              且**不計入 ⚠️ 紅色數字**（刀 6）。
--
-- ----------------------------------------------------------------------------
-- ⭐ 為什麼要新開一張表，而不是沿用 transfer_items.shortage_resolution
--
--   短收／多收（transfer_short / transfer_over）掛在 transfer_items 上，那條路不動。
--   但「進貨」三類的身分**不是 transfer_item**：
--     - po_shortage / po_over 是 **po_item_id** 層級（v_hq_exceptions 用
--       SELECT DISTINCT po_item_id, … 產列，見下方 §3 的 pd 子查詢）。
--       ⚠️ 第一版誤用 (po_id, sku_id) 當身分，被阿審判 P0-1：
--       purchase_order_items **沒有 (po_id, sku_id) 唯一約束**（20260422120004 建表全文），
--       同一張 PO 開兩行同 SKU 時兩行會共用同一個 row_key，處理一行會誤消另一行。
--       ⇒ 現在一行一個身分。
--     - po_damage 是 goods_receipt_items.id 層級。
--   三種鍵不同，硬塞進同一張既有表會做出對不齊的資料。
--
--   ⇒ 用 v_hq_exceptions **自己已經產出的 row_key** 當身分（不新發明 ID 體系），
--     欄位名逐字比照 shortage_resolution / _at / _by / _notes 那一組，
--     刀 7 的紀錄頁兩邊才長得一樣。
--
-- ----------------------------------------------------------------------------
-- ⚠️⚠️ 事實查核：現行畫面那句「PO 已關單,差額不會到」**是錯的**
--
--   qty_shortage 的定義（v_picking_demand_by_po 最新版
--   20260818000030_wave_transfer_join_by_id.sql:244-247）：
--       CASE WHEN ps.po_status = 'fully_received' AND gr_qty < qty_ordered
--            THEN qty_ordered - gr_qty ELSE 0 END
--   ⇒ 條件是 **fully_received**，不是 closed。
--   而該 view 的 PO 白名單（同檔 :77）只有 sent / partially_received / fully_received
--   ⇒ **PO 一旦變成 closed，這一列根本不會出現在異常清單裡。**
--   ⇒ 畫面卻寫「已關單」＝ 一句對不上系統事實的話。本檔照事實改寫成白話。
--   （這也是需求單「已結案的列拿掉『前往 →』」的判準來源：
--     po_shortage 這一類**全部**都是「已標成收完了」，所以整類拿掉；
--     po_over / po_damage 不受這個條件限制，前往鈕保留。）
--
-- ----------------------------------------------------------------------------
-- 「廠商補寄＝留在待辦直到補到」怎麼做到的（⭐ 零額外機制）
--   廠商真的補送、有人收貨 → goods_receipt_items.qty_received 增加
--   → gr_qty 上升 → qty_shortage 變 0 → **這一列本來就會自己從 view 消失**。
--   ⇒ 「補寄」只寫紀錄、**不寫 closed_at**，它自然會在補到那天消失。
--   ⇒ 廠商最後沒補的出口：同一列再按一次「廠商不補」即結案（RPC 走 UPSERT）。
--
-- 基底版本（append-only，皆為現行最新版，已用標準查法確認）：
--   v_hq_exceptions   = 20260824020000_receive_allocate_rework.sql:1380-1558（共 4 版）
--   rpc_hq_exceptions = 20260824020000_receive_allocate_rework.sql:1633-1684（共 2 版；
--                       線上真身是 4 參數版，3 參數版已於該檔 DROP）
--   本檔逐字保留兩者全文，改動只有下列各段註解標「⬅ 本次」的地方。
--
-- Rollback：
--   1. CREATE OR REPLACE VIEW / FUNCTION 回 20260824020000 的兩段全文；
--      ⚠️ view 要先 DROP 再建（本檔在尾端加了 2 欄，CREATE OR REPLACE 減不回去）：
--        DROP VIEW public.v_hq_exceptions;  再貼 20260824020000:1380-1558。
--   2. DROP FUNCTION public.rpc_resolve_hq_po_exception(TEXT, TEXT, TEXT, UUID);
--   3. DROP TABLE public.hq_exception_resolutions;（留著也無害，view 不再 join 它）
--
-- ----------------------------------------------------------------------------
-- ⭐⭐ 2026-09-03 重定基（Alex #898~#904 已上線）—— 本檔對新 main 逐一重驗過：
--
--   ① **基底沒變**：v_hq_exceptions 與 rpc_hq_exceptions 的最新定義**仍然是
--      20260824020000**。用標準查法對新 main 確認過：
--        git grep -lnE "CREATE (OR REPLACE )?VIEW (public\.)?v_hq_exceptions" main -- supabase/migrations
--        git grep -lnE "FUNCTION (public\.)?rpc_hq_exceptions" main -- supabase/migrations
--      Alex 這波 7 支 migration **一支都沒有重建它們** ⇒ 本檔照舊安全。
--
--   ② **不需要為 reject_return 改 view**（盤點原本擔心的那一條，實際查完不成立）：
--      Alex 的 reject_return 會把 qty_received 補成 qty_shipped，所以「派出 − 實收」
--      對處理過的列會算出 0（他 2026-09-03 寫進 CLAUDE.md 的那條規矩）。
--      **但本檔的 view 兩個 transfer 分支都要求 `ti.shortage_resolution IS NULL`**
--      （或 replenish 且還沒補到，見下方 §3 那兩段的 WHERE）
--      ⇒ 被處理過的列**根本不會出現在 view 裡**，view 永遠不會對它算那個減法。
--      ⚠️ 真正會踩到那條規矩的是**紀錄頁**（讀 transfer_items 現值）——
--        那一半在前端修，做法**逐字沿用 Alex 自己的寫法**
--        （ExceptionsContent.tsx 錨點 `const baseRecv =`：reject_return 的列改讀
--          shortage_prev_qty_received）。⛔ 不要另創第二套算法。
--
--   ③ **檔號改過**：原本是 20260902060000，改成 20260903010000 ——
--      要排在 Alex 的 20260903000200 之後，repo 從零重放的順序才對
--      （他那支動了 transfer_items 的 CHECK 與 rpc_resolve_transfer_item_shortage）。
--      ⚠️ 本檔與他那些完全不重疊（本檔不碰 transfer_items、不碰那支函式）。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 處理紀錄表
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.hq_exception_resolutions (
  id             BIGSERIAL PRIMARY KEY,
  tenant_id      UUID        NOT NULL,
  -- v_hq_exceptions.row_key 逐字（po-short-<po_item_id> / po-over-<po_item_id> / po-dmg-<gr_item_id>）
  -- ⚠️ 前兩種在第一版是 <po_id>:<sku_id>，阿審 P0-1 後改成 po_item_id（見檔頭）。
  row_key        TEXT        NOT NULL,
  exception_type TEXT        NOT NULL CHECK (exception_type IN ('po_shortage','po_damage','po_over')),
  -- 欄位名逐字比照 transfer_items.shortage_resolution 那一組
  resolution     TEXT        NOT NULL CHECK (resolution IN
                   ('vendor_reship','vendor_no_reship','vendor_notified')),
  resolution_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolution_by  UUID,
  resolution_notes TEXT,
  -- 有值＝結案，該列從 v_hq_exceptions 消失。
  -- vendor_reship 刻意留 NULL（留在待辦追蹤，補到了 view 自己會讓它消失）。
  closed_at      TIMESTAMPTZ,
  -- 反查用：紀錄頁要顯示單號／品名，view 消失後就查不回來了
  -- ⚠️ po_item_id 是 po_shortage/po_over 的**身分本身**（row_key 就是由它組的，
  --   見阿審 P0-1），這裡存一份是為了不必再去 parse row_key。
  po_item_id     BIGINT,
  po_id          BIGINT,
  sku_id         BIGINT,
  gr_item_id     BIGINT,
  doc_no         TEXT,
  sku_label      TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT hq_exception_resolutions_key_uniq UNIQUE (tenant_id, row_key)
);

CREATE INDEX IF NOT EXISTS idx_hq_exc_res_tenant_at
  ON public.hq_exception_resolutions (tenant_id, resolution_at DESC);

COMMENT ON TABLE public.hq_exception_resolutions IS
  '總倉收件匣「進貨」三類異常的處理紀錄（2026-09-02 刀 1）。'
  '身分＝v_hq_exceptions.row_key。closed_at 有值＝結案、該列從異常清單消失；'
  'vendor_reship 刻意不結案 —— 廠商補到貨時 qty_shortage 歸零，view 自己會讓它消失。'
  '短收／多收不走這張表，它們仍在 transfer_items.shortage_resolution。';

COMMENT ON COLUMN public.hq_exception_resolutions.resolution IS
  'vendor_reship=廠商補寄(追蹤中,不結案)/vendor_no_reship=廠商不補(結案)/vendor_notified=已通知廠商(結案)';

ALTER TABLE public.hq_exception_resolutions ENABLE ROW LEVEL SECURITY;

-- 讀開給登入者（收件匣異常頁與紀錄頁要看）；寫入只走下面那支 SECURITY DEFINER RPC。
-- 樣板逐字沿用 20260824000100_order_transfer_links.sql:67-72。
DROP POLICY IF EXISTS auth_read_hq_exception_resolutions ON public.hq_exception_resolutions;
CREATE POLICY auth_read_hq_exception_resolutions
  ON public.hq_exception_resolutions FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

GRANT SELECT ON public.hq_exception_resolutions TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. 寫入 RPC
--    角色守衛逐字比照 rpc_ack_transfer_over（20260824020000 該段）：
--    app_metadata.role 不在管理層（owner/admin/hq_manager/''）才擋。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_resolve_hq_po_exception(
  p_row_key    TEXT,
  p_resolution TEXT,
  p_notes      TEXT,
  p_operator   UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role     TEXT;
  v_tenant     UUID;
  v_type       TEXT;
  v_po_item_id BIGINT;   -- ⬅ 阿審 P0-1
  v_po_id    BIGINT;
  v_sku_id   BIGINT;
  v_gri_id   BIGINT;
  v_doc_no   TEXT;
  v_label    TEXT;
  v_closed   TIMESTAMPTZ;
  v_id       BIGINT;
BEGIN
  v_role := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  IF v_role NOT IN ('owner','admin','hq_manager','') THEN
    RAISE EXCEPTION 'insufficient_role';
  END IF;

  IF p_resolution NOT IN ('vendor_reship','vendor_no_reship','vendor_notified') THEN
    RAISE EXCEPTION 'invalid resolution: %', p_resolution;
  END IF;

  -- row_key 反解：三種前綴各自對回實體，順便把單號／品名撈起來存著
  -- （結案之後那一列會從 view 消失，不存就再也查不回來）
  IF p_row_key LIKE 'po-dmg-%' THEN
    v_type   := 'po_damage';
    v_gri_id := NULLIF(SPLIT_PART(p_row_key, 'po-dmg-', 2), '')::BIGINT;
    SELECT gr.tenant_id, gr.po_id, gri.sku_id, gr.gr_no,
           COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''),
             '品項#' || gri.sku_id::TEXT)
      INTO v_tenant, v_po_id, v_sku_id, v_doc_no, v_label
      FROM goods_receipt_items gri
      JOIN goods_receipts gr ON gr.id = gri.gr_id
      LEFT JOIN skus s ON s.id = gri.sku_id
     WHERE gri.id = v_gri_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這筆進貨明細（%）', p_row_key;
    END IF;
    IF p_resolution <> 'vendor_notified' THEN
      RAISE EXCEPTION '「總倉進貨破損」只能按「通知廠商」（收到 %）', p_resolution;
    END IF;

  ELSIF p_row_key LIKE 'po-short-%' OR p_row_key LIKE 'po-over-%' THEN
    v_type := CASE WHEN p_row_key LIKE 'po-short-%' THEN 'po_shortage' ELSE 'po_over' END;
    -- ⬅ 阿審 P0-1：row_key 現在是 po-short-<po_item_id> / po-over-<po_item_id>，
    --   反解出 po_item_id，po_id / sku_id 一律從 purchase_order_items 查回來，
    --   ⛔ 不再從字串裡拆（拆出來的 sku_id 無法分辨同 PO 同 SKU 的兩行）。
    v_po_item_id := NULLIF(
      SPLIT_PART(p_row_key, CASE WHEN v_type = 'po_shortage' THEN 'po-short-' ELSE 'po-over-' END, 2),
      '')::BIGINT;
    SELECT po.tenant_id, po.po_no, poi.po_id, poi.sku_id,
           COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'')
             || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''),
             '品項#' || poi.sku_id::TEXT)
      INTO v_tenant, v_doc_no, v_po_id, v_sku_id, v_label
      FROM purchase_order_items poi
      JOIN purchase_orders po ON po.id = poi.po_id
      LEFT JOIN skus s ON s.id = poi.sku_id
     WHERE poi.id = v_po_item_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '找不到這筆採購明細（%）', p_row_key;
    END IF;
    -- 「總倉進貨過量」老闆定為無鈕（純紀錄）⇒ 後端一併擋，避免以後有人接錯線
    IF v_type = 'po_over' THEN
      RAISE EXCEPTION '「總倉進貨過量」不需要處理，這一類沒有按鈕';
    END IF;
    IF p_resolution NOT IN ('vendor_reship','vendor_no_reship') THEN
      RAISE EXCEPTION '「總倉進貨少給」只能按「廠商補寄」或「廠商不補」（收到 %）', p_resolution;
    END IF;

  ELSE
    RAISE EXCEPTION '不認得的異常列（%）—— 這支只處理進貨三類', p_row_key;
  END IF;

  IF COALESCE(auth.jwt() ->> 'tenant_id', '') <> ''
     AND (auth.jwt() ->> 'tenant_id')::UUID <> v_tenant THEN
    RAISE EXCEPTION 'exception row not in current tenant';
  END IF;

  -- 廠商補寄＝追蹤中，不結案（見檔頭）；其餘兩顆結案
  v_closed := CASE WHEN p_resolution = 'vendor_reship' THEN NULL ELSE NOW() END;

  INSERT INTO hq_exception_resolutions (
    tenant_id, row_key, exception_type, resolution, resolution_at,
    resolution_by, resolution_notes, closed_at,
    po_item_id, po_id, sku_id, gr_item_id, doc_no, sku_label
  ) VALUES (
    v_tenant, p_row_key, v_type, p_resolution, NOW(),
    p_operator, NULLIF(TRIM(p_notes), ''), v_closed,
    v_po_item_id, v_po_id, v_sku_id, v_gri_id, v_doc_no, v_label
  )
  ON CONFLICT (tenant_id, row_key) DO UPDATE
     SET resolution       = EXCLUDED.resolution,
         resolution_at    = EXCLUDED.resolution_at,
         resolution_by    = EXCLUDED.resolution_by,
         resolution_notes = EXCLUDED.resolution_notes,
         -- 補寄 → 不補：closed_at 從 NULL 變成有值（這是刻意允許的改判）
         closed_at        = EXCLUDED.closed_at,
         doc_no           = EXCLUDED.doc_no,
         sku_label        = EXCLUDED.sku_label,
         updated_at       = NOW()
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id,
    'row_key', p_row_key,
    'type', v_type,
    'resolution', p_resolution,
    'closed', v_closed IS NOT NULL
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_resolve_hq_po_exception(TEXT, TEXT, TEXT, UUID)
  TO authenticated;

COMMENT ON FUNCTION public.rpc_resolve_hq_po_exception(TEXT, TEXT, TEXT, UUID) IS
  '總倉收件匣「進貨」三類異常的處理（2026-09-02 刀 1）。'
  'po_shortage：vendor_reship（廠商補寄，不結案、留在待辦追蹤）／vendor_no_reship（廠商不補，結案）。'
  'po_damage：vendor_notified（已通知廠商，結案）。'
  'po_over：無鈕，後端一併擋下。同一列可重按（UPSERT），補寄→不補是刻意允許的改判。';

-- ----------------------------------------------------------------------------
-- 3. v_hq_exceptions —— 20260824020000:1380-1558 逐字，改動：
--      ⬅ 本次 a：進貨少給/過量、進貨破損兩段各 LEFT JOIN 處理紀錄、排除已結案
--      ⬅ 本次 b：「PO 已關單,差額不會到」改成照事實的白話（見檔頭事實查核）
--      ⬅ 本次 c：尾端加 hq_resolution / hq_resolution_at 兩欄（5 段都要加，
--                 UNION ALL 的欄數必須一致；後三段填 NULL）
--    ⚠️ CREATE OR REPLACE VIEW 只能在尾端加欄位 —— 新欄位刻意放最後兩個。
--    ⭐ 刻意**不用 DROP VIEW**：CREATE OR REPLACE 在「既有 25 欄的名稱／型別／順序
--       有任何一處被我改到」時會直接報錯，等於免費多一道自我檢查；
--       DROP 則會安靜接受任何改動，還要冒著砍掉沒查到的相依物的風險。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_hq_exceptions AS
-- 1+3. 進貨短少 / 過量進貨（同一次掃描，用 qty_shortage 決定 type）
SELECT
  CASE WHEN pd.qty_shortage > 0 THEN 'po_shortage' ELSE 'po_over' END::text AS type,
  -- ⚠️⚠️ 2026-09-02 阿審 P0-1：身分鍵一定要用 **po_item_id**，不可以用 po_id:sku_id。
  --   v_picking_demand_by_po 的粒度是 po_item_id（20260818000030，錨點 `poi.id AS po_item_id`），
  --   而 purchase_order_items **沒有 (po_id, sku_id) 唯一約束**（20260422120004 建表全文）
  --   ⇒ 同一張採購單同一個品項開兩行時，兩行會共用同一個 row_key，
  --     處理其中一行會把另一行也一起濾掉（誤刪）。
  --   ⇒ 一行一個身分，處理哪行就只消哪行。
  (CASE WHEN pd.qty_shortage > 0 THEN 'po-short-' ELSE 'po-over-' END
    || pd.po_item_id::text)                                                 AS row_key,
  po.created_at                                                             AS ts,
  pd.po_no                                                                  AS doc_no,
  pd.sku_code,
  pd.sku_label,
  pd.qty_ordered::numeric                                                   AS expected,
  pd.gr_qty                                                                 AS actual,
  CASE WHEN pd.qty_shortage > 0 THEN pd.qty_shortage
       ELSE pd.gr_qty - pd.qty_ordered END                                  AS diff,
  NULL::text                                                                AS reason,
  -- ⬅ 本次 b：照事實寫。qty_shortage > 0 的條件是 po_status='fully_received'
  --    （20260818000030:244-247），不是 closed —— closed 根本不在該 view 的
  --    白名單裡（同檔 :77），所以這裡永遠不可能是「已關單」的單。
  CASE WHEN pd.qty_shortage > 0
       THEN '這張採購單已經標成「收完了」，少的 '
            || trim_scale(pd.qty_shortage)::text || ' 件不會再進來'
       ELSE '供應商多送或重複入庫' END::text                                 AS extra,
  NULL::bigint                                                              AS transfer_item_id,
  NULL::bigint                                                              AS transfer_id,
  NULL::text                                                                AS transfer_no,
  pd.sku_id,
  NULL::numeric                                                             AS qty_shipped,
  NULL::numeric                                                             AS qty_received,
  NULL::numeric                                                             AS shortage_qty,
  NULL::bigint                                                              AS dest_location,
  NULL::bigint                                                              AS dest_store_id,
  NULL::text                                                                AS dest_store_name,
  NULL::bigint                                                              AS customer_order_id,
  NULL::text                                                                AS shortage_resolution,
  pd.po_id                                                                  AS doc_id,
  (SELECT l.name FROM locations l WHERE l.id = po.dest_location_id)         AS warehouse_name,
  r.resolution                                                              AS hq_resolution,      -- ⬅ 本次 c
  r.resolution_at                                                           AS hq_resolution_at    -- ⬅ 本次 c
FROM (
  -- ⬅ 阿審 P0-1：DISTINCT 清單補 po_item_id。
  --   ⚠️ 副作用（刻意的、要知道）：以前「同 PO 同 SKU 兩行、而且訂量與已收量剛好都一樣」
  --     會被 DISTINCT 併成一列，現在會正確地拆成兩列 ⇒ **異常筆數可能變多**。
  --     那本來就是兩筆各自獨立的短少，拆開才對，也才處理得了。
  --   ⚠️ 仍然不帶 store_id：該 view 是 (po_item_id × store) 粒度，
  --     進貨異常跟「派給哪家店」無關，帶了會一筆變好幾筆。
  SELECT DISTINCT po_item_id, po_id, sku_id, po_no, sku_code, sku_label, qty_ordered, gr_qty, qty_shortage
  FROM public.v_picking_demand_by_po
  WHERE qty_shortage > 0 OR gr_qty > qty_ordered
) pd
LEFT JOIN public.purchase_orders po ON po.id = pd.po_id
-- ⬅ 本次 a
LEFT JOIN public.hq_exception_resolutions r
       ON r.row_key = (CASE WHEN pd.qty_shortage > 0 THEN 'po-short-' ELSE 'po-over-' END
                        || pd.po_item_id::text)
      AND r.tenant_id = po.tenant_id
WHERE r.closed_at IS NULL   -- ⬅ 本次 a：結案的不再列出（沒紀錄時 r.* 全 NULL，照樣通過）

UNION ALL

-- 2. 進貨破損
SELECT
  'po_damage'::text,
  'po-dmg-' || gri.id::text,
  gr.created_at,
  gr.gr_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || gri.sku_id::text),
  gri.qty_received::numeric,
  gri.qty_received - gri.qty_damaged,
  gri.qty_damaged::numeric,
  gri.variance_reason,
  '已收 ' || gri.qty_received::text || ' 含瑕疵 ' || gri.qty_damaged::text,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  gri.sku_id,
  NULL::numeric,
  NULL::numeric,
  NULL::numeric,
  NULL::bigint,
  NULL::bigint,
  NULL::text,
  NULL::bigint,
  NULL::text,
  gr.po_id,
  (SELECT l.name FROM locations l WHERE l.id = gr.dest_location_id),
  r.resolution,      -- ⬅ 本次 c
  r.resolution_at    -- ⬅ 本次 c
FROM public.goods_receipt_items gri
JOIN public.goods_receipts gr ON gr.id = gri.gr_id
LEFT JOIN public.skus s ON s.id = gri.sku_id
-- ⬅ 本次 a
LEFT JOIN public.hq_exception_resolutions r
       ON r.row_key = 'po-dmg-' || gri.id::text
      AND r.tenant_id = gr.tenant_id
WHERE gri.qty_damaged > 0
  AND gr.status = 'confirmed'
  AND r.closed_at IS NULL   -- ⬅ 本次 a：按過「通知廠商」就消失（C3 結構性殭屍的出口）

UNION ALL

-- 4. 收貨短少（轉貨 received 但實收 < 出貨；已標補出貨但還沒補到的也繼續列）
SELECT
  'transfer_short'::text,
  'tshort-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  CASE WHEN NULLIF(TRIM(COALESCE(t.notes,'')), '') IS NOT NULL
       THEN '店家收貨備註：' || TRIM(t.notes) ELSE NULL END,
  (CASE WHEN COALESCE(ti.damage_qty, 0) > 0 THEN '含破損 ' || ti.damage_qty::text
        ELSE '分店少收或運送中遺失' END)
  || (CASE WHEN ti.shortage_resolution = 'replenish' THEN ' · 已標補出貨,尚未補到' ELSE '' END),
  ti.id,
  ti.transfer_id,
  t.transfer_no,
  ti.sku_id,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  t.dest_location,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  NULL::text,
  ti.transfer_id,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::text,        -- ⬅ 本次 c（這一類的處理紀錄在 transfer_items，不走新表）
  NULL::timestamptz  -- ⬅ 本次 c
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.qty_received < ti.qty_shipped
  AND (
    ti.shortage_resolution IS NULL
    OR (
      ti.shortage_resolution = 'replenish'
      AND COALESCE((
        SELECT SUM(ti2.qty_received)
        FROM public.transfers t2
        JOIN public.transfer_items ti2 ON ti2.transfer_id = t2.id
        WHERE t2.dest_location = t.dest_location
          AND t2.tenant_id = t.tenant_id
          AND ti2.sku_id = ti.sku_id
          AND t2.status IN ('received', 'closed')
          AND COALESCE(t2.received_at, t2.updated_at) > ti.shortage_resolution_at
      ), 0) < (ti.qty_shipped - ti.qty_received)
    )
  )
UNION ALL

-- 5. 收貨多收（20260824020000：轉貨 received 且實收 > 出貨 —— 店家照實收，
--    差異回報總倉；HQ 按「知道了」(shortage_resolution='over_ack') 收掉）
SELECT
  'transfer_over'::text,
  'tover-' || ti.id::text,
  COALESCE(t.received_at, t.created_at),
  t.transfer_no,
  s.sku_code,
  COALESCE(NULLIF(TRIM(COALESCE(s.product_name,'') || COALESCE(' / ' || NULLIF(s.variant_name,''), '')), ''), '品項#' || ti.sku_id::text),
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_received - ti.qty_shipped,
  CASE WHEN NULLIF(TRIM(COALESCE(t.notes,'')), '') IS NOT NULL
       THEN '店家收貨備註：' || TRIM(t.notes) ELSE NULL END,
  '分店實收多於派出（總倉多裝或撿貨誤差），貨已入分店帳'::text,
  ti.id,
  ti.transfer_id,
  t.transfer_no,
  ti.sku_id,
  ti.qty_shipped::numeric,
  ti.qty_received::numeric,
  ti.qty_shipped - ti.qty_received,
  t.dest_location,
  (SELECT ds.id FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::bigint,
  ti.shortage_resolution,
  ti.transfer_id,
  COALESCE(
    (SELECT ds.name FROM public.stores ds WHERE ds.location_id = t.dest_location ORDER BY ds.id LIMIT 1),
    (SELECT l.name FROM public.locations l WHERE l.id = t.dest_location),
    '位置 #' || COALESCE(t.dest_location::text, '?')
  ),
  NULL::text,        -- ⬅ 本次 c
  NULL::timestamptz  -- ⬅ 本次 c
FROM public.transfer_items ti
JOIN public.transfers t ON t.id = ti.transfer_id
LEFT JOIN public.skus s ON s.id = ti.sku_id
WHERE t.status = 'received'
  AND ti.qty_received > ti.qty_shipped
  AND ti.shortage_resolution IS NULL;

GRANT SELECT ON public.v_hq_exceptions TO authenticated;

COMMENT ON VIEW public.v_hq_exceptions IS
  '總倉收件匣異常統一 view:union 進貨短少/破損/過量/收貨短少/收貨多收 5 來源為扁平列,'
  '供 rpc_hq_exceptions 做 server-side 分頁與計數。'
  'warehouse_name = 該筆異常的地點（PO/GR 收貨倉、收貨分店），前端畫成「地點」欄。'
  'transfer_over(20260824020000)=分店實收多於派出,HQ 按「知道了」(over_ack)收掉。'
  '20260903010000 起:進貨三類 LEFT JOIN hq_exception_resolutions,closed_at 有值就不列;'
  'hq_resolution/_at 兩欄讓畫面顯示「已請廠商補寄，追蹤中」。';

-- ----------------------------------------------------------------------------
-- 4. rpc_hq_exceptions —— 20260824020000:1633-1684 逐字，只在 counts 加一個 key
--      ⬅ 刀 6：「總倉進貨過量」不計入 ⚠️ 紅色數字（老闆 2026-09-02：可以）。
--
--    ⚠️⚠️ 2026-09-02 阿審 P0-4 訂正（第一版我做錯了）：
--      第一版是把 counts.all 直接改成「排除 po_over」。那會讓三個數字互相打臉：
--        · 「全部」分頁**列得出** po_over 的列，標籤卻用扣掉它的數字
--        · 頁首「共 N 筆異常」跟旁邊五個分類數字**加不起來**
--        · total（受 p_type 影響）仍含 po_over
--      ⇒ 正解是**兩個數字分開命名**，不要讓同一個 key 身兼二職：
--        counts.all   = 全部列數（**回復原意**，跟「全部」分頁列的東西一致）
--        counts.badge = ⚠️ 紅字用（排除 po_over）← 新增
--      前端各取所需（見 ExceptionsContent 的 onCountChange 與頁首）。
--    ⚠️ counts.po_over 照舊回真實筆數 —— 分頁籤上那個小數字還是要顯示。
--    ⚠️ 'total' 一個字都不動。
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rpc_hq_exceptions(
  p_type      text DEFAULT NULL,
  p_page      int  DEFAULT 1,
  p_page_size int  DEFAULT 20,
  p_search    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH ex AS MATERIALIZED (
    SELECT * FROM public.v_hq_exceptions
    WHERE (NULLIF(TRIM(p_search), '') IS NULL
           OR doc_no ILIKE '%' || TRIM(p_search) || '%'
           OR sku_code ILIKE '%' || TRIM(p_search) || '%'
           OR sku_label ILIKE '%' || TRIM(p_search) || '%'
           OR warehouse_name ILIKE '%' || TRIM(p_search) || '%')
  ),
  filtered AS (
    SELECT * FROM ex
    WHERE (p_type IS NULL OR p_type = 'all' OR ex.type = p_type)
  ),
  page AS (
    SELECT * FROM filtered
    ORDER BY ts DESC NULLS LAST, row_key
    LIMIT  GREATEST(1, p_page_size)
    OFFSET GREATEST(0, (p_page - 1) * p_page_size)
  )
  SELECT jsonb_build_object(
    'total', (SELECT COUNT(*) FROM filtered),
    'counts', (
      SELECT jsonb_build_object(
        -- 'all' ＝ 全部列數（原意，跟「全部」分頁列的東西一致）⛔ 不要再動它
        'all',               COUNT(*),
        -- ⬅ 刀 6（阿審 P0-4 訂正後）：'badge' 才是 ⚠️ 紅字的口徑 ⇒ 排除 po_over。
        --   ⭐ 它剛好等於下面四個分類數字的和 —— 這是刻意的：
        --     使用者要能拿畫面上的數字自己心算對上，對不上就是畫面在說謊。
        'badge',             COUNT(*) FILTER (WHERE type <> 'po_over'),
        'po_shortage',       COUNT(*) FILTER (WHERE type = 'po_shortage'),
        'po_damage',         COUNT(*) FILTER (WHERE type = 'po_damage'),
        'po_over',           COUNT(*) FILTER (WHERE type = 'po_over'),
        'transfer_short',    COUNT(*) FILTER (WHERE type = 'transfer_short'),
        'transfer_over',     COUNT(*) FILTER (WHERE type = 'transfer_over'),
        'customer_shortage', COUNT(*) FILTER (WHERE type = 'customer_shortage')
      )
      FROM ex
    ),
    'rows', (
      SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY ts DESC NULLS LAST, row_key), '[]'::jsonb)
      FROM page
    )
  );
$$;

GRANT EXECUTE ON FUNCTION public.rpc_hq_exceptions(text, int, int, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_hq_exceptions(text, int, int, text) IS
  '總倉收件匣異常的 server-side 分頁與計數。'
  '20260903010000 起(刀 6)新增 counts.badge = 排除 po_over 的筆數,供 ⚠️ 紅字使用'
  '(＝四個「要動手」分類的和,使用者可以自己心算對上);'
  'counts.all 維持原意=全部列數(與「全部」分頁列的東西一致),total 與 po_over 皆不受影響。';
