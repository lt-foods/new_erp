-- ============================================================================
-- 20260927000000_line_note_post_on_insert_open.sql
--
-- 開團自動發文（LINE 記事本）漏掉「一建立就是 open」的團。
--
-- trg_line_note_on_campaign_open 從 20260908010000 起只掛 AFTER UPDATE OF status，
-- 但商品頁建團 rpc_create_campaign_from_product（20260925000000；開團時間＝現在時）
-- 是直接 INSERT status='open'，rpc_clone_store_campaign / rpc_upsert_campaign 帶
-- p_status='open' 也是 —— 這些團從來沒有進過 trigger，一個社群都不會自動發。
-- 畫面上看起來「有 7 個社群」其實是店員先手動貼到 LINE、讀取留言時才對上團的貼文
-- （posted_at 早於 line_note_posts.created_at、created_by 是 NULL），少貼的社群就空著。
-- 9/27 老闆問「為什麼松山沒有 po」（GRP-20260925-002）就是這樣：7 個社群是 18:26–18:48
-- 手動貼的，18:58 才從商品頁建團，松山沒手動貼、系統也沒發。
--
-- 修法：trigger 改成 AFTER INSERT OR UPDATE OF status；函式的「剛變成 open」判斷
-- 對 INSERT 不看 OLD（TG_OP='INSERT' 時 OLD 是 NULL，原本 `OLD.status = 'open'`
-- 會是 NULL → 整個守衛 NULL → 不 RETURN → 反而剛好會跑，但那是靠 NULL 邏輯碰巧對，
-- 這裡寫明白）。另外擋掉 restock sentinel（campaign_no = '__INTERNAL_RESTOCK__'，
-- 20260612000020 建立時就是 'open'、owner_store_id NULL → 不擋會發到所有社群）。
--
-- 商品頁建團的順序是「先 INSERT 團、同一交易再補 campaign_items」；
-- 工作是 line_note_jobs 一列，worker 下一分鐘才來拿，交易早就 commit，品項齊了。
--
-- 基底：_line_note_on_campaign_open @ 20260925070000（只加 TG_OP 與 sentinel 兩個守衛）。
-- 順帶：trg_campaigns_lock_on_open（價格鎖）同樣只掛 UPDATE，但它要看 campaign_items，
-- 對「先建團後補品項」的路徑掛 INSERT 也鎖不到東西，不在這支處理。
--
-- 已經開著、沒自動發到的團不回補：老闆看到哪個社群缺就在開團列表的「LINE 記事本」
-- 彈窗勾那個社群發文；自動補會把兩天前的舊團一口氣貼一輪。
--
-- rollback：
--   DROP TRIGGER trg_line_note_on_campaign_open ON group_buy_campaigns;
--   CREATE TRIGGER trg_line_note_on_campaign_open AFTER UPDATE OF status ON group_buy_campaigns
--     FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_open();
--   函式還原到 20260925070000 那版。
-- ============================================================================

CREATE OR REPLACE FUNCTION public._line_note_on_campaign_open()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER
AS $$
DECLARE
  v_c RECORD;
  v_post BIGINT;
BEGIN
  -- 只在「剛變成 open」時跑：INSERT 直接看 NEW，UPDATE 要 OLD 不是 open
  IF NEW.status <> 'open' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'open' THEN RETURN NEW; END IF;
  -- 補貨申請的 sentinel 團（20260612000020）建立時就是 open，不是要發的團
  IF NEW.campaign_no = '__INTERNAL_RESTOCK__' THEN RETURN NEW; END IF;

  FOR v_c IN
    SELECT c.id AS community_id, c.account_id, c.post_mode
      FROM line_note_communities c
      JOIN line_note_accounts a ON a.id = c.account_id AND a.status = 'active'
     WHERE c.tenant_id = NEW.tenant_id
       AND c.auto_post_on_open
       AND c.share_from_community_id IS NULL
       AND (NEW.owner_store_id IS NULL OR c.store_id = NEW.owner_store_id)
       AND public._line_note_takes_channel(c.sales_channels, NEW.sales_channel)
  LOOP
    INSERT INTO line_note_posts (tenant_id, community_id, campaign_id, status, share_state, created_by, updated_by)
    VALUES (NEW.tenant_id, v_c.community_id, NEW.id, 'queued',
            CASE WHEN v_c.post_mode = 'immediate' THEN 'none' ELSE 'scheduled' END,
            NEW.updated_by, NEW.updated_by)
    ON CONFLICT (community_id, campaign_id) DO NOTHING
    RETURNING id INTO v_post;
    IF v_post IS NOT NULL THEN
      INSERT INTO line_note_jobs (tenant_id, kind, account_id, community_id, post_id, created_by)
      VALUES (NEW.tenant_id, 'post', v_c.account_id, v_c.community_id, v_post, NEW.updated_by);
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_open ON public.group_buy_campaigns;
CREATE TRIGGER trg_line_note_on_campaign_open
  AFTER INSERT OR UPDATE OF status ON public.group_buy_campaigns
  FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_open();
