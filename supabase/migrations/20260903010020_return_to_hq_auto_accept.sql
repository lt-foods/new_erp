-- ============================================================================
-- 2026-09-02（收件匣減法案 · 刀 3）：退貨回總倉 —— 48 小時沒人處理就自動同意收回
--
-- 老闆 2026-09-02 裁示（甲案，原話整理見 需求暨計畫_收件匣減法案_2026-09-02.md §刀3）：
--   「確認入倉」→「同意收回」；「取消」→「不同意退貨」（改名在前端，本檔不碰）。
--   **待處理超過 48 小時未按 → 視同「同意收回」自動入倉；48h 內總倉隨時可按「不同意退貨」。
--     自動同意的單要留紀錄標明是自動的。**
--
-- ----------------------------------------------------------------------------
-- ⚠️⚠️ 做了會怎樣／不做會怎樣（兩邊都要講）
--
--   做了：48 小時沒人管，系統自己把退貨單收進總倉庫存。
--     ⇒ 若那批貨**實際上沒有到總倉**（店家沒寄／寄丟了），總倉帳面會多出不存在的貨；
--       之後派出去、店家收不到 ⇒ 變成新的一筆「收貨短少」。
--     ⇒ 而且它會**自動觸發下面那條既有的連帶行為**（見「連帶行為」節）。
--   不做：退貨單永遠卡在待處理，貨帳懸在半空、原客人訂單也跟著卡住
--     —— 這正是老闆要解掉的東西。
--   ⇒ 老闆已裁示做（甲案）。本檔照做，並把上面這件事**寫到畫面上**讓總倉知道有時鐘在跑
--     （前端 hq/inbox 那半）。
--
-- ----------------------------------------------------------------------------
-- ⚠️ 連帶行為（逐段查證，不是推測）：「同意收回」走的是 rpc_receive_transfer 主線。
--   對 return_to_hq 而言，該支最新版（20260827000000）裡：
--     邏輯 A0(:188) / C(:271) / E(:386) / F(:414) 都被 `v_transfer_type = 'hq_to_store'` 擋住
--       ⇒ 退貨單走不進去 ✅（不會配單、不會推播、不會進現貨池）
--     **但邏輯 B（:256-265）不看 transfer_type**，條件只有 `v_customer_order_id IS NOT NULL`，
--       而退貨單身上有 customer_order_id
--       （rpc_create_order_return 建單時就寫，20260801000000_full_return_closes_order:168）
--       ⇒ **原訂單若當下是 shipping，會被推成 ready。**
--   這是 8/27 之前就存在的既有行為，本檔沒有改它；
--   但**本檔把它自動化了**（原本要人按才發生）⇒ 必須寫出來，不可以裝作沒有。
--
-- ----------------------------------------------------------------------------
-- 母體怎麼框（⭐ 逐字對齊畫面，不是自己另訂一套）
--   畫面上「同意收回／不同意退貨」兩顆鈕的出現條件（hq/inbox/page.tsx:2886, :2937-2947）：
--       status === 'shipped'  且  dest_location === HQ  且  isOrderReturnTransfer(notes)
--   其中 isOrderReturnTransfer 是 `notes.startsWith("[order return")`（同檔 :189-191）。
--   本檔三個條件一個不少地照抄。
--
--   ⚠️ 為什麼不簡化成 `transfer_type='return_to_hq'`（雖然查證顯示兩者等價）：
--     全庫只有兩處建 return_to_hq —— rpc_create_order_return（status='shipped'，
--     notes 一律 '[order return…' 開頭，20260801000000:155-171）與
--     20260901000010 的短收沖帳單（status='received'，notes 是 '[短收沖帳]…'）。
--     ⇒ 對 status='shipped' 的單來說兩個口徑今天確實等價。
--     **但等價是「今天的資料剛好如此」，不是保證。** 只要有人新增第三種建單路徑，
--     寬的那個口徑就會把「畫面上根本沒有那顆鈕的單」自動處理掉 ——
--     自動化的東西不可以比人能按的範圍大。所以照抄畫面，不取巧。
--
-- ----------------------------------------------------------------------------
-- 冪等：天然的。收完 status 就變 received ⇒ 下一輪掃不到它。
--   同一輪內每張單各自 BEGIN/EXCEPTION（樣板沿用 rpc_transfer_arrive_at_hq_batch），
--   一張失敗不會拖垮整批。
--
-- 開關：**就是 pg_cron 這個 job 本身**（repo 現有 4 支 cron job 全是這個慣例：
--   20260605000014 / 20260707000020 / 20260720000030 / 20260827010000）。
--   ⇒ 要停：  SELECT cron.unschedule('hq-auto-accept-overdue-returns');
--   ⇒ 要開回來：把本檔最後那段 cron.schedule 再貼一次（同名 job 是冪等的）。
--   ⇒ 想先看看「如果現在跑會處理掉哪些」而不真的動手：
--        SELECT public.rpc_auto_accept_overdue_returns(TRUE);   -- TRUE = 只看不做
--   ⭐ 刻意**不新建設定表**：全庫沒有任何 settings/feature_flag 表
--     （grep 只有 xiaolan_settings，那是別的系統的），
--     為了一個開關新開一張表＝多一個沒人維護的東西。
--
-- 操作者：'00000000-0000-0000-0000-000000000000'（全零 sentinel）。
--   ⚠️ 不能用 NULL —— stock_movements.operator_id 是 NOT NULL
--      （20260422120003_inventory_schema.sql:75）。
--   全零這個值在本 repo 已是既有慣例（rpc_merge_member 等 5 支的
--   `COALESCE(p_operator, auth.uid(), '00000000-…-0000')`）。
--   ⭐ 它同時就是「這筆是自動的」的判準：received_by = 全零 ⇒ 自動；其餘 ⇒ 有人按的。
--
-- Rollback：
--   SELECT cron.unschedule('hq-auto-accept-overdue-returns');
--   DROP FUNCTION public.rpc_auto_accept_overdue_returns(BOOLEAN);
--   ⚠️ 已經自動收掉的單**不會**自己退回去 —— 要退，對那張單走既有的
--     「取消收貨」(rpc_unreceive_transfer)，它會把庫存反向沖銷乾淨。
--
-- 本檔不改任何既有函式、不改任何 view、無資料異動。
--
-- ============================================================================
-- ⭐⭐ 2026-09-03 重定基（Alex #898~#904 已上線）—— 本檔對新 main 重驗結論
-- ============================================================================
--
-- ✅ 依賴沒變：本檔唯一呼叫的 rpc_receive_transfer，最新版仍是
--    20260827000000_receive_gate_only_batch_sku_orders.sql（用標準查法對新 main 確認），
--    簽章仍是 5 參數 (bigint, jsonb, uuid, text, boolean) ⇒ 呼叫方式不用改。
--    Alex 這波沒有重建這一支。
--
-- ✅ 與他的「✎ 修改實收」(rpc_adjust_received_transfer) **母體不相交**：
--    他那支硬擋 `IF v_status <> 'received' THEN RAISE`（20260903000200 那一段），
--    本檔的母體是 `status = 'shipped'` ⇒ 同一張單不會同時被兩邊處理。
--
-- 🔴🔴 **但有一個「我們自己放大的暴露面」，必須寫出來（CEO 2026-09-03 要求想過）**：
--
--    事實鏈（每一環都對新 main 查過）：
--      ① 他的「✎ 修改實收」是**純紀錄**，一筆庫存都不寫；
--      ② 它的月份鎖定守衛**只在 `transfer_type = 'hq_to_store'` 時才檢查**
--         （20260903000200 那一段，錨點 `IF v_transfer_type = 'hq_to_store'`）；
--      ③ 而月結的 `return_out` 段**直接乘 qty_received**
--         （20260901000000，錨點 `F) return_out`），每日對帳同一段也是；
--      ④ 「已收」清單的查詢只 `.eq("status","received")`、沒有單型過濾
--         （wms/inbound/page.tsx，錨點 `doneQ = doneQ.eq("status"`）。
--    ⇒ **`return_to_hq` 的客人退貨單一旦變成 received，就按得到「✎ 修改實收」，
--       而且沒有月份鎖定守衛。** 改下去：每日對帳（即時讀）動了、已鎖定月份的
--       月結快照不會重算 ⇒ 兩頁打架、帳面對不回來。
--
--    ⚠️ **這個缺口不是本檔造成的**（任何「人工按了同意收回」的退貨單早就有這個曝險），
--       **但本檔會讓更多單自動走到 received** ⇒ **踩到的機率被我們放大了**。
--    ⇒ 處置（照老闆「不是我做的我沒權利動」）：
--       缺口本身是 Alex 的檔、他的判定 ⇒ **當 P1 交回給他**（見施工回報）。
--       ⛔ 本檔**不**自己去補他的守衛，也**不**因此縮小 48h 的母體
--         —— 縮母體＝把老闆要的功能閹掉來繞過別人的 bug，那是錯的方向。
--    📌 要先降風險又不動他的檔，唯一乾淨的做法是「把 48h 的開關先關著」
--       （SELECT cron.unschedule('hq-auto-accept-overdue-returns');），
--       等他補上守衛再開 —— 這是**老闆的取捨**，不是我可以自己決定的。
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA cron TO postgres;

