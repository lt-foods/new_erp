-- ============================================================================
-- 收貨防「同一批貨算兩次」：冪等鍵（重試）＋ 已收量樂觀鎖（多台 iPad 過期資料）
--
-- 由來（PR #792 審查報告 P0-1 / P0-2，2026-08-20）：
--   樓下 iPad 收貨頁走 rpc_arrive_and_distribute（累加語意，每次收貨建一張 GR）。
--   兩個都會讓同一批貨被 qty_received += 兩次、庫存進兩次、應付廠商多算：
--     P0-1 重試：後端已入庫、HTTP 回應在路上斷掉 → 前端判定失敗並解鎖 →
--                樓下照畫面指示再按一次 → 第二張 GR。
--     P0-2 併發：兩台 iPad 各自開同一張單、各自看著（可能已經過期的）剩餘量
--                按「全到」→ 兩邊都通過。
--
-- ⭐⭐ 先講一個查證結果，因為它決定了修法：
--   **這兩件事都不是「缺少互斥鎖」。** rpc_arrive_and_distribute 第 1 步就有
--   `SELECT ... FROM purchase_orders WHERE id = p_po_id FOR UPDATE`
--   （20260512000002_arrive_no_auto_wave.sql:44-48，本檔逐字保留），
--   同一張 PO 的兩個呼叫本來就會在那一行排隊、一個一個跑。
--   → 所以**再加 pg_advisory_xact_lock('po:' || p_po_id) 是多餘的**：
--     它防的東西那一行已經防住了。⛔ 不要「順手補一把鎖」然後以為 P0-2 修好了。
--
--   真正的病是**過期讀取**（application-level lost update）：
--   第二台 iPad 的 payload 是用它三分鐘前讀到的 qty_received 算出來的。
--   排隊只保證它「後跑」，不會讓它的數字變新 —— 它照樣 +10 疊在前一台的 +10 上。
--   → 序列化解不了，只有「把當時看到的值一起送上來比對」解得了。
--
-- 修法（兩個問題兩個機制，⛔ 不要以為其中一個能替代另一個）：
--   A. goods_receipts.client_request_id ＋ partial UNIQUE
--      同一次送出的重試帶同一個值 → 直接回傳既有 GR，不再入庫一次。
--      房規前例：customer_orders.external_order_no + idx_corders_external
--      （20260424130000:14-27）、community_product_candidates.source_external_id
--      （20260513000006:105-109）—— 兩者都是「可空欄位 + partial unique」，
--      ⛔ 所以本檔**不新建任何資料表**。
--   B. p_arrivals[i].qty_received_base（可空）
--      呼叫端把「我畫面上這一項的已收量」一起送上來，RPC 在**同一個交易、
--      同一把列鎖之下**比對現值，不一樣就擋下並叫人重新整理。
--
--   為什麼 B 不能省（A 看起來也擋得住重試）：A 只認得「同一次送出」。
--   兩台 iPad 是兩次不同的送出、兩個不同的 UUID，A 完全看不出來。
--   為什麼 A 不能省（B 在重試時現值已經變了，看起來也擋得住）：
--   B 擋下來的樣子是**一句錯誤訊息**。樓下站在貨旁邊看到紅字，
--   合理反應是再按一次或叫人來，而事實上貨早就收進去了。
--   A 讓那個情境變成「這批貨先前已經收過了，進貨單 GR-xxxx」的成功畫面。
--   → A 管「講清楚」，B 管「送進來的品項不可能算兩次」。
--
-- ⚠️⚠️ A 與 B 共同的天花板（2026-08-20 複審抓到，⛔ 改本檔前必須知道）：
--   **這兩道都只看得到「這一次 payload 裡有的品項」。**
--   A 是整批比對 client_request_id；B 是 `FOR i IN 0..jsonb_array_length(p_arrivals)-1`
--   逐項比對 base（本檔第 4b 段）。**沒送進來的品項，兩道都不會檢查。**
--   ⇒ 本檔早期版本在檔頭寫過「內容一樣→A 擋、內容不同→B 擋，兩條路都是吵的，
--     沒有一條靜默」——**那句話是錯的，已刪除**。反例：
--       ① 第一次送 A 品項 5 個，後端 commit 了、HTTP 回應斷在路上
--       ② 前端判定失敗，樓下以為整批沒送出
--       ③ 他不確定 A 品項有沒有問題，把 A 清成 0、改填 B 品項再送
--       ④ 第二次 payload 裡**根本沒有 A** → A 不在 A/B 兩道的檢查範圍內
--       ⑤ B 品項成功入庫、畫面顯示成功，而 A 品項早在①就已經入過一次帳
--     → 兩批貨都真的收了，使用者的認知跟系統的真實狀態對不上，而且沒有任何錯誤。
--   ⇒ 補的是第三道 **C（純前端）**：`apps/admin/src/lib/receivingSubmission.ts`
--     的 decideSubmission() —— 送出失敗後只要內容改過，就**不換新鍵、直接擋下**，
--     逼使用者走「重新載入這張單、看最新已收量」這條唯一安全的路。
--   ⛔ 所以：**C 目前是這條路上唯一的防線，而它在前端。**
--     任何直接打 RPC 的呼叫端（本函式是 SECURITY DEFINER + GRANT TO authenticated）
--     都繞得過它。要在 DB 層封死，得讓呼叫端送「全品項的 base 快照」而不只是
--     這次要收的那幾項 —— 那會改動 p_arrivals 的契約，屬獨立議題，不在本檔範圍。
--
-- ⛔ 為什麼不改 rpc_confirm_gr（那裡才是真正 += 的地方）：
--   它有 7 個呼叫點（5 支 arrive 歷代版本、20260729000020:135、
--   20260801000000:509），動它會同時波及正式收貨與「調整已收量」兩條路。
--   本檔一行都沒碰它。
--
-- ⛔ 為什麼不加「不可超過訂購量」的硬上限：
--   本系統**進貨可超收**是既有政策（前後端都不擋，只要求填差異原因；
--   purchase/orders/receive/page.tsx:321-324、原 RPC 只擋 qty <= 0）。
--   加上限會把「供應商多送」這個天天發生的正常情境變成收不進來。
--
-- ✅ 辦公室收貨頁 /purchase/orders/receive 為什麼一行都不用改、行為也不變：
--   它用具名參數只送 5 個（p_po_id / p_arrivals / p_operator / p_invoice_no /
--   p_notes，receive/page.tsx:402-408），不送 p_client_request_id、
--   arrivals 裡也不放 qty_received_base。
--     - p_client_request_id 為 NULL → 整段冪等邏輯跳過（連查詢都不發）
--     - qty_received_base 為 NULL → 樂觀鎖跳過
--   其餘每一行（含錯誤訊息文字與其先後順序）都是 20260512000002 逐字搬過來的。
--
-- ⚠️ 為什麼是 DROP 舊 5 參數 + CREATE OR REPLACE 新 6 參數：
--   單純 CREATE OR REPLACE 換不掉舊的：**加參數會產生多載而不是取代**。
--   舊 5 參數版與新 6 參數版（第 6 個有預設）同時存在時，PostgREST 用 5 個具名參數
--   呼叫會兩支都符合 → PostgreSQL 直接回「function ... is not unique」
--   → **辦公室收貨頁當場壞掉**。
--   房規前例：20260613000050_member_import_drop_old_overloads.sql 就是在收拾同一種爛攤子。
--   → 所以「DROP 掉 5 參數那支」是必要的；而新的 6 參數那支用 OR REPLACE，
--     是為了讓整支檔案**可以重跑**（見下面「部署方式」為什麼這件事很重要）。
--   ⚠️ DROP 會一併丟掉舊函式的 ACL，所以下面把 20260430120000:216 那句 GRANT 原樣補回。
--
-- ⚠️⚠️ 部署方式（決定了下面第 0 節為什麼存在）—— ⛔ 改本檔前必讀：
--   本公司**實際的套用方式是「開檔、全選複製、貼進 Supabase SQL Editor 執行」**，
--   不是 `supabase db push`。這條路**不保證有交易包覆**。
--   ⇒ 因此「檔尾放個自我檢查、失敗就整支 rollback」這個假設 **對我們不成立**。
--     最壞情況是 DROP／CREATE／GRANT 各自已經提交、檢查才失敗：
--     畫面上看到「套用中止」，但多載其實已經留在正式庫上，
--     **隔天早上辦公室收不了貨**。（本檔 24ad46b 版本就是犯這個錯，2026-08-20 修正。）
--   ⇒ 正解是 **fail fast**：把所有「這台資料庫長得對不對」的檢查放在
--     **第 0 節、所有 DDL 之前**。沒動任何東西之前先吵，就不必依賴 rollback。
--   ⇒ 檔尾第 3 節保留一個「事後檢查」，但它的定位不同：它驗的是**結果**
--     （做完之後真的只剩一支、GRANT 真的還在），失敗時直接把補救指令印在錯誤訊息裡。
--   ⇒ 若改用 psql 手動套，請用：psql -v ON_ERROR_STOP=1 -1 -f <本檔>
--     （`-1` 才是整支一個交易，`ON_ERROR_STOP=1` 才會在第一個錯誤就停）。
--
-- ⚠️ 刻意**沒有**加的東西（不是忘記）：
--   - `SET search_path = public`：新函式都有寫，但這一支沒有，鏈上的
--     rpc_confirm_gr / rpc_inbound 也都沒有（且 rpc_confirm_gr 禁改）。
--     只釘這一支＝保護不完整、卻多一份「辦公室那條路解析到別的物件」的風險。
--     整條鏈一起釘是獨立議題，不在本檔範圍。
--   - REVOKE ... FROM PUBLIC：原函式沒有，補上等於**收窄**既有權限，
--     不符合「辦公室行為一字不差」。權限議題同樣獨立處理。
--
-- rollback：
--   DROP FUNCTION IF EXISTS public.rpc_arrive_and_distribute(BIGINT,JSONB,UUID,TEXT,TEXT,TEXT);
--   -- 再把 20260512000002_arrive_no_auto_wave.sql 的 CREATE OR REPLACE 整段重跑，
--   -- 並補 GRANT EXECUTE ... TO authenticated;
--   DROP INDEX IF EXISTS idx_gr_client_request;
--   ALTER TABLE goods_receipts DROP COLUMN IF EXISTS client_request_id;
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 前置檢查 —— ⚠️ 必須排在所有 DDL 之前（理由見檔頭「部署方式」）
--
-- 防的是這個 repo 的頭號病灶：**repo ≠ 正式庫**（migration 全人工套）。
-- 這裡每一條都是「下面某一句 DDL 會靜默做錯事」的前提檢查：
--   0a → 下面的 DROP 寫死了舊簽章，簽章不符時 `IF EXISTS` 會**靜默跳過**，
--        接著 CREATE 出第二支 → 多載 → 辦公室收貨頁 function is not unique。
--   0b → 已經是 6 參數（重跑本檔）時，`CREATE OR REPLACE` **改不了 input 參數的名字**，
--        名字不同會在下面 CREATE 那一行才爆 —— 那時 ALTER TABLE / CREATE INDEX 已經提交。
--   0c → 下面的 CREATE UNIQUE INDEX **IF NOT EXISTS 只看名字**，
--        同名但定義不對時會靜默跳過 → 冪等防重整個不成立、而且看起來一切正常。
-- 這一節失敗時**還沒有動過任何東西**，直接照訊息處理即可，不需要 rollback。
--
-- ⚠️ 這一節的每一條錯誤訊息都要**把現況原樣印出來**：老闆是「開檔複製貼上到
--    Supabase SQL Editor」套這支的，訊息就是他手上唯一的線索。
--    ⛔ 也因此，這裡的比對寧可**寬到語意等價為止**也不要多擋 ——
--    誤擋會直接卡住部署（見 0c 的改法說明）。
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_sigs     TEXT[];
  v_argnames TEXT[];
  v_idx_oid  OID;
  v_idx_kind "char";
  v_idxdef   TEXT;
  v_idx_ok   BOOLEAN;
