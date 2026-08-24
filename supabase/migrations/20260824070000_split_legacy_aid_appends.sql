-- ============================================================
-- 2026-08-24: 總倉收件匣一店一單 —— 舊的互助併入拆開，並修正繼承來的假狀態
--
-- 症狀一（店家回報）：「松山 → 古華、囍願土雞蛋這一筆為什麼沒有在總倉收件匣？」
--   其實有，但它掛在**中和店**名下。那批貨被併進古華既有的
--   __INTERNAL_RESTOCK__-TF0486，而那張單身上有 3 家店的 5 次轉入；
--   v_hq_inbox_aid 顯示來源用的是 customer_orders.transferred_from_order_id，
--   那一欄只有「建立這張單」的第一趟會寫（= 中和店 AB-45-0001）→ 整張單被
--   算成「中和 → 古華」、5 個品項混成一列，松山端在收件匣裡找不到自己那批。
--
-- 症狀二（比較嚴重，是併單的連帶傷害）：**併進去的貨會繼承容器單的狀態**。
--   平鎮 TF0497 在 8/24 13:39 因為另一趟空中轉到貨而變 ready；而雞腿排那趟
--   （松山 → 平鎮、經總倉、12:27）被併進同一張單，於是也跟著顯示「可取貨」——
--   但它連 transfers 都沒有一張，貨根本還沒離開松山。20260824060000 的回填
--   把這個錯狀態原樣抄到拆出來的 TF0506 上（status=ready 但 ready_at 是空的，
--   就是繼承來的痕跡）。取貨閘門放行 = 直接把 on_hand 扣成負的，要修。
--
-- 做法：
--   1. 把還併在一起、且認得出屬於哪則互助貼文的轉入趟次拆成獨立單
--      （搬列不是複製，品項 id 不變）。
--   2. 每一張拆出來的單，狀態**依它自己那一趟**重算，不抄容器單：
--        有轉移單且已收貨 → ready；有轉移單未收 → shipping；
--        沒有轉移單但是空中轉（舊資料，自動出貨上線前） → shipping；
--        其餘（經總倉，等總倉收） → pending。
--      並把對應的那張 transfers 改指到新單，收貨時才推得動正確的單。
--   3. 20260824060000 已經拆出來的單一併重算（TF0506 就是靠這步修回 pending）。
--
-- 認貼文的三條路（依序取第一個認得出的）：
--   (a) reason 帶貼文編號 —— 20260824060000 之後的新資料。
--   (b) 手動現貨：rpc_claim_manual_spot 會在載體單（AB-xx-000n）品項的 notes
--       蓋「[互助板認領 #N]」，而那張載體單只為那一次認領而生 → 從它轉出去的
--       那一趟就是那次認領。線上 #119/#206/#207/#208 靠這條。
--   (c) 有來源訂單的釋出貼文：來源單 + SKU 對得起來，且貼文早於這趟轉移。
--       線上 #227（松山 OV-2-0001 的囍願土雞蛋）靠這條。
--   認不出來的**不動** —— 拆了卻沒有 aid_board_id 可蓋，會撞
--   customer_orders_trio_kind_active_uniq（那個唯一索引只放行蓋過章的單）。
--
-- ⚠ transfers 對到哪一趟：t.shipped_at 落在 [l.transferred_at, +1 秒) 之內。
--   不能用等號 —— 連結表回填時 transferred_at 被截到秒，而 transfers 留著毫秒
--   （線上 link 516 就是 09:13:06 對 09:13:06.810991，等號比不出來）。
--
-- 只搬還在店裡的品項（pending/reserved/ready）；已取貨 / 已取消的動了就是改到歷史。
-- 容器單至少留一件，不生空殼單。
--
-- Rollback：拆出來的單都帶 [回填拆單] notes 且 aid_board_id 非空，
--   把品項搬回 notes 裡寫的原單、transfers 改回原單、刪掉新單、
--   把 link 的 dest_order_id 改回去即可。
-- ============================================================

DO $backfill$
DECLARE
  r              RECORD;
  v_seq          INT;
  v_campaign_no  TEXT;
  v_new_order_id BIGINT;
  v_new_order_no TEXT;
  v_split        INT := 0;
  v_fixed        INT := 0;
BEGIN
  -- ------------------------------------------------------------
  -- 1. 拆併入
  -- ------------------------------------------------------------
  FOR r IN
    SELECT l.id AS link_id, l.source_order_id, l.dest_order_id, l.dest_item_ids,
           l.is_air_transfer, l.transferred_at,
           d.tenant_id, d.campaign_id, d.channel_id, d.member_id,
           d.pickup_store_id, d.nickname_snapshot,
           s.order_no AS src_no,
           COALESCE(
             (regexp_match(l.reason, '互助板[^#]*#([0-9]+)'))[1]::BIGINT,
             (SELECT b.id FROM mutual_aid_board b
                JOIN customer_order_items ci
                  ON ci.notes LIKE '%互助板認領 #' || b.id || '%'
               WHERE ci.order_id = l.source_order_id
               ORDER BY b.id DESC LIMIT 1),
             (SELECT b2.id FROM mutual_aid_board b2
               WHERE b2.source_customer_order_id = l.source_order_id
                 AND b2.sku_id = (SELECT i2.sku_id FROM customer_order_items i2
                                   WHERE i2.id = l.dest_item_ids[1])
                 AND b2.created_at <= l.transferred_at
               ORDER BY b2.created_at DESC LIMIT 1)
           ) AS board_id
      FROM customer_order_transfer_links l
      JOIN customer_orders d ON d.id = l.dest_order_id
      JOIN customer_orders s ON s.id = l.source_order_id
     WHERE l.appended
       AND s.pickup_store_id IS DISTINCT FROM d.pickup_store_id
     ORDER BY l.transferred_at
  LOOP
    -- 認不出屬於哪則貼文的不動（沒有 aid_board_id 可蓋 → 會撞唯一索引）
    IF r.board_id IS NULL THEN CONTINUE; END IF;

    IF NOT EXISTS (
      SELECT 1 FROM customer_order_items i
       WHERE i.id = ANY (r.dest_item_ids)
         AND i.order_id = r.dest_order_id
         AND i.status IN ('pending','reserved','ready')
    ) THEN CONTINUE; END IF;

    -- 容器單至少留一件，不生空殼單
    IF NOT EXISTS (
      SELECT 1 FROM customer_order_items i
       WHERE i.order_id = r.dest_order_id
         AND NOT (i.id = ANY (r.dest_item_ids))
    ) THEN CONTINUE; END IF;

    SELECT campaign_no INTO v_campaign_no
      FROM group_buy_campaigns WHERE id = r.campaign_id;

    -- TF 序號比照 rpc_transfer_order_partial：MAX+1，不是 COUNT+1
    PERFORM pg_advisory_xact_lock(hashtext('order_tf_seq:' || r.campaign_id::text));
    SELECT COALESCE(MAX(substring(order_no FROM '-TF([0-9]+)$'))::INT, 0) + 1
      INTO v_seq
      FROM customer_orders
     WHERE tenant_id = r.tenant_id AND campaign_id = r.campaign_id
       AND order_no ~ '-TF[0-9]+$';
    v_new_order_no := v_campaign_no || '-TF' ||
                      lpad(v_seq::text, GREATEST(length(v_seq::text), 4), '0');

    -- 狀態先建成 pending，第 2 段統一依「自己那一趟」重算（含既有的拆出單）
    INSERT INTO customer_orders (
      tenant_id, order_no, campaign_id, channel_id, member_id, nickname_snapshot,
      pickup_store_id, status, notes, transferred_from_order_id, is_air_transfer,
      aid_board_id, created_at, updated_at
    ) VALUES (
      r.tenant_id, v_new_order_no, r.campaign_id, r.channel_id, r.member_id,
      r.nickname_snapshot, r.pickup_store_id, 'pending',
      '[回填拆單] 原本併在訂單 #' || r.dest_order_id || '，依來源單 #' ||
        r.source_order_id || ' (' || r.src_no || ') 拆成獨立轉入單（互助板 #' ||
        r.board_id || '）',
      r.source_order_id, COALESCE(r.is_air_transfer, FALSE),
      r.board_id, r.transferred_at, NOW()
    ) RETURNING id INTO v_new_order_id;

    UPDATE customer_order_items
       SET order_id = v_new_order_id, updated_at = NOW()
     WHERE id = ANY (r.dest_item_ids) AND order_id = r.dest_order_id;

    -- 這一趟自己的轉移單也要跟著改指過去，否則收貨時推的是容器單
    UPDATE transfers t
       SET customer_order_id = v_new_order_id
     WHERE t.customer_order_id = r.dest_order_id
       AND t.status <> 'cancelled'
       AND t.shipped_at >= r.transferred_at
       AND t.shipped_at <  r.transferred_at + INTERVAL '1 second';

    UPDATE customer_order_transfer_links
       SET dest_order_id = v_new_order_id, appended = FALSE, aid_board_id = r.board_id
     WHERE id = r.link_id;

    UPDATE customer_orders
       SET notes = COALESCE(notes, '') ||
                   E'\n[拆單] 來源單 #' || r.source_order_id || ' 那一趟的貨已拆到 ' ||
                   v_new_order_no || '（' || to_char(NOW(), 'YYYY-MM-DD HH24:MI:SS') || '）',
           updated_at = NOW()
     WHERE id = r.dest_order_id;

    v_split := v_split + 1;
  END LOOP;

  -- ------------------------------------------------------------
  -- 2. 拆出來的單，狀態依「自己那一趟」重算
  --    20260824060000 的回填直接抄容器單的狀態，於是雞腿排（經總倉、
  --    連轉移單都沒有）繼承到平鎮容器單的 ready，變成「還沒出貨卻可取貨」。
  -- ------------------------------------------------------------
  FOR r IN
    SELECT co.id, co.status AS cur_status,
           l.is_air_transfer, l.transferred_at,
           t.id AS transfer_id, t.received_at
      FROM customer_orders co
      JOIN customer_order_transfer_links l ON l.dest_order_id = co.id
      LEFT JOIN transfers t
        ON t.customer_order_id = co.id
       AND t.status <> 'cancelled'
       AND t.shipped_at >= l.transferred_at
       AND t.shipped_at <  l.transferred_at + INTERVAL '1 second'
     WHERE co.aid_board_id IS NOT NULL
       AND co.notes LIKE '[回填拆單]%'
       -- 已取貨 / 已取消的不要回頭改
       AND co.status IN ('pending','confirmed','shipping','ready')
  LOOP
    DECLARE
      v_want TEXT := CASE
        WHEN r.transfer_id IS NOT NULL AND r.received_at IS NOT NULL THEN 'ready'
        WHEN r.transfer_id IS NOT NULL THEN 'shipping'
        -- 空中轉＝轉單當下貨就離開轉出店（20260814030000）；舊資料可能沒建轉移單
        WHEN r.is_air_transfer THEN 'shipping'
        ELSE 'pending'   -- 經總倉：等總倉收貨
      END;
    BEGIN
      IF v_want IS DISTINCT FROM r.cur_status THEN
        UPDATE customer_orders
           SET status   = v_want,
               -- ready_at 只有真的到貨才留；退回 pending 要一起清掉，
               -- 否則畫面會顯示一個根本沒發生過的到貨時間
               ready_at = CASE WHEN v_want = 'ready' THEN COALESCE(ready_at, r.received_at) ELSE NULL END,
               notes    = COALESCE(notes, '') ||
                          E'\n[狀態修正] ' || r.cur_status || ' → ' || v_want ||
                          '（原本抄的是容器單狀態，改成依這一趟自己的進度）',
               updated_at = NOW()
         WHERE id = r.id;
        v_fixed := v_fixed + 1;
      END IF;
    END;
  END LOOP;

  RAISE NOTICE '互助併入拆單：拆 % 筆、狀態修正 % 筆', v_split, v_fixed;
END;
$backfill$;