CREATE OR REPLACE FUNCTION public.rpc_auto_accept_overdue_returns(
  p_dry_run BOOLEAN DEFAULT FALSE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- 全零 sentinel：既是「系統」這個操作者，也是紀錄頁判「自動 vs 手動」的判準
  c_system_operator CONSTANT UUID := '00000000-0000-0000-0000-000000000000';
  c_hours           CONSTANT INT  := 48;
  v_row       RECORD;
  v_ok        BIGINT[] := ARRAY[]::BIGINT[];
  v_failed    JSONB    := '[]'::jsonb;
  v_would     JSONB    := '[]'::jsonb;
  v_err       TEXT;
BEGIN
  FOR v_row IN
    SELECT t.id, t.transfer_no, t.shipped_at, t.created_at
      FROM transfers t
     WHERE t.transfer_type = 'return_to_hq'
       AND t.status        = 'shipped'
       -- 逐字對齊畫面的 isOrderReturnTransfer（hq/inbox/page.tsx:189-191）
       AND COALESCE(t.notes, '') LIKE '[order return%'
       -- 逐字對齊畫面的 isHqDest（同檔 :2885）：那兩顆鈕只在目的地是「那一個」總倉時才出現。
       -- ⚠️ 不可以寫成 `l.type = 'central_warehouse'` —— 畫面拿到的 hqLocId 是
       --   `type='central_warehouse' AND is_active ORDER BY id LIMIT 1`（同檔 :1002-1009，
       --   單數一個），若哪天有第二個總倉，寬的寫法會自動處理到「畫面上根本沒有那顆鈕」的單。
       --   自動化的母體不可以比人能按的範圍大。
       AND t.dest_location = (
             SELECT l.id FROM locations l
              WHERE l.tenant_id = t.tenant_id
                AND l.type      = 'central_warehouse'
                AND l.is_active
              ORDER BY l.id
              LIMIT 1
           )
       -- shipped_at 由 rpc_create_order_return 建單時寫 NOW()，理論上一定有值；
       -- 退回 created_at 是為了「萬一是 NULL」時不會安靜地永遠不處理它
       AND COALESCE(t.shipped_at, t.created_at) < NOW() - make_interval(hours => c_hours)
     ORDER BY t.id
  LOOP
    IF p_dry_run THEN
      v_would := v_would || jsonb_build_object(
        'id', v_row.id,
        'transfer_no', v_row.transfer_no,
        'waiting_since', COALESCE(v_row.shipped_at, v_row.created_at)
      );
      CONTINUE;
    END IF;

    BEGIN
      -- 全收入總倉（p_lines = NULL ⇒ 照 qty_shipped 全收），
      -- 並把「這是自動的」寫進單據 notes —— 老闆要求自動處理要留紀錄標明是自動的。
      PERFORM rpc_receive_transfer(
        v_row.id,
        NULL,
        c_system_operator,
        '[自動同意收回] 超過 ' || c_hours || ' 小時總倉未處理，系統視同「同意收回」自動入倉（'
          || to_char(NOW() AT TIME ZONE 'Asia/Taipei', 'YYYY-MM-DD HH24:MI') || '）',
        FALSE
      );
      v_ok := v_ok || v_row.id;
    EXCEPTION WHEN OTHERS THEN
      v_err := SQLERRM;
      v_failed := v_failed || jsonb_build_object(
        'id', v_row.id, 'transfer_no', v_row.transfer_no, 'reason', v_err
      );
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run',   p_dry_run,
    'hours',     c_hours,
    'accepted',  to_jsonb(v_ok),
    'would_do',  v_would,
    'failed',    v_failed
  );