BEGIN
  -- 0a. 正式庫上現在到底有幾支 rpc_arrive_and_distribute、簽章是什麼？
  --     ⚠️ 用 oidvectortypes（只有型別）而不是 pg_get_function_identity_arguments
  --        （那個**會帶參數名**，例如 'p_po_id bigint, ...'），
  --        參數名被改過就會誤判成「簽章不符」而擋掉正常的套用。
  SELECT array_agg(oidvectortypes(p.proargtypes) ORDER BY 1)
    INTO v_sigs
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'rpc_arrive_and_distribute';

  IF v_sigs IS NULL THEN
    RAISE EXCEPTION '套用中止（尚未變更任何東西）：這台資料庫上找不到 public.rpc_arrive_and_distribute。本檔是「改既有函式」，不是從零建立；請先確認連對資料庫、以及 20260512000002 是否套過。';
  END IF;

  IF array_length(v_sigs, 1) <> 1 THEN
    RAISE EXCEPTION '套用中止（尚未變更任何東西）：public.rpc_arrive_and_distribute 現在有 % 支（應該只有 1 支）。現存簽章：%。本檔只 DROP 得掉 (bigint, jsonb, uuid, text, text) 那一支，其餘會留下來變成多載，辦公室收貨頁的 5 參數呼叫會 function is not unique。請先人工確認這些多載哪些該留。',
      array_length(v_sigs, 1), array_to_string(v_sigs, ' ｜ ');
  END IF;

  -- 允許兩種狀態：① 還沒套過（舊 5 參數） ② 已經套過了（新 6 參數，重跑本檔）
  IF v_sigs[1] NOT IN ('bigint, jsonb, uuid, text, text',
                       'bigint, jsonb, uuid, text, text, text') THEN
    RAISE EXCEPTION '套用中止（尚未變更任何東西）：public.rpc_arrive_and_distribute 目前的簽章是「%」，不是本檔預期的 (bigint, jsonb, uuid, text, text)。表示正式庫上跑的不是 20260512000002 那一版（有人手動改過、或漏套／多套了某支 migration）。硬套下去會留下多載並讓辦公室收貨頁壞掉，請先查明現況。',
      v_sigs[1];
  END IF;

  -- 0b. 已經是 6 參數（＝本檔套過了、現在是重跑）→ 參數名必須完全相符。
  --     PostgreSQL 的 CREATE OR REPLACE FUNCTION **不能改 input parameter 的名字**
  --     （官方 CREATE FUNCTION 文件明講，本機 PG18 實測錯誤訊息是
  --      `cannot change name of input parameter "..."`）。
  --     名字不同的話，下面那句 CREATE OR REPLACE 會失敗 —— 而那時第 1 節的
  --     ALTER TABLE / CREATE INDEX 已經各自提交（我們這條部署路徑沒有交易包覆）。
  --     結果不會壞資料（函式維持舊的），但畫面上是一個看不懂的錯誤，
  --     不如在這裡先把話講清楚。
  --   ⓘ 5 參數那條路不必檢查名字：那支是被 DROP 掉再重建的，名字無所謂。
  --     所以這條只在「已是 6 參數」時才成立，⛔ 不要順手套用到 5 參數，會誤擋。
  IF v_sigs[1] = 'bigint, jsonb, uuid, text, text, text' THEN
    SELECT p.proargnames
      INTO v_argnames
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'rpc_arrive_and_distribute';

    IF v_argnames IS DISTINCT FROM ARRAY['p_po_id','p_arrivals','p_operator',
                                         'p_invoice_no','p_notes','p_client_request_id'] THEN
      RAISE EXCEPTION '套用中止（尚未變更任何東西）：public.rpc_arrive_and_distribute 已經是 6 參數版，但參數名稱是「%」，不是本檔的 (p_po_id, p_arrivals, p_operator, p_invoice_no, p_notes, p_client_request_id)。CREATE OR REPLACE 改不掉既有函式的參數名，硬套下去會在中途失敗。請先確認正式庫上這一支是誰改的、要不要保留；要換掉的話請先 DROP FUNCTION public.rpc_arrive_and_distribute(BIGINT,JSONB,UUID,TEXT,TEXT,TEXT); 再重跑本檔。',
        COALESCE(array_to_string(v_argnames, ', '), '(沒有參數名)');
    END IF;
  END IF;

  -- 0c. 同名索引若已存在，語意必須正確（IF NOT EXISTS 只看名字，驗不到定義）
  --
  --   ⚠️ 2026-08-20 改法（原本比對 pg_get_indexdef 的完整字串 LIKE）：
  --     文字比對會把**語意正確但輸出文字不同**的索引也擋掉，例如
  --       · 沒有 WHERE 條件的 unique index —— 其實**等價**：unique index 裡
  --         NULL 彼此不相等，所以整表 unique(tenant_id, client_request_id)
  --         對「client_request_id IS NULL 的那些列」一樣不設限
  --         （本機 PG18 實測：同 tenant 連插兩列 NULL 都成功）。
  --       · 帶 WITH (fillfactor=...)、tablespace、INCLUDE 欄位、非預設 collation…
  --     這些一律擋下的結果就是**老闆貼 SQL 時卡在這裡**，而索引其實好好的。
  --   ⇒ 改成查 pg_index 的語意欄位。真正非擋不可的只有四件事：
  --       ① 這個名字確實是索引，而且掛在 public.goods_receipts 上
  --       ② unique，而且 valid / ready（CONCURRENTLY 失敗會留下 invalid 索引，
  --          它**不會**強制唯一性 → 冪等防重形同虛設，這是真的要擋）
  --       ③ 前兩個 key 欄位就是 (tenant_id, client_request_id)，順序一樣
  --       ④ NULLS NOT DISTINCT 沒有被打開（打開的話 NULL 會互相碰撞，
  --          辦公室那條不帶 client_request_id 的路會開始撞唯一鍵）
  --     predicate 則放寬到「沒有」或「就是我們那一條」兩種。
  --   ⓘ indnullsnotdistinct 用 to_jsonb 取而不直接寫欄位名：那個欄位 PG15 才有，
  --     直接寫的話在更舊的版本上會變成「欄位不存在」而整段爆掉。
  SELECT c.oid, c.relkind
    INTO v_idx_oid, v_idx_kind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'idx_gr_client_request';

  IF v_idx_oid IS NOT NULL THEN
    v_idxdef := CASE WHEN v_idx_kind = 'i' THEN pg_get_indexdef(v_idx_oid) END;

    SELECT i.indrelid = to_regclass('public.goods_receipts')
       AND i.indisunique
       AND i.indisvalid
       AND i.indisready
       AND COALESCE(to_jsonb(i) ->> 'indnullsnotdistinct', 'false') = 'false'
       AND i.indnkeyatts = 2
       AND (SELECT string_agg(a.attname, ',' ORDER BY k.ord)
              FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(attnum, ord)
              JOIN pg_attribute a
                ON a.attrelid = i.indrelid AND a.attnum = k.attnum
             WHERE k.ord <= i.indnkeyatts) = 'tenant_id,client_request_id'
       AND (i.indpred IS NULL
            OR pg_get_expr(i.indpred, i.indrelid) = '(client_request_id IS NOT NULL)')
      INTO v_idx_ok
      FROM pg_index i
     WHERE i.indexrelid = v_idx_oid;

    IF NOT COALESCE(v_idx_ok, FALSE) THEN
      RAISE EXCEPTION '套用中止（尚未變更任何東西）：已經有一個叫 idx_gr_client_request 的東西，但它不是「goods_receipts 上、unique 且有效、前兩個欄位是 (tenant_id, client_request_id)、NULLS DISTINCT」的索引。下面那句 CREATE UNIQUE INDEX IF NOT EXISTS 只看名字，會靜默跳過，收貨冪等防重就形同虛設。現況：%',
        -- ⚠️ v_idx_kind 是 "char" 型別，⛔ 不可以直接接 || ——
        --    Postgres 會在**解析階段**就報 `operator is not unique: unknown || "char"`，
        --    連 COALESCE 走不走到第二個參數都不管。一定要明寫 ::TEXT。
        --    （沒有 ::TEXT 時，這裡會用一句看不懂的型別錯誤蓋掉上面整段說明。）
        COALESCE(v_idxdef,
                 'public.idx_gr_client_request 不是索引（pg_class.relkind = '
                   || v_idx_kind::TEXT || '），這個名字被別的物件占用了');
    END IF;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 1. 冪等鍵欄位（加在既有表上，不新建表）
