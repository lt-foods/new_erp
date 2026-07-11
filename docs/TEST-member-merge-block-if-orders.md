# 測試項目 — 會員合併：來源有訂單則禁止合併

> ⚠️ **已被後續版本取代（歷史文件，勿依此驗收）**
> - 2026-07-01 起（`20260701030000`）：來源(未綁 LINE)**可以**有訂單，訂單會一起搬到目標；改為「目標(已綁 LINE)有訂單就擋」。
> - 2026-07-11 起（`20260714000070`）：目標**也可以**有訂單；只有當來源與目標在同一 `(tenant, campaign, channel, order_kind)` 都有 active 訂單（真的會撞唯一索引）時才擋。
> 目前正確行為請看 **`docs/TEST-member-merge-target-orders-collision.md`**。

**對應 migration:** `supabase/migrations/20260618000030_rpc_merge_member_block_if_guest_has_orders.sql`
**對應 UI:** `apps/admin/src/components/MemberMergeModal.tsx`、`apps/admin/src/lib/rpcError.ts`

> 決策（使用者 2026-05-18）：合併只在「來源(未綁 LINE / 虛擬)會員身上**沒有任何 `customer_orders`**」時才允許。
> 訂單**個別是個別的、永遠不搬移**（移除原本 `UPDATE customer_orders SET member_id`）。
> 儲值金 / 點數 / 卡片 / 標籤 / 暱稱對應 / 流水等「其他」資料**照舊** merge 搬到正式會員。

## 1. RPC 層（`rpc_merge_member`）

### 1.1 守門：來源有訂單 → 擋
- [ ] 來源會員有 ≥1 筆 `customer_orders`（任何狀態，含 cancelled）→ 呼叫 RAISE `source member % has orders, cannot merge`
- [ ] 擋下時**完全無副作用**：來源仍 `status<>'merged'`、`member_cards`/`points_ledger`/`wallet_ledger`/`member_tags`/`customer_line_aliases` 都沒被改、無 `member_merges` 新列、餘額未動

### 1.2 正常流程：來源無訂單 → 合併（訂單以外照搬）
- [ ] 來源會員 0 筆 `customer_orders` → 合併成功不報錯
- [ ] `customer_line_aliases` / `member_tags` / `member_cards` / `points_ledger` / `wallet_ledger` 的 member_id 由來源改為目標
- [ ] 點數 / 儲值金餘額併入目標（UPSERT 相加），來源餘額列刪除
- [ ] 來源 `status='merged'`、`merged_into_member_id=目標`，寫一筆 `member_merges`
- [ ] **`customer_orders` 完全不被觸碰**（本來就 0 筆；確認函式內已無 `UPDATE customer_orders`）

### 1.3 既有守門不回歸
- [ ] 來源已綁 LINE（line_user_id 不為 null）→ RAISE already bound
- [ ] 來源已 merged → RAISE already merged
- [ ] guest_id = real_id → RAISE must differ
- [ ] 來源不存在 → RAISE not found
- [ ] 跨 tenant：守門查 `customer_orders` 帶 `tenant_id=v_tenant`，不會誤判別 tenant 的訂單

### 1.4 驗證 SQL（Supabase Studio，auto 模式無法 push、SQL 交使用者跑）
```sql
-- 函式已無搬訂單那行
SELECT pg_get_functiondef('rpc_merge_member(bigint,bigint,uuid,text)'::regprocedure)
  NOT LIKE '%UPDATE customer_orders%SET member_id%' AS orders_move_removed;  -- 期望 true
-- 守門：建一個有訂單的 guest，呼叫應 raise
-- 正常：建一個無訂單的 guest，呼叫應成功且 customer_orders 不變
```

## 2. UI 層（MemberMergeModal）

- [ ] 兩個方向（guest-to-real / real-from-guest）合併彈窗文案：**不再**出現「訂單會搬」；改為「訂單不會搬移、有訂單則無法合併」
- [ ] 來源有訂單時按「合併」→ 紅框錯誤顯示中文「來源會員仍有訂單，無法合併。訂單個別獨立、不會搬移；請先處理…」（經 `translateRpcError`，非 raw 英文 / 非 `[object Object]`）
- [ ] 來源無訂單 → 合併成功 alert + `onMerged()` 刷新
- [ ] 既有錯誤（已綁 LINE / 已合併）也都有中文

## 3. 回歸
- [ ] 會員列表 / MemberDetail「已合併 → #x」標記、guest 標記顯示不變
- [ ] 既有「已 merged」歷史資料不受影響（本 migration 只改函式、不回填）

## 驗證方式
- RPC：上述 SQL 於 Supabase Studio 實跑
- UI：`next build` 綠；preview 互動由使用者自審（沙箱阻擋 admin 登入）
