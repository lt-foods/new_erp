# 測試項目 — 會員合併：目標可有訂單，只擋真正撞單

**對應 migration:** `supabase/migrations/20260714000070_rpc_merge_member_target_orders_collision_only.sql`
**對應 UI:** `apps/admin/src/components/MemberMergeModal.tsx`、`apps/admin/src/lib/rpcError.ts`
**基底版本:** `20260701030000_rpc_merge_member_move_orders_block_target.sql`（rollback 指回此檔）

> 需求（使用者 2026-07-11，個案 `M20260701073103771`「tde美 715890-古華」）：
> 客人早就綁 LINE 並用 LINE 會員下過單，同時又有一筆未綁 LINE 的虛擬會員也累積訂單。
> 舊版（`20260701030000`）因「目標(LINE)已有訂單」一律擋 → 無法合併。
> 但那個擋只是怕搬訂單撞 `customer_orders_trio_kind_active_uniq`
> `(tenant_id, campaign_id, channel_id, member_id, order_kind) WHERE status NOT IN ('transferred_out','expired','cancelled')`。
> 只有來源與目標**同 trio+kind 都有 active 訂單**時才真的會撞，其餘搬移完全不衝突。

## 1. RPC 層（`rpc_merge_member`）

### 1.1 精準守門：同 (團, 頻道, 訂單類型) 兩邊都有 active 訂單 → 擋
- [ ] 來源、目標各有一筆 active 訂單且 `(tenant, campaign, channel, order_kind)` 相同
      → RAISE `merge would collide: source % and target % ... cannot merge`
- [ ] 擋下時**完全無副作用**（來源仍 `status<>'merged'`、無 `member_merges` 新列、訂單未搬、餘額未動）

### 1.2 正常流程：目標有訂單但不撞 → 合併成功，訂單一起搬
- [ ] 目標(已綁 LINE)已有 ≥1 筆訂單、且與來源訂單無同 trio+kind active 重疊 → 合併成功不報錯
- [ ] 來源所有 `customer_orders` 的 `member_id` 改成目標；搬完不違反 `customer_orders_trio_kind_active_uniq`
- [ ] `customer_line_aliases` / `member_tags` / `member_cards` / `points_ledger` / `wallet_ledger` 的 member_id 由來源改為目標
- [ ] 點數 / 儲值金餘額併入目標（UPSERT 相加），來源餘額列刪除
- [ ] 來源 `status='merged'`、`merged_into_member_id=目標`，寫一筆 `member_merges`

### 1.3 既有守門不回歸
- [ ] 來源已綁 LINE → RAISE already bound；來源已 merged → RAISE already merged
- [ ] guest_id = real_id → RAISE must differ；來源不存在 → RAISE not found
- [ ] 跨 tenant：守門與搬移都帶 `tenant_id=v_tenant`

### 1.4 已驗證（2026-07-11，個案 51647 → 67078，正式庫 dry-run 後 ROLLBACK）
```
DO $$ DECLARE v int; s text;
BEGIN
  PERFORM rpc_merge_member(51647, 67078, NULL, 'DRY-RUN');   -- 未撞、成功
  SELECT count(*) INTO v FROM customer_orders WHERE member_id=67078;  -- 8 → 44
  SELECT status  INTO s FROM members WHERE id=51647;                  -- active → merged
  RAISE EXCEPTION 'DRYRUN_OK tgt=% src=%', v, s;              -- 靠 RAISE 自動 rollback，不落地
END $$;
-- 結果：DRYRUN_OK tgt=44 src=merged；rollback 後目標仍 8 筆、來源仍 active（無殘留）
```

## 2. UI 層（MemberMergeModal）
- [ ] 彈窗黃框文案：目標「可以已有訂單」，只有「同一團同一頻道兩邊都有進行中訂單」才無法合併
- [ ] 撞單時紅框顯示中文（經 `translateRpcError`）：「兩筆會員在『同一團、同一頻道』都有進行中的訂單，無法自動合併…」
- [ ] 一般成功 → alert + `onMerged()` 刷新

## 驗證方式
- RPC：Management API `database/query` 跑 §1.4 dry-run（RAISE 自動 rollback，不影響正式資料）
- UI：`next build` 綠；實際合併由門市人員於後台點按（不可還原、屬人工操作）
