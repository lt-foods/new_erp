-- ============================================================================
--  01 預覽（只查不改：整份只有一句查詢）
--  限量團超賣：三團一次取消 73 張超賣訂單（＋辣椒醬 0040 那張轉出單，見下方「轉入單」）
--    GRP-20261015-024 洗面乳（上限 6）　GRP-20261016-048 辣椒醬（上限 34）　GRP-20261021-018 微燻李（上限 22）
--  日期：2026-10-28　阿寫寫
--  名單出處：公司\01_進行中\超賣名單_洗面乳辣椒醬微燻李_與全站掃描_2026-10-28.md
--  ⛔ 輸出不列客人姓名、電話、會員編號（只列團、門市、訂單號、狀態、件數、金額）
-- ============================================================================
--  各段在看什麼
--    ⓪ 對象：三個團各剛好一個、上限是不是 6／34／22、三團是同一家公司
--    ① 要取消的 73 張（42＋17＋14；需求單寫 72 是加總筆誤），一張一列：團、單號、店、件數、狀態、儲值金、是不是轉入單
--       ＋ 0040（辣椒醬 TF0001 的原單）：02 取消 TF0001 時它會被系統復活，02 會接著取消它
--       ⚠ 這份只收 待確認／已確認：有任何一張出貨中（或其他狀態）打 ❌，02 會停、改人工處理
--    ② 檢查：名單 73 張都找得到、件數合計、保留的 48 張逐張都在且有效（張數＋件數）、名單外有沒有新冒出來的有效單、
--       三團取消後預估剩多少件（應為 5／34／21；老闆之後各補 1 件 → 6／34／22）
--    ③ 儲值金：會自動退幾張、多少錢；付過錢但不是儲值金的（不會自動退）
--    ④ 轉入單 TF0001 與原單 0040：復活後會不會直接變「可取貨」（會的話 02 會停）、會不會撞「一人一團一張」
--    ⑤ 02 做過了沒
--    ⑥ 操作人候選：這家公司的總部帳號（老闆認出自己那一列，把那串 UUID 交給 CEO 填進 02／05）
--  「結果」欄：✅ 符合預期　❌ 跟預期不同（先停，截圖給 CEO；有任何一列 ❌ 就不要貼 02）　ℹ 參考　⚠ 要注意
--  「有效」的算法＝超賣名單那支查詢＝商城／後台上限檢查的算法：
--    單頭不是 已取消／已過期／已轉出、品項不是 已取消／已過期
--    （rpc_place_member_order_guarded 20261013000000:1220-1221、:1253-1254；
--     PR #1094 _campaign_cap_remaining 20261028000000:176-177）
-- ============================================================================
WITH
param AS (
  SELECT '限量超賣：2026-10-28 老闆核准批次取消'::text AS tag
),
lst AS (   -- 名單（kind：cancel＝要取消的 73 張；follow＝0040 轉出單，02 取消 TF0001 後接著取消；keep＝保留）
  SELECT 'GRP-20261015-024'::text AS campaign_no, 'GRP-20261015-024-' || lpad(n::text, 4, '0') AS order_no, 'cancel'::text AS kind
    FROM generate_series(6, 46) n
  UNION ALL SELECT 'GRP-20261015-024', 'GRP-20261015-024-INT0047', 'cancel'
  UNION ALL
  SELECT 'GRP-20261016-048', 'GRP-20261016-048-' || lpad(n::text, 4, '0'), 'cancel'
    FROM generate_series(27, 43) n WHERE n <> 40
  UNION ALL SELECT 'GRP-20261016-048', 'GRP-20261016-048-TF0001', 'cancel'
  UNION ALL SELECT 'GRP-20261016-048', 'GRP-20261016-048-0040', 'follow'
  UNION ALL
  SELECT 'GRP-20261021-018', 'GRP-20261021-018-' || lpad(n::text, 4, '0'), 'cancel'
    FROM generate_series(18, 31) n
  UNION ALL
  SELECT 'GRP-20261015-024', 'GRP-20261015-024-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 5) n
  UNION ALL
  SELECT 'GRP-20261016-048', 'GRP-20261016-048-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 26) n
  UNION ALL
  SELECT 'GRP-20261021-018', 'GRP-20261021-018-' || lpad(n::text, 4, '0'), 'keep' FROM generate_series(1, 17) n
),
exp AS (   -- 每團：上限、要取消幾張、保留的單應有幾件、取消後預估剩幾件
  SELECT * FROM (VALUES
    ('GRP-20261015-024', '洗面乳', 6::numeric, 42, 5::numeric, 5),
    ('GRP-20261016-048', '辣椒醬', 34::numeric, 17, 34::numeric, 26),
    ('GRP-20261021-018', '微燻李', 22::numeric, 14, 21::numeric, 17)
  ) v(campaign_no, label, cap, n_cancel, after_qty, n_keep)
),
cp AS (
  SELECT c.id, c.tenant_id, c.campaign_no, c.status, c.total_cap_qty,
         COALESCE(NULLIF(c.total_cap_qty, 0), (SELECT sum(ci.cap_qty) FROM public.campaign_items ci WHERE ci.campaign_id = c.id)) AS cap
    FROM public.group_buy_campaigns c
   WHERE c.campaign_no IN (SELECT campaign_no FROM exp)
),
ords AS (  -- 三團全部訂單＋有效件數
  SELECT co.id, co.order_no, co.campaign_id, cp.campaign_no, co.tenant_id, co.status, co.member_id, co.channel_id,
         co.order_kind, co.payment_status, COALESCE(co.wallet_paid_amount, 0) AS wallet,
         co.transferred_from_order_id, co.transferred_to_order_id, co.aid_board_id, co.pickup_store_id,
         COALESCE(st.name, '?') AS store_name,
         (SELECT COALESCE(sum(i.qty), 0) FROM public.customer_order_items i
           WHERE i.order_id = co.id AND i.status NOT IN ('cancelled', 'expired')) AS live_qty
    FROM public.customer_orders co
    JOIN cp ON cp.id = co.campaign_id
    LEFT JOIN public.stores st ON st.id = co.pickup_store_id
),
eff AS (   -- 現在算「有效」的單
  SELECT * FROM ords WHERE status NOT IN ('cancelled', 'expired', 'transferred_out')
),
tgt AS (   -- 名單 × 實際訂單
  SELECT l.campaign_no, l.order_no, l.kind, o.id, o.status, o.store_name, o.live_qty, o.wallet, o.payment_status,
         o.member_id, o.transferred_from_order_id, o.transferred_to_order_id, o.aid_board_id,
         m.status AS member_status, m.member_type, m.id AS member_row, m.tenant_id AS member_tenant, o.tenant_id
    FROM lst l
    LEFT JOIN ords o ON o.order_no = l.order_no AND o.campaign_no = l.campaign_no
    LEFT JOIN public.members m ON m.id = o.member_id
),
orphan AS ( -- 名單外、現在還算有效的單（例如 10/28 之後又有人加單）
  SELECT e.* FROM eff e WHERE NOT EXISTS (SELECT 1 FROM lst l WHERE l.order_no = e.order_no)
),
tf AS (    -- 轉入單 TF0001 與它的原單
  SELECT o.*, src.order_no AS src_no, src.status AS src_status, src.transferred_to_order_id AS src_to,
         src.pickup_store_id AS src_store, src.member_id AS src_member, src.channel_id AS src_channel,
         src.order_kind AS src_kind, src.id AS src_id
    FROM ords o LEFT JOIN public.customer_orders src ON src.id = o.transferred_from_order_id
   WHERE o.order_no = 'GRP-20261016-048-TF0001'
),
src_items AS ( -- 原單 0040 復活後的有效品項，各自是不是已經到店可取（全部可取 → 系統會把 0040 直接推成「可取貨」，02 就取消不了）
  SELECT i.id, i.qty, public.is_order_item_pickup_ready(i.id) AS ready
    FROM public.customer_order_items i
   WHERE i.order_id = (SELECT src_id FROM tf)
     AND i.status IN ('pending', 'reserved', 'ready')
),
tf_items AS ( -- TF0001 身上的品項（整單轉出 → 原單品項沒被動過；部分轉出 → 取消時會還回原單）
  SELECT i.status, i.source, count(*) AS n, COALESCE(sum(i.qty), 0) AS q
    FROM public.customer_order_items i WHERE i.order_id = (SELECT id FROM tf)
   GROUP BY i.status, i.source
),
src_dup AS ( -- 0040 復活回「已確認」時，同一位客人同團同頻道有沒有別張進行中的單（唯一索引 customer_orders_trio_kind_active_uniq，
             -- 條件照 20261013000000 第 1 段與 rpc_restore_cancelled_order 守衛 5 :1541-1558）。名單裡的單 02 會先取消，所以不算。
  SELECT co.order_no
    FROM public.customer_orders co, tf
   WHERE co.tenant_id = tf.tenant_id AND co.campaign_id = tf.campaign_id
     AND co.channel_id = tf.src_channel AND co.member_id = tf.src_member AND co.order_kind = tf.src_kind
     AND tf.src_kind <> 'restock'
     AND co.id <> tf.src_id
     AND co.status NOT IN ('transferred_out', 'expired', 'cancelled')
     AND co.order_no NOT LIKE 'SP-%' AND co.order_no NOT LIKE 'WS-%'
     AND co.aid_board_id IS NULL AND co.transferred_from_order_id IS NULL
     AND co.order_no NOT IN (SELECT order_no FROM lst WHERE kind = 'cancel')
),
tf_xfer AS ( -- 掛在 TF0001 上、還沒作廢的調撥單（TF0001 是「出貨中」才會被取消函式一起作廢）
  SELECT t.id, t.status FROM public.transfers t WHERE t.customer_order_id = (SELECT id FROM tf) AND t.status <> 'cancelled'
),
done AS (  -- 02 留下的編輯歷史（原因那一句是固定的）
  SELECT count(*) AS n, max(a.created_at) AS at
    FROM public.customer_order_audit_log a JOIN param p ON a.edit_reason = p.tag
   WHERE a.entity_type = 'order' AND a.field = 'status'
     AND a.order_id IN (SELECT id FROM ords)
),
ops AS (   -- 這家公司的總部帳號（認法同 02：app_metadata.tenant_id＋總部角色）
  SELECT u.id, u.email, u.last_sign_in_at, COALESCE(u.raw_app_meta_data ->> 'role', '') AS role
    FROM auth.users u
   WHERE (u.raw_app_meta_data ->> 'tenant_id') IN (SELECT tenant_id::text FROM cp)
     AND COALESCE(u.raw_app_meta_data ->> 'role', '') IN ('', 'owner', 'admin', 'hq_manager', 'hq_accountant')
)
SELECT "段落", "團", "項目", "門市", "件數", "結果", "說明"
FROM (
  -- ⓪ 對象
  SELECT 0 AS o1, 1 AS o2, '⓪ 對象'::text AS "段落", e.label AS "團", e.campaign_no AS "項目", NULL::text AS "門市",
         (SELECT cap FROM cp WHERE cp.campaign_no = e.campaign_no LIMIT 1) AS "件數",
         CASE WHEN (SELECT count(*) FROM cp WHERE cp.campaign_no = e.campaign_no) <> 1
                THEN '❌ 查到 ' || (SELECT count(*) FROM cp WHERE cp.campaign_no = e.campaign_no) || ' 個（要剛好 1 個）'
              WHEN (SELECT cap FROM cp WHERE cp.campaign_no = e.campaign_no) IS DISTINCT FROM e.cap
                THEN '❌ 上限不是 ' || trim_scale(e.cap)
              ELSE '✅ 剛好 1 個、上限 ' || trim_scale(e.cap) END AS "結果",
         COALESCE((SELECT '開團狀態 ' || status FROM cp WHERE cp.campaign_no = e.campaign_no LIMIT 1), '') AS "說明"
    FROM exp e
  UNION ALL
  SELECT 0, 2, '⓪ 對象', NULL, '三團是同一家公司', NULL, NULL,
         CASE WHEN (SELECT count(DISTINCT tenant_id) FROM cp) = 1 THEN '✅' ELSE '❌ 不是同一家（02 會停）' END, ''

  -- ① 要取消的單（一張一列）
  UNION ALL
  SELECT 1, ROW_NUMBER() OVER (ORDER BY t.campaign_no, t.order_no)::int, '① 要取消的單',
         (SELECT label FROM exp WHERE exp.campaign_no = t.campaign_no), t.order_no, t.store_name, t.live_qty,
         CASE WHEN t.id IS NULL THEN '❌ 系統裡找不到這張單'
              WHEN t.kind = 'follow' AND (SELECT status FROM tf) IS DISTINCT FROM 'cancelled' THEN
                CASE WHEN t.status = 'transferred_out' THEN '✅ 已轉出（轉成 TF0001）'
                     WHEN t.status IN ('pending', 'confirmed') THEN '✅ ' || t.status || '（部分轉出，0040 身上還有剩的品項）'
                     ELSE '❌ ' || t.status || '（這份只處理 已轉出／待確認／已確認，02 會停）' END
              WHEN t.kind = 'follow' AND t.status IN ('pending', 'confirmed') THEN '⚠ ' || t.status || '（TF0001 已有人先取消過；02 照樣取消它）'
              WHEN t.kind = 'follow' AND t.status = 'cancelled' THEN '⚠ 已經是已取消（02 會跳過）'
              WHEN t.kind = 'follow' THEN '❌ ' || t.status || '（02 會停）'
              WHEN t.status IN ('pending', 'confirmed') THEN '✅ ' || CASE t.status WHEN 'pending' THEN '待確認' ELSE '已確認' END
              WHEN t.status = 'cancelled' THEN '⚠ 已經是已取消（02 會跳過）'
              WHEN t.status = 'shipping' THEN '❌ 出貨中（取消會作廢調撥、把已出貨量入回來源端；這份不處理，02 會停，改人工）'
              ELSE '❌ ' || t.status || '（這份只收 待確認／已確認，02 會停）' END,
         CASE WHEN t.kind = 'follow' THEN '轉出原單：02 取消 TF0001 時系統會把它退回「已確認」（20260826000010:249-256），02 接著把它也取消；不算在 73 張裡'
              ELSE '' END
           || CASE WHEN t.transferred_from_order_id IS NOT NULL THEN '轉入單（從 ' || COALESCE((SELECT src_no FROM tf WHERE tf.id = t.id), '?') || ' 轉來）；' ELSE '' END
           || CASE WHEN t.order_no LIKE '%-INT%' OR t.member_type = 'store_internal' THEN '內部單；' ELSE '' END
           || CASE WHEN t.wallet > 0 THEN '用了儲值金 $' || trim_scale(t.wallet) || '，取消時自動退回；' ELSE '' END
           || CASE WHEN t.wallet = 0 AND t.payment_status = 'paid' THEN '⚠ 付過錢但不是儲值金，不會自動退；' ELSE '' END
           || CASE WHEN t.aid_board_id IS NOT NULL THEN '⚠ 互助板帶來的單，取消會把量還回互助貼文；' ELSE '' END
    FROM tgt t WHERE t.kind IN ('cancel', 'follow')

  -- ② 檢查
  UNION ALL
  SELECT 2, 1, '② 檢查', e.label, '要取消的單：找得到幾張', NULL,
         (SELECT count(*) FROM tgt WHERE tgt.campaign_no = e.campaign_no AND kind = 'cancel' AND id IS NOT NULL),
         CASE WHEN (SELECT count(*) FROM tgt WHERE tgt.campaign_no = e.campaign_no AND kind = 'cancel' AND id IS NOT NULL) = e.n_cancel
              THEN '✅ ' || e.n_cancel || ' 張' ELSE '❌ 應為 ' || e.n_cancel || ' 張' END,
         '這一欄是「張數」不是件數'
    FROM exp e
  UNION ALL
  SELECT 2, 2, '② 檢查', NULL, '要取消的單：合計', NULL,
         (SELECT COALESCE(sum(live_qty), 0) FROM tgt WHERE kind = 'cancel'),
         CASE WHEN (SELECT count(*) FROM tgt WHERE kind = 'cancel' AND id IS NOT NULL) = 73 THEN '✅ 73 張' ELSE '❌ 應為 73 張' END,
         '「件數」欄＝這 73 張現在的有效件數合計（參考）'
  UNION ALL
  SELECT 2, 3, '② 檢查', e.label, '保留的單（不動）', NULL, k.q,
         CASE WHEN k.n_found = e.n_keep AND k.n_live = e.n_keep AND k.q = e.after_qty
              THEN '✅ ' || e.n_keep || ' 張都在、都有效、合計 ' || trim_scale(e.after_qty) || ' 件'
              ELSE '❌ 應為 ' || e.n_keep || ' 張都有效、合計 ' || trim_scale(e.after_qty) || ' 件（02 會停）' END,
         '找到 ' || k.n_found || ' 張、有效 ' || k.n_live || ' 張；'
           || COALESCE('找不到：' || k.missing || '；', '')
           || COALESCE('不是有效的：' || k.dead, '')
    FROM exp e
    CROSS JOIN LATERAL (
      SELECT count(o.id) AS n_found,
             count(o.id) FILTER (WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')) AS n_live,
             COALESCE(sum(o.live_qty) FILTER (WHERE o.status NOT IN ('cancelled', 'expired', 'transferred_out')), 0) AS q,
             string_agg(o.order_no, '、') FILTER (WHERE o.id IS NULL) AS missing,
             string_agg(o.order_no || '＝' || o.status, '、') FILTER (WHERE o.status IN ('cancelled', 'expired', 'transferred_out')) AS dead
        FROM tgt o WHERE o.campaign_no = e.campaign_no AND o.kind = 'keep') k
  UNION ALL
  SELECT 2, 4, '② 檢查', NULL, '名單外、現在還算有效的單', NULL, (SELECT count(*) FROM orphan),
         CASE WHEN NOT EXISTS (SELECT 1 FROM orphan) THEN '✅ 0 張' ELSE '❌ 有，02 會停' END,
         COALESCE((SELECT string_agg(order_no || '（' || store_name || ' ' || trim_scale(live_qty) || ' 件）', '、' ORDER BY order_no) FROM orphan),
                  '10/28 查完之後沒有人再加單')
  UNION ALL
  SELECT 2, 5, '② 檢查', e.label, '取消後預估剩下的有效件數', NULL,
         (SELECT COALESCE(sum(x.live_qty), 0) FROM eff x WHERE x.campaign_no = e.campaign_no
             AND x.order_no NOT IN (SELECT order_no FROM lst WHERE kind IN ('cancel', 'follow'))),
         CASE WHEN (SELECT COALESCE(sum(x.live_qty), 0) FROM eff x WHERE x.campaign_no = e.campaign_no
                      AND x.order_no NOT IN (SELECT order_no FROM lst WHERE kind IN ('cancel', 'follow'))) = e.after_qty
              THEN '✅ ' || trim_scale(e.after_qty) || ' 件' ELSE '❌ 應為 ' || trim_scale(e.after_qty) || ' 件' END,
         '上限 ' || trim_scale(e.cap) || '。'
           || CASE WHEN e.after_qty < e.cap THEN '整張取消的那張（' || CASE e.campaign_no WHEN 'GRP-20261015-024' THEN '0006 古華' ELSE '0018 忠順' END
                    || '）原本有 1 件在上限內，老闆之後用後台加單補 1 件 → ' || trim_scale(e.cap) || ' 件（不在 02 範圍）'
                   ELSE '剛好滿' END
    FROM exp e

  -- ③ 儲值金
  UNION ALL
  SELECT 3, 1, '③ 儲值金', NULL, '用了儲值金、取消時自動退回', NULL,
         (SELECT COALESCE(sum(wallet), 0) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet > 0),
         'ℹ ' || (SELECT count(*) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet > 0) || ' 張',
         '「件數」欄這裡是金額（元）。取消鈕自己會退（rpc_wallet_refund，20260826000010:203-215）'
  UNION ALL
  SELECT 3, 2, '③ 儲值金', NULL, '要退儲值金、但沒有會員／會員不對／不是正常狀態', NULL,
         (SELECT count(*) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet > 0 AND status IS DISTINCT FROM 'cancelled'
             AND (member_id IS NULL OR member_row IS NULL OR member_tenant IS DISTINCT FROM tenant_id OR COALESCE(member_status, '') <> 'active')),
         CASE WHEN (SELECT count(*) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet > 0 AND status IS DISTINCT FROM 'cancelled'
                      AND (member_id IS NULL OR member_row IS NULL OR member_tenant IS DISTINCT FROM tenant_id OR COALESCE(member_status, '') <> 'active')) = 0
              THEN '✅ 0 張' ELSE '❌ 有（退不回去，02 會停）' END,
         '退款函式只退給 active 的會員（20260606000000:31-37）；沒有會員的話取消鈕會直接跳過退款（20260826000010:203）'
  UNION ALL
  SELECT 3, 3, '③ 儲值金', NULL, '付過錢但不是儲值金（不會自動退）', NULL,
         (SELECT count(*) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet = 0 AND payment_status = 'paid'),
         CASE WHEN (SELECT count(*) FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet = 0 AND payment_status = 'paid') = 0
              THEN '✅ 0 張' ELSE '⚠ 有，要人工退款' END,
         COALESCE((SELECT string_agg(order_no, '、') FROM tgt WHERE kind IN ('cancel', 'follow') AND wallet = 0 AND payment_status = 'paid'), '（沒有）')

  -- ④ 轉入單 TF0001 與原單 0040
  UNION ALL
  SELECT 4, 1, '④ 轉入單', '辣椒醬', 'TF0001 的原單', (SELECT store_name FROM ords WHERE id = (SELECT src_id FROM tf)), NULL,
         CASE WHEN NOT EXISTS (SELECT 1 FROM tf) THEN '❌ 找不到 TF0001'
              WHEN (SELECT src_no FROM tf) = 'GRP-20261016-048-0040' THEN '✅ 是 0040'
              ELSE '❌ 原單是 ' || COALESCE((SELECT src_no FROM tf), '（空）') END,
         'TF0001 取貨店：' || COALESCE((SELECT store_name FROM tf), '?')
           || CASE WHEN (SELECT src_store FROM tf) IS NOT DISTINCT FROM (SELECT pickup_store_id FROM tf) THEN '（同店換客人）' ELSE '（跨店轉）' END
  UNION ALL
  SELECT 4, 2, '④ 轉入單', '辣椒醬', 'TF0001 身上的品項：' || ti.status || '／' || COALESCE(ti.source, '?'), NULL, ti.q,
         'ℹ ' || ti.n || ' 筆',
         '來源 aid_transfer＝轉單搬過來的。整單轉出時原單品項沒被動過，取消只把原單單頭退回（_restore_transfer_source_items 20260818000030:83-93）；部分轉出時會把量還回原單（:97-134）'
    FROM tf_items ti
  UNION ALL
  SELECT 4, 3, '④ 轉入單', '辣椒醬', '0040 復活後會不會直接變「可取貨」', NULL,
         (SELECT COALESCE(sum(qty), 0) FROM src_items),
         CASE WHEN NOT EXISTS (SELECT 1 FROM src_items)
                THEN '⚠ 0040 現在沒有有效品項（＝部分轉出，取消 TF0001 時品項會還回 0040）：還回來的貨到店了沒，01 預先判斷不了；02 遇到可取貨會停'
              WHEN (SELECT bool_and(ready) FROM src_items) THEN '❌ 會（貨已經到店），取消鈕取消不了可取貨的單，02 會停'
              ELSE '✅ 不會（還有品項沒到店）→ 會停在「已確認」，02 取消得掉' END,
         '取消轉入單時，原單若「已經可取」系統會直接推成可取貨（20260826000010:258-267）；取消鈕只收 待確認／已確認／出貨中（:73-77）'
  UNION ALL
  SELECT 4, 4, '④ 轉入單', '辣椒醬', '0040 復活時會不會撞「一人一團一張」', NULL, (SELECT count(*) FROM src_dup),
         CASE WHEN NOT EXISTS (SELECT 1 FROM src_dup) THEN '✅ 不會' ELSE '❌ 會（02 會停）' END,
         COALESCE('同一位客人在這團另有進行中的單：' || (SELECT string_agg(order_no, '、') FROM src_dup), '同一位客人在這團沒有別張進行中的單（名單內的 02 會先取消）')
  UNION ALL
  SELECT 4, 5, '④ 轉入單', '辣椒醬', '掛在 TF0001 上、還沒作廢的調撥單', NULL, (SELECT count(*) FROM tf_xfer),
         CASE WHEN NOT EXISTS (SELECT 1 FROM tf_xfer) THEN '✅ 0 張'
              ELSE '⚠ ' || (SELECT count(*) FROM tf_xfer) || ' 張（取消鈕只在出貨中才作廢調撥單；這份不收出貨中 → 不會碰它，跟手按一樣）' END,
         COALESCE((SELECT string_agg(id::text || ' ' || status, '、') FROM tf_xfer), '')

  -- ⑤ 做過了沒
  UNION ALL
  SELECT 5, 1, '⑤ 02 做過了沒', NULL, '這一次取消留下的編輯歷史', NULL, (SELECT n FROM done),
         CASE WHEN (SELECT n FROM done) = 0 THEN 'ℹ 還沒做過' ELSE '⚠ 已經有 ' || (SELECT n FROM done) || ' 筆' END,
         CASE WHEN (SELECT n FROM done) = 0 THEN '可以照順序貼 02'
              ELSE '最近一次：' || to_char((SELECT at FROM done) AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI:SS') || '（重貼 02 會跳過已取消的）' END

  -- ⑥ 操作人候選
  UNION ALL
  SELECT 6, ROW_NUMBER() OVER (ORDER BY o.last_sign_in_at DESC NULLS LAST)::int, '⑥ 操作人候選', NULL, COALESCE(o.email, '（沒有 email）'), NULL, NULL,
         o.id::text,
         '角色 ' || CASE WHEN o.role = '' THEN '（空白＝總部）' ELSE o.role END || '　最後登入 '
           || COALESCE(to_char(o.last_sign_in_at AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI'), '—')
           || '　→ 老闆認出自己那一列，把「結果」欄那串交給 CEO'
    FROM ops o
) x
ORDER BY o1, o2, "團" NULLS FIRST, "項目";