END;
$$;

-- 只給 cron / service_role 跑，不開放前端
-- （樣板逐字沿用 20260720000030_aid_board_badge_and_expiry_purge.sql 的 purge 那支）
REVOKE EXECUTE ON FUNCTION public.rpc_auto_accept_overdue_returns(BOOLEAN)
  FROM authenticated, anon, public;
GRANT EXECUTE ON FUNCTION public.rpc_auto_accept_overdue_returns(BOOLEAN)
  TO service_role;

COMMENT ON FUNCTION public.rpc_auto_accept_overdue_returns(BOOLEAN) IS
  '退貨回總倉滿 48 小時總倉沒處理 → 視同「同意收回」自動入倉（2026-09-02 刀 3，老闆甲案）。'
  '母體逐字對齊畫面上那兩顆鈕的出現條件：status=shipped ＋ 目的地是總倉 ＋ notes 以 [order return 開頭。'
  '操作者寫全零 sentinel ⇒ 紀錄頁靠 received_by = 全零 判「自動」；notes 另有 [自動同意收回] 標記。'
  '冪等：收完 status 變 received，下一輪掃不到。p_dry_run=TRUE 只回「會處理哪些」不動手。'
  '⚠ 連帶：rpc_receive_transfer 的邏輯 B 不看 transfer_type，原訂單若是 shipping 會被推成 ready。'
  '停用：SELECT cron.unschedule(''hq-auto-accept-overdue-returns'');';

-- 排程：每 30 分鐘（cron.schedule 同名 job 為 idempotent，重複 run migration 不會炸）
-- ⭐ 為什麼是 30 分鐘不是每分鐘：判準是「滿 48 小時」，早半小時晚半小時沒有差別，
--   而這支每跑一次都要掃 transfers ⇒ 沒必要一分鐘掃一次。
SELECT cron.schedule(
  'hq-auto-accept-overdue-returns',
  '*/30 * * * *',
  $cron$ SELECT public.rpc_auto_accept_overdue_returns(); $cron$
);
