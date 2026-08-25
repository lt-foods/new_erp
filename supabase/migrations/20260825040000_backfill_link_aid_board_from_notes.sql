-- ============================================================
-- 2026-08-25: 回填 customer_order_transfer_links.aid_board_id
--             —— 讓「來源未記錄」只剩真的查不出來的那幾筆
--
-- 背景：互助頁的每一筆轉移現在會標來源（互助板 #N ／ 訂單轉單）。判定依據是
--   aid_board_id（20260824060000 才有的欄位）或 reason 裡的貼文編號，而
--   20260824000100 的回填把舊資料的 reason 一律蓋成「[回填] …」，原始的
--   「互助板認領 #N」就消失了 → 608 筆舊轉移全部只能標「來源未記錄」。
--
-- 但原始 reason 其實還留在**轉入單的 notes** 裡：兩支轉單 RPC 建單時把
--   p_reason 併進 notes（新建單放最前面、追加轉入放在時間戳後面 ' / ' 之後）。
--
-- 線上盤點（2026-08-25，608 筆無來源的舊 link）：
--     15 筆 轉入單 notes 找得到「互助板 #N」  → 本檔回填
--    593 筆 三個訊號全查過都沒有互助痕跡      → 確定是訂單轉單
--         （notes 沒提互助板、來源單不是 AB- 互助載體單、
--           來源單品項 notes 也沒有「[互助板認領 #N]」的蓋章）
--   ⇒ 回填後前端就能把「沒有 aid_board_id」直接視為訂單轉單。
--
-- 對應方式（同 20260824070000 的教訓）：notes 裡每一段轉入紀錄都帶
--   to_char(v_now,'YYYY-MM-DD HH24:MI:SS')，而 link.transferred_at 正是同一個
--   v_now（回填時被截到秒）。所以用「該段時間戳 = link.transferred_at 截到秒」
--   對趟；一張轉入單只有一筆 link 且 notes 只提到一個編號時可直接對上。
--   兩者都對不上的不動（寧可留「來源未記錄」，不要猜錯）。
--
-- Rollback：
--   UPDATE customer_order_transfer_links SET aid_board_id = NULL
--    WHERE reason LIKE '[回填]%';
-- ============================================================

-- 候選：還沒有 aid_board_id、reason 也認不出編號的舊 link
WITH bf AS (
  SELECT l.id AS link_id, l.dest_order_id, l.transferred_at, d.notes
    FROM customer_order_transfer_links l
    JOIN customer_orders d ON d.id = l.dest_order_id
   WHERE l.aid_board_id IS NULL
     AND COALESCE(l.reason, '') NOT LIKE '互助板%'
     AND (l.reason LIKE '[回填]%' OR l.reason IS NULL)
     AND d.notes ~ '互助板[^#]*#[0-9]+'
),
-- notes 裡出現過的所有貼文編號（不限位置）——
-- ⚠ 兩支 RPC 擺 reason 的位置不同：建新轉入單放 notes 第一行、追加轉入放在
--    時間戳後面的 ' / ' 之後。只認後者的話會漏掉一大半（實測只救到 2/15）。
boards AS (
  SELECT bf.link_id, bf.dest_order_id, m[1]::BIGINT AS board_id
    FROM bf
    CROSS JOIN LATERAL regexp_matches(bf.notes, '互助板[^#]*#(\d+)', 'g') AS m
),
-- (a) 追加轉入格式：同一行帶時間戳，可以精準對到是哪一趟
seg AS (
  SELECT bf.link_id, bf.transferred_at,
         (m[1] || '+00')::TIMESTAMPTZ AS seg_at,
         m[2]::BIGINT AS board_id
    FROM bf
    CROSS JOIN LATERAL regexp_matches(
      bf.notes,
      '\] (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})[^\n]*互助板[^#]*#(\d+)',
      'g') AS m
),
by_time AS (
  SELECT link_id, MIN(board_id) AS board_id
    FROM seg
   WHERE date_trunc('second', seg_at) = date_trunc('second', transferred_at)
   GROUP BY link_id
  HAVING COUNT(DISTINCT board_id) = 1
),
-- (b) 對不到時間戳，但該轉入單只有這一筆 link、notes 也只提到一個編號
by_unique AS (
  SELECT b.link_id, MIN(b.board_id) AS board_id
    FROM boards b
   WHERE NOT EXISTS (SELECT 1 FROM by_time t WHERE t.link_id = b.link_id)
     AND (SELECT COUNT(*) FROM customer_order_transfer_links l2
           WHERE l2.dest_order_id = b.dest_order_id) = 1
   GROUP BY b.link_id
  HAVING COUNT(DISTINCT b.board_id) = 1
),
resolved AS (
  SELECT link_id, board_id FROM by_time
  UNION
  SELECT link_id, board_id FROM by_unique
)
UPDATE customer_order_transfer_links l
   SET aid_board_id = r.board_id
  FROM resolved r
 WHERE l.id = r.link_id
   AND EXISTS (SELECT 1 FROM mutual_aid_board b WHERE b.id = r.board_id);

-- 驗證（套用後跑）：
--   SELECT COUNT(*) FILTER (WHERE aid_board_id IS NOT NULL) AS 有貼文編號,
--          COUNT(*) FILTER (WHERE aid_board_id IS NULL
--                             AND (reason LIKE '[回填]%' OR reason IS NULL)
--                             AND EXISTS (SELECT 1 FROM customer_orders d
--                                          WHERE d.id = dest_order_id
--                                            AND d.notes ~ '互助板[^#]*#[0-9]+')) AS 仍不明
--     FROM customer_order_transfer_links;

-- ------------------------------------------------------------
-- 對不出貼文編號、但確實查得到互助痕跡的（線上 6 筆：轉入單上有多筆 link、
-- 時間戳又對不起來）→ 蓋一個標記，前端才不會把它們誤標成「訂單轉單」。
-- 這幾筆會顯示「互助板（編號不明）」。
-- ------------------------------------------------------------
UPDATE customer_order_transfer_links l
   SET reason = COALESCE(l.reason, '') || ' ｜ 互助（貼文編號不明）'
 WHERE l.aid_board_id IS NULL
   AND COALESCE(l.reason, '') NOT LIKE '%互助%'
   AND (l.reason LIKE '[回填]%' OR l.reason IS NULL)
   AND EXISTS (SELECT 1 FROM customer_orders d
                WHERE d.id = l.dest_order_id
                  AND d.notes ~ '互助板[^#]*#[0-9]+');