-- ----------------------------------------------------------------------------

ALTER TABLE goods_receipts
  ADD COLUMN IF NOT EXISTS client_request_id TEXT;

COMMENT ON COLUMN goods_receipts.client_request_id IS
  '(收貨冪等 2026-08-20) 呼叫端產生的一次性識別碼；同一次送出的重試帶同一個值，'
  'rpc_arrive_and_distribute 會回傳既有 GR 而不重複入庫。'
  'NULL = 呼叫端沒帶（辦公室收貨頁），不參加防重。';

-- partial index：沒帶的那些列（絕大多數）不佔索引、也不會互相撞 NULL
CREATE UNIQUE INDEX IF NOT EXISTS idx_gr_client_request
  ON goods_receipts (tenant_id, client_request_id)
  WHERE client_request_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 2. rpc_arrive_and_distribute v6
--    基底 20260512000002_arrive_no_auto_wave.sql 逐字保留，只加 1b / 4a / 4b。
-- ----------------------------------------------------------------------------

DROP FUNCTION IF EXISTS public.rpc_arrive_and_distribute(BIGINT, JSONB, UUID, TEXT, TEXT);

-- OR REPLACE 是為了「整支檔案可以重跑」（第 0 節已擋掉真正危險的簽章狀況）。
-- 不加的話，套到一半失敗後再貼一次會卡在 function already exists。
CREATE OR REPLACE FUNCTION public.rpc_arrive_and_distribute(
  p_po_id             BIGINT,
  p_arrivals          JSONB,
  p_operator          UUID,
  p_invoice_no        TEXT DEFAULT NULL,
  p_notes             TEXT DEFAULT NULL,
  p_client_request_id TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_po              RECORD;
  v_close_dates     DATE[];
  v_close_date      DATE;
  v_gr_id           BIGINT;
  v_gr_no           TEXT;
  v_arrival         JSONB;
  v_po_item_id      BIGINT;
  v_sku_id          BIGINT;
  v_qty_received    NUMERIC(18,3);
  v_qty_damaged     NUMERIC(18,3);
  v_unit_cost       NUMERIC(18,4);
  -- 以下為 20260820000000 新增
  v_dup             RECORD;
  v_item_ordered    NUMERIC(18,3);
  v_item_received   NUMERIC(18,3);
  v_item_cost       NUMERIC(18,4);
  v_base            NUMERIC;
  v_sku_label       TEXT;
BEGIN
  -- 1. PO 守衛
  --    ⭐ 這一行 FOR UPDATE 就是同一張 PO 的互斥鎖（見檔頭：所以不需要 advisory lock）。
  SELECT id, tenant_id, supplier_id, dest_location_id, status
    INTO v_po
    FROM purchase_orders
   WHERE id = p_po_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PO % not found', p_po_id;
  END IF;

  -- 1b. 冪等：這個 client_request_id 已經收過了嗎？
  --
  --     ⚠️⚠️ 位置很重要：**必須在下面的狀態守衛之前**。
  --     最常見的重試情境正是「第一次其實成功了，而且把 PO 收成 fully_received」，
  --     若先跑狀態守衛，重試會拿到
  --     「PO must be sent/partially_received」這種看起來像壞掉的錯誤，
  --     樓下不會知道貨其實已經進去了。
  --
  --     ⚠️ 這裡不需要額外的鎖：同一張 PO 的並行呼叫已經卡在第 1 步的 FOR UPDATE，
  --     所以先到的那筆一定已經 commit、這裡看得到它。
  --     真的有未知路徑繞過的話，第 3 步 INSERT 的 unique_violation 是最後一道網。
  IF p_client_request_id IS NOT NULL THEN
    SELECT gr.id, gr.gr_no, gr.po_id
      INTO v_dup
      FROM goods_receipts gr
     WHERE gr.tenant_id = v_po.tenant_id
       AND gr.client_request_id = p_client_request_id;

    IF FOUND THEN
      -- 同一個識別碼跑到別張採購單 = 呼叫端把 key 重複用了，
      -- 這時回「成功」會騙人（那批貨根本沒收進這張單），一律報錯。
      IF v_dup.po_id <> p_po_id THEN
        RAISE EXCEPTION '收貨識別碼 % 先前已用在採購單 #%,不可以再用在 #%',
          p_client_request_id, v_dup.po_id, p_po_id;
      END IF;

      RETURN jsonb_build_object(
        'gr_id',     v_dup.id,
        'gr_no',     v_dup.gr_no,
        'wave_id',   NULL,
        'wave_code', NULL,
        -- 用 MIN 而不是複製第 2 步那段 array_agg + 多重 close_date 檢查：
        -- 能走到這裡代表原本那次已經成功過，也就代表當時只有一個 close_date，
        -- 兩種寫法結果相同。
        'close_date', (
          SELECT MIN(pr.source_close_date)
            FROM purchase_order_items poi
            JOIN purchase_request_items pri ON pri.po_item_id = poi.id
            JOIN purchase_requests pr ON pr.id = pri.pr_id
           WHERE poi.po_id = p_po_id
             AND pr.source_close_date IS NOT NULL
        ),
        'duplicate', TRUE
      );
    END IF;
  END IF;

  IF v_po.status NOT IN ('sent','partially_received') THEN
    RAISE EXCEPTION 'PO % must be sent/partially_received (current: %)', p_po_id, v_po.status;
  END IF;

  -- 2. 反查 close_date（保留供回傳值）
  SELECT array_agg(DISTINCT pr.source_close_date)
    INTO v_close_dates
    FROM purchase_order_items poi
    JOIN purchase_request_items pri ON pri.po_item_id = poi.id
    JOIN purchase_requests pr ON pr.id = pri.pr_id
   WHERE poi.po_id = p_po_id
     AND pr.source_close_date IS NOT NULL;

  IF v_close_dates IS NOT NULL AND array_length(v_close_dates, 1) > 1 THEN
    RAISE EXCEPTION 'PO % spans multiple close_dates: %', p_po_id, v_close_dates;
  END IF;

  v_close_date := COALESCE(v_close_dates[1], NULL);

  -- 3. GR header
  v_gr_no := public.rpc_next_gr_no();
  BEGIN
    INSERT INTO goods_receipts (
      tenant_id, gr_no, po_id, supplier_id, dest_location_id,
      status, supplier_invoice_no, received_by, notes, created_by, updated_by,
      client_request_id
    ) VALUES (
      v_po.tenant_id, v_gr_no, v_po.id, v_po.supplier_id, v_po.dest_location_id,
      'draft', p_invoice_no, p_operator, p_notes, p_operator, p_operator,
      p_client_request_id
    ) RETURNING id INTO v_gr_id;
  EXCEPTION WHEN unique_violation THEN
    -- 只有「冪等鍵撞號」這一種算重試，回傳既有 GR。
    -- ⛔ 其他 unique_violation（例如 gr_no 撞號）一律原樣往上丟：
    --    把它當成「已經收過了」會靜默吞掉真正的問題。
    SELECT gr.id, gr.gr_no
      INTO v_dup
      FROM goods_receipts gr
     WHERE p_client_request_id IS NOT NULL
       AND gr.tenant_id = v_po.tenant_id
       AND gr.client_request_id = p_client_request_id
       AND gr.po_id = p_po_id;
    IF NOT FOUND THEN
      RAISE;
    END IF;
    RETURN jsonb_build_object(
      'gr_id',      v_dup.id,
      'gr_no',      v_dup.gr_no,
      'wave_id',    NULL,
      'wave_code',  NULL,
      'close_date', v_close_date,
      'duplicate',  TRUE
    );
  END;

  -- 4. GR items
  FOR v_arrival IN SELECT * FROM jsonb_array_elements(p_arrivals) LOOP
    v_po_item_id   := (v_arrival->>'po_item_id')::BIGINT;
    v_sku_id       := (v_arrival->>'sku_id')::BIGINT;
    v_qty_received := (v_arrival->>'qty_received')::NUMERIC;
    v_qty_damaged  := COALESCE((v_arrival->>'qty_damaged')::NUMERIC, 0);
    v_unit_cost    := (v_arrival->>'unit_cost')::NUMERIC;
    -- 沒帶 = NULL = 不做樂觀鎖檢查（辦公室收貨頁就是這種）
    v_base         := (v_arrival->>'qty_received_base')::NUMERIC;

    IF v_qty_received IS NULL OR v_qty_received <= 0 THEN
      RAISE EXCEPTION 'arrival sku_id % has invalid qty_received', v_sku_id;
    END IF;

    -- 4a. 鎖住品項並讀現值。
    --
    --   原版在這裡對 purchase_order_items 查了兩次（qty_expected 用 inline
    --   子查詢、unit_cost 只在沒帶成本時查），合併成一次並加 FOR UPDATE。
    --   ⭐ FOR UPDATE 是 4b 正確性的前提：沒有它，「比對現值」與「confirm_gr
    --     真的 += 上去」之間有空隙，別的交易可以插進來 —— 檢查就白做了。
    --   ⭐ 對辦公室那條路沒有行為差異：rpc_confirm_gr 本來就會 UPDATE 同一列、
    --     拿到同一把列鎖，這裡只是把取得時間往前挪幾行。
    --     鎖的**順序**也沒變（一樣是 purchase_orders 在前、purchase_order_items 在後）。
    --   ⚠️ 三個變數每圈都要先清空：po_item_id 為 NULL 時下面的 SELECT 不會執行，
    --     不清空就會沿用上一圈的值（qty_expected 會寫錯到別的品項頭上）。
    --
    --   ⭐⭐ `AND poi.po_id = p_po_id` 是 2026-08-20 補的資料完整性守衛。
    --     **這個洞舊版就有**（20260512000002:98-105 的 inline 子查詢一樣只用 id 查），
    --     不是本次改壞的；但既然整支要重建，補一個條件幾乎零成本，一起修掉。
    --     沒有它會怎樣：呼叫端傳一個「屬於別張採購單 B」的 po_item_id，
    --       - GR header 建在 A（用 p_po_id）
    --       - rpc_confirm_gr 卻把 **B 的品項** qty_received += 上去
    --         （20260422120004:328-331，它只認 po_item_id，不檢查屬於誰）
    --       - 而重算「是否全部到貨」的只有 A（_refresh_po_status(v_gr.po_id)）
    --     → 兩張單的已收量與狀態同時失真，**而且完全沒有錯誤訊息**。
    --     ⛔ 不可以只靠「畫面上選不出跨單的 po_item_id」來心安：這支是
    --        SECURITY DEFINER 且 GRANT TO authenticated，任何登入帳號都能直接打 RPC
    --        繞過前端（機制索引「七、慣性坑 #3」：守衛要放 DB，不是放前端）。
    --   ⚠️ 找不到時**一律報錯**（不分有沒有帶 qty_received_base）：
    --     靜默跳過等於把「收到別張單頭上」變成看不見的壞帳。
    v_item_ordered  := NULL;
    v_item_received := NULL;
    v_item_cost     := NULL;
    IF v_po_item_id IS NOT NULL THEN
      SELECT poi.qty_ordered, poi.qty_received, poi.unit_cost
        INTO v_item_ordered, v_item_received, v_item_cost
        FROM purchase_order_items poi
       WHERE poi.id = v_po_item_id
         AND poi.po_id = p_po_id
       FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION '收貨資料有誤:品項 #% 不屬於採購單 #%(或已不存在),不能收在這張單底下。',
          v_po_item_id, p_po_id;
      END IF;
    END IF;

    -- 4b. 樂觀鎖：呼叫端說「我看到的已收量是 X」，現值不是 X 就擋下。
    --
    --   這是 P0-2 的正解。⛔ 不要改成「不可超過訂購量」那種上限檢查 ——
    --   本系統允許超收（供應商多送），上限會擋掉正常情境；
    --   而且兩台各收一半、加起來剛好不超量時，上限根本擋不到。
    --
    --   ⚠️⚠️ 這道防線的**範圍**：它跟著外層的 `FOR i IN 0..長度-1` 跑，
    --   所以**只檢查這一次 p_arrivals 裡面有的品項**。
    --   ⛔ 不要因為這裡擋得住就推論「重複入庫已經不可能」——
    --     呼叫端只要把上一次送過的品項從 payload 裡拿掉，這裡就完全看不到它。
    --     那條路目前是前端 decideSubmission() 在擋（檔頭「A 與 B 共同的天花板」）。
    IF v_base IS NOT NULL THEN
      -- 帶了 base 卻沒帶 po_item_id：沒有東西可以比對，等於樂觀鎖被靜默關掉。
      -- 上面 4a 只有 po_item_id 不為 NULL 時才查，所以這裡要自己擋。
      -- （辦公室那條路不帶 base，走不到這裡。）
      IF v_po_item_id IS NULL THEN
        RAISE EXCEPTION '收貨資料有誤:帶了 qty_received_base 就必須一併帶 po_item_id,否則無從比對已收量。';
      END IF;

      IF COALESCE(v_item_received, 0) <> v_base THEN
        -- 訊息要讓樓下看得懂並且知道下一步做什麼；品名一律帶 variant_name，
        -- 只講上層品名現場會抓錯貨。
        SELECT TRIM(
                 COALESCE(s.sku_code || ' ', '')
                 || COALESCE(s.product_name, '')
                 || COALESCE(' / ' || s.variant_name, '')
               )
          INTO v_sku_label
          FROM skus s
         WHERE s.id = v_sku_id;

        -- ⚠️ 格式字串刻意寫成一行：RAISE 的 format 必須是單一字串常數，
        --    不要為了排版拆成多行相接（那是 lexer 層的接法，容易寫錯又難驗）。
        RAISE EXCEPTION '「%」的已收量在你核對的期間從 % 變成了 %(可能別台 iPad 或辦公室剛收過同一張單)。請退出去重新點一次這張採購單、看最新數量再收,不然這批貨會被算兩次。',
          COALESCE(NULLIF(v_sku_label, ''), '品項 #' || COALESCE(v_po_item_id::TEXT, '?')),
          v_base,
          COALESCE(v_item_received, 0);
      END IF;
    END IF;

    IF v_unit_cost IS NULL THEN
      v_unit_cost := COALESCE(v_item_cost, 0);
    END IF;

    INSERT INTO goods_receipt_items (
      gr_id, po_item_id, sku_id,
      qty_expected, qty_received, qty_damaged, unit_cost,
      batch_no, expiry_date, variance_reason, created_by, updated_by
    ) VALUES (
      v_gr_id, v_po_item_id, v_sku_id,
      v_item_ordered,
      v_qty_received, v_qty_damaged, v_unit_cost,
      v_arrival->>'batch_no',
      NULLIF(v_arrival->>'expiry_date','')::DATE,
      v_arrival->>'variance_reason',
      p_operator, p_operator
    );
  END LOOP;

  -- 5. confirm GR（入總倉庫存）
  PERFORM rpc_confirm_gr(v_gr_id, p_operator);

  -- 6. （已移除）撿貨單由工作站建立
  --    若 p_arrivals 帶了 allocations，無作用，純粹忽略。

  RETURN jsonb_build_object(
    'gr_id',      v_gr_id,
    'gr_no',      v_gr_no,
    'wave_id',    NULL,
    'wave_code',  NULL,
    'close_date', v_close_date,
    'duplicate',  FALSE
  );
END;
$$;

-- DROP 會連 ACL 一起丟掉，把 20260430120000:216 那句原樣補回（不多不少）
GRANT EXECUTE ON FUNCTION
  public.rpc_arrive_and_distribute(BIGINT, JSONB, UUID, TEXT, TEXT, TEXT)
  TO authenticated;

-- ----------------------------------------------------------------------------
-- 3. 套用後結果檢查
--
-- ⚠️⚠️ 這一節**不保證會 rollback**，⛔ 不要再把它當安全網來寫。
--   真正的守衛在第 0 節（DDL 之前就擋）。這裡驗的是**做完之後的結果**：
--   東西真的變成該有的樣子了嗎（只剩一支？GRANT 還在？索引真的建出來了？）。
--   本公司實際部署是「複製貼上到 Supabase SQL Editor」，那條路不保證有交易包覆
--   → 這一節若失敗，上面的變更**可能已經落在正式庫上了**，
--     所以錯誤訊息裡直接附補救指令，不要求任何人自己想。
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_n    INT;
  v_sigs TEXT;
  v_fix  TEXT;
BEGIN
  SELECT COUNT(*), string_agg(oidvectortypes(p.proargtypes), ' ｜ ')
    INTO v_n, v_sigs
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'rpc_arrive_and_distribute';

  IF v_n <> 1 THEN
    -- ⭐ 補救指令直接組成可以整段複製貼上的 SQL。
    --    原本寫「DROP FUNCTION ...(<不該留的那組簽章>);」，那不是能貼的東西 ——
    --    而本公司就是用「開檔複製貼上」在套 SQL 的，還要人自己代換就等於沒給。
    SELECT string_agg(
             'DROP FUNCTION public.rpc_arrive_and_distribute(' ||
               oidvectortypes(p.proargtypes) || ');', E'\n')
      INTO v_fix
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname = 'rpc_arrive_and_distribute'
       AND oidvectortypes(p.proargtypes) <> 'bigint, jsonb, uuid, text, text, text';

    RAISE EXCEPTION
      '⚠️ 收尾檢查失敗（變更可能已經生效，請照下面處理）：public.rpc_arrive_and_distribute 現在有 % 支（應該只有 1 支）。現存簽章：%。多載會讓辦公室收貨頁的 5 參數呼叫變成 function is not unique。留下 (bigint, jsonb, uuid, text, text, text) 這一支即可，補救指令（可直接整段複製執行）：%',
      v_n, v_sigs, COALESCE(E'\n' || v_fix,
        '（沒有多餘的簽章可刪 —— 表示 6 參數那支反而不見了，請把本檔第 2 節重跑一次）');
  END IF;

  IF NOT has_function_privilege('authenticated',
        'public.rpc_arrive_and_distribute(BIGINT,JSONB,UUID,TEXT,TEXT,TEXT)', 'EXECUTE') THEN
    RAISE EXCEPTION '⚠️ 收尾檢查失敗（變更可能已經生效，請照下面處理）：authenticated 沒有 EXECUTE 權限，兩個收貨頁都會壞掉。補救：GRANT EXECUTE ON FUNCTION public.rpc_arrive_and_distribute(BIGINT,JSONB,UUID,TEXT,TEXT,TEXT) TO authenticated;';
  END IF;

  -- 冪等防重整個機制的地基。沒建起來的話，重複收貨會靜默通過。
  IF NOT EXISTS (
        SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relname = 'idx_gr_client_request') THEN
    RAISE EXCEPTION '⚠️ 收尾檢查失敗（變更可能已經生效，請照下面處理）：idx_gr_client_request 不存在，收貨冪等防重形同虛設。補救：CREATE UNIQUE INDEX idx_gr_client_request ON goods_receipts (tenant_id, client_request_id) WHERE client_request_id IS NOT NULL;';
  END IF;
END $$;

-- ⚠️ 這裡的參數列表不可以省（原版 20260512000002 省了，因為當時只有一支）：
--    真的出現多載時，不帶參數的 COMMENT ON FUNCTION 會先報
--    「function name is not unique」，把上面那個講得清楚的錯誤訊息蓋掉。
COMMENT ON FUNCTION
  public.rpc_arrive_and_distribute(BIGINT, JSONB, UUID, TEXT, TEXT, TEXT) IS
  '進貨確認：GR 入倉（不再自動建 picking_wave；撿貨改由工作站手動建立）。'
  'p_client_request_id 帶了就冪等（重試回既有 GR）；'
  'p_arrivals[i].qty_received_base 帶了就比對現值（擋多台裝置用過期數字重複收貨）。'
  '兩個都可空，不帶＝行為與 20260512000002 完全相同。';
