-- ============================================================================
-- 20260921010000_line_note_disable_auto_post_on_open.sql
--
-- 老闆 9/21 交代：「開團自動機器人 po 記事本」先關掉。
--
-- 做法是**只拿掉 trigger**：`_line_note_on_campaign_open()` 函式本體留著、
-- `line_note_communities.auto_post_on_open` 的資料也一列都不動 —— 要開回來就是把
-- 下面 rollback 那一句 CREATE TRIGGER 跑回去，各社群原本的設定原封不動還在。
-- （不要改成把 auto_post_on_open 全清成 FALSE：那是使用者資料，清掉就回不去了，
--   而且後台勾回來會以為又開了。）
--
-- 不受影響（發文能力沒有被拿掉，只是不再自動觸發）：
--   * 開團列表每一團的「LINE 記事本」按鈕 → rpc_line_note_queue_posts（總部）
--   * LINE 記事本 → 社群設定 → 每列的「發文」→ rpc_line_note_queue_post
--   * 定時讀留言加單（listen_enabled / read_times）、按笑臉、留言處理
--   * rpc_line_note_campaign_targets 的 can_post / scoped 判定（本來就不看 auto_post_on_open）
--
-- 基底（已 grep 全 migrations 確認）：
--   _line_note_on_campaign_open()      @ 20260909020000（最新版，函式不動）
--   trg_line_note_on_campaign_open     @ 20260908010000（本次移除的就是它）
--
-- rollback：
--   CREATE TRIGGER trg_line_note_on_campaign_open
--     AFTER UPDATE OF status ON public.group_buy_campaigns
--     FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_open();
-- ============================================================================

DROP TRIGGER IF EXISTS trg_line_note_on_campaign_open ON public.group_buy_campaigns;

COMMENT ON FUNCTION public._line_note_on_campaign_open() IS
  '開團（status → open）自動排記事本發文。20260921010000 起 trigger 已移除（老闆交代先關掉），'
  '函式保留以便隨時開回來：CREATE TRIGGER trg_line_note_on_campaign_open AFTER UPDATE OF status '
  'ON public.group_buy_campaigns FOR EACH ROW EXECUTE FUNCTION public._line_note_on_campaign_open();';

COMMENT ON COLUMN public.line_note_communities.auto_post_on_open IS
  '開團時自動發文。20260921010000 起全站停用（trigger 已移除），這一欄暫時不影響任何行為，'
  '保留是為了開回來時沿用各社群原本的設定；後台顯示成「暫停中」，發文改由開團列表的「LINE 記事本」按鈕手動排。';
