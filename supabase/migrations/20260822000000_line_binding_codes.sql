-- ============================================================================
-- 2026-08-22: line_binding_codes —— 限量商品下單前的「店家 LINE 一鍵綁定」
--
-- 問題：會員拿到商城連結、LINE Login 登入就能下單，但店家沒有他的聯絡方式，
-- 棄單就找不到人。既有的 account link 綁定（line-webhook 邀請 → /link 頁）
-- 只有「會員主動傳訊息給店家 OA」才會啟動，覆蓋不到下單這條路。
--
-- 解法：會員在商城按「下單限量商品」時，liff-api（start_line_binding）發一組
-- 綁定碼，前端開店家 OA 對話並預填「綁定碼：XXXXXX」訊息；會員按送出（順手
-- 加了好友），line-webhook 收到訊息、比對這張表，直接把該 OA provider 的
-- line_user_id 連上會員（寫 store_line_followers.member_id）—— 效果等同
-- account link，但不用經過 LINE 的 accountLink 對話框，一則訊息就完成。
--
-- 這張表只有 edge function（service_role）讀寫：
--   liff-api  start_line_binding：發碼（同會員同店 30 分鐘內重複使用同一組）
--   line-webhook：訊息帶碼 → 核銷（used_at + line_user_id）並完成綁定
-- 前端拿不到別人的碼（無 RLS policy = anon / authenticated 全零列），
-- 碼本身也只是「這位會員要綁這家店」的一次性憑據，不含任何敏感資料。
--
-- Rollback：DROP TABLE IF EXISTS line_binding_codes;
-- ============================================================================

CREATE TABLE IF NOT EXISTS line_binding_codes (
  id           BIGSERIAL   PRIMARY KEY,
  tenant_id    UUID        NOT NULL,
  member_id    BIGINT      NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  store_id     BIGINT      NOT NULL REFERENCES stores(id) ON DELETE CASCADE,
  code         TEXT        NOT NULL,
  -- 核銷時回填：送出綁定訊息的那個 LINE 使用者（該店 OA provider 的 ID）
  line_user_id TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at   TIMESTAMPTZ NOT NULL,
  used_at      TIMESTAMPTZ
);

COMMENT ON TABLE line_binding_codes IS
  '限量商品下單前的 LINE 綁定碼。liff-api 發碼、line-webhook 核銷；只有 service_role 讀寫';
COMMENT ON COLUMN line_binding_codes.code IS
  '預填進 OA 訊息的一次性綁定碼（6 碼，去除易混淆字元）。活著的碼全域唯一';
COMMENT ON COLUMN line_binding_codes.line_user_id IS
  '核銷時回填：送碼進來的 LINE 使用者（店家 OA provider 的 ID），除錯 / 稽核用';

-- 活著的碼（還沒核銷）全域唯一 —— webhook 只憑 code + store 就要找得到唯一一筆。
-- 過期未用的碼會繼續佔號到被核銷或刪除；發碼端撞號時重生一組即可（機率極低）。
CREATE UNIQUE INDEX IF NOT EXISTS idx_line_binding_codes_active_code
  ON line_binding_codes (code) WHERE used_at IS NULL;

-- 發碼端查「這位會員在這家店有沒有還活著的碼」（重複按下單不重發）
CREATE INDEX IF NOT EXISTS idx_line_binding_codes_member_active
  ON line_binding_codes (member_id, store_id) WHERE used_at IS NULL;

-- 前端一律讀不到：不給任何 policy，service_role bypass 不受影響
-- （同 store_line_oa_credentials 的做法，見 20260807000030）
ALTER TABLE line_binding_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON line_binding_codes FROM anon, authenticated;
