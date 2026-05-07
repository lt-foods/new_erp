-- ============================================================================
-- member_merges 缺 SELECT policy → 前端讀不到、UI 看不到合併紀錄
-- 補：tenant 內的人都可讀（與 members / wallet_ledger / points_ledger 同 pattern）
-- 寫入仍只走 SECURITY DEFINER RPC，policy 不開 INSERT/UPDATE/DELETE
-- ============================================================================

CREATE POLICY auth_read_member_merges ON member_merges
  FOR SELECT USING (tenant_id = (auth.jwt() ->> 'tenant_id')::uuid);
