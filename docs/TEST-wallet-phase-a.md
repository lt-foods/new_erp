# wallet-phase-a 測試項目 — admin 寫入介面

**對應 migration:**
- `supabase/migrations/20260606000000_wallet_write_rpcs.sql`（新）

**對應 UI 變更:**
- `apps/admin/src/components/MemberDetail.tsx`（修）
- `apps/admin/src/components/WalletActionModal.tsx`（新）

**對應 plan:** `C:\Users\Alex\.claude\plans\session-db-federated-thunder.md`

**前置背景:** `wallet_balances` + `wallet_ledger` + `rpc_wallet_topup` + `rpc_wallet_spend` 已在 `20260422120002_member_schema.sql` 落地。本階段補完寫入操作（refund / adjust / reverse）+ 後台 UI。

---

## 1. Schema / Migration 層

### 1.1 新 RPC 都存在
- [ ] `rpc_wallet_refund(uuid, bigint, numeric, text, bigint, text, uuid)` 存在、SECURITY DEFINER、回傳 BIGINT
- [ ] `rpc_wallet_adjust(uuid, bigint, numeric, text, uuid)` 存在、SECURITY DEFINER、回傳 BIGINT
- [ ] `rpc_wallet_reverse(uuid, bigint, text, uuid)` 存在、SECURITY DEFINER、回傳 BIGINT
- [ ] `fn_check_wallet_consistency()` 存在、READS sql、回傳 setof
  ```sql
  SELECT proname, prosecdef, pg_get_function_arguments(oid)
    FROM pg_proc
   WHERE proname IN ('rpc_wallet_refund','rpc_wallet_adjust',
                     'rpc_wallet_reverse','fn_check_wallet_consistency');
  ```

### 1.2 GRANT 設定
- [ ] 三支 public RPC（refund / adjust / reverse）都 `GRANT EXECUTE TO authenticated`
- [ ] `fn_check_wallet_consistency` 不對 authenticated grant（只給 ops 用）

### 1.3 既有約束未動
- [ ] `wallet_ledger` 仍是 append-only（`forbid_ledger_mutation` trigger 沒被改）
  ```sql
  SELECT tgname FROM pg_trigger
   WHERE tgrelid='wallet_ledger'::regclass AND NOT tgisinternal;
  -- expect: trg_no_update_wallet, trg_no_delete_wallet
  ```
- [ ] `wallet_balances` CHECK `balance >= 0` 仍在
- [ ] `wallet_ledger.type` CHECK 仍是 `IN ('topup','spend','refund','adjust','reversal')`

---

## 2. RPC 行為（SQL 直測）

### 2.1 rpc_wallet_refund — happy path
**情境：** 會員餘額 100，refund +50（reason='會員退費 ABC'）
**預期：**
- 餘額 = 150
- ledger 多一筆 `type='refund', change=50, balance_after=150, reason='會員退費 ABC', source_type=…, source_id=…, operator_id=…`
- `wallet_balances.version` +1、`last_movement_at` 更新

### 2.2 rpc_wallet_refund — 金額 ≤ 0 拒絕
- [ ] `p_amount = 0` → RAISE
- [ ] `p_amount = -10` → RAISE
- [ ] balance / ledger 都不動

### 2.3 rpc_wallet_refund — reason 必填
- [ ] `p_reason = NULL` → RAISE `reason required (>=4 chars)`
- [ ] `p_reason = ''` → RAISE
- [ ] `p_reason = '12'`（< 4 chars）→ RAISE
- [ ] `p_reason = '   abc   '`（trim 後 3 chars）→ RAISE
- [ ] `p_reason = 'abcd'` → 通過

### 2.4 rpc_wallet_adjust — happy path（補償 +）
**情境：** 餘額 100、role='owner'、`p_change = 30, p_reason = '客訴補償 #1234'`
**預期：**
- 餘額 = 130
- ledger 多一筆 `type='adjust', change=30, balance_after=130`
- **`member_audit_log` 多一筆** `entity_type='wallet', action='adjust', before_value={"balance":100}, after_value={"balance":130}, reason='客訴補償 #1234', operator_id=…`

### 2.5 rpc_wallet_adjust — happy path（修正 −）
**情境：** 餘額 100、`p_change = -30, p_reason = '誤入帳修正'`
**預期：** 餘額 = 70；ledger `change=-30, balance_after=70`；audit log 寫入

### 2.6 rpc_wallet_adjust — 0 拒絕
- [ ] `p_change = 0` → RAISE（CHECK 也擋，但 RPC 應提早報錯）

### 2.7 rpc_wallet_adjust — 餘額 < 0 拒絕
**情境：** 餘額 50，`p_change = -100`
**預期：** RAISE（CHECK 攔；錯誤訊息應友善）；balance / ledger / audit log 都不動

### 2.8 rpc_wallet_adjust — role gate（對齊 `apps/admin/src/lib/role.ts` BRANCH_ROLES）
| JWT role | 預期 |
|---|---|
| `''`（admin role NULL → empty） | 過 |
| `owner` | 過 |
| `admin` | 過 |
| `hq_manager` | 過 |
| `hq_accountant` | 過 |
| `store_manager` | 過 |
| `assistant` | RAISE `permission denied for wallet adjust` |
| `store_staff` | RAISE |
| 無 role claim | 過（NULL → empty） |

- [ ] 至少測 3 種：HQ admin (空字串)、store_manager、store_staff（拒絕）

### 2.9 rpc_wallet_adjust — reason 必填（同 2.3 規則）
- [ ] NULL / '' / 短於 4 chars 都 RAISE

### 2.10 rpc_wallet_reverse — happy path
**前置：** 先用 `rpc_wallet_topup` 加 100（產生 ledger row L1，type='topup'）
**操作：** `rpc_wallet_reverse(tenant, L1, '誤刷取消', operator)`
**預期：**
- 餘額 = 0
- ledger 多一筆 L2 `type='reversal', change=-100, balance_after=0, reverses=L1, reason='誤刷取消'`
- L1 **不被更新**（append-only）
- 反查「L1 是否已被反向」：`EXISTS (SELECT 1 FROM wallet_ledger WHERE reverses=L1)` → true

### 2.11 rpc_wallet_reverse — 反向 spend
**前置：** 餘額 100，`rpc_wallet_spend(50, ...)` → L1 type='spend', change=-50, balance_after=50
**操作：** reverse(L1)
**預期：** 餘額回到 100；L2 `type='reversal', change=+50, balance_after=100, reverses=L1`

### 2.12 rpc_wallet_reverse — 拒絕反向 reversal
**前置：** 已有 reversal row L2
**操作：** `rpc_wallet_reverse(L2, ...)`
**預期：** RAISE `cannot reverse a reversal`

### 2.13 rpc_wallet_reverse — 拒絕重複反向
**前置：** L1 已被 L2 反向
**操作：** `rpc_wallet_reverse(L1, ...)`（再一次）
**預期：** RAISE `ledger already reversed`

### 2.14 rpc_wallet_reverse — 反向後餘額會變負則拒絕
**情境：** topup 100（L1）→ spend 80 → 餘額 20 → reverse(L1)
**預期：** RAISE（會讓餘額 = -80，CHECK 擋）；L1 仍未被反向

### 2.15 rpc_wallet_reverse — reason 必填
- [ ] NULL / '' / 短於 4 chars → RAISE

### 2.16 並發鎖定
**情境：** 兩個 session 同時對同會員 topup + adjust
**預期：** `FOR UPDATE on wallet_balances` 序列化；兩筆 ledger 都成功，最終餘額 = 起始 + 兩筆 change 總和；`balance_after` 各自正確

### 2.17 Member status guard
- [ ] member.status='merged' → 三支 RPC 全 RAISE
- [ ] member.status='deleted' → 三支 RPC 全 RAISE
- [ ] member.status='active' → 通過

### 2.18 Append-only invariants
- [ ] 直接 `UPDATE wallet_ledger SET reason='x'` → trigger 擋
- [ ] 直接 `DELETE FROM wallet_ledger` → trigger 擋
- [ ] 認證 user 直接 `INSERT INTO wallet_ledger` → 失敗（無 INSERT policy；只能走 SECURITY DEFINER RPC）

### 2.19 fn_check_wallet_consistency
**前置：** 跑完上面所有測試
**預期：** `SELECT * FROM fn_check_wallet_consistency()` 回傳 0 rows（所有 member 的 ledger 累加 = balance）

---

## 3. UI 行為（preview 互動）

### 3.1 MemberDetail wallet tab — 入口
**路徑：** `/members` → 點任一會員 → 切到「儲值流水」tab
- [ ] tab 切換無 console error
- [ ] 既有餘額顯示卡片仍在
- [ ] tab 表頭上方多 4 顆按鈕：`[+ 加值] [− 扣款] [↺ 退款] [⚙ 調整]`
- [ ] 表格每筆 row 在最後一欄看到「↩ 反向」icon（type=topup/spend/refund/adjust 且未被反向時）
- [ ] reversal row 本身**沒有**反向 icon

### 3.2 加值 modal
- [ ] 點「+ 加值」開 modal
- [ ] 欄位：金額（必填、>0）、付款方式 select（cash/credit_card/transfer）、原因（選填）
- [ ] 送出後 modal 關閉、wallet tab 餘額 + ledger 自動 reload（reloadTick）
- [ ] 餘額更新到正確值
- [ ] 新 ledger row 出現在最頂端、type='topup'、payment_method 對

### 3.3 扣款 modal
- [ ] 點「− 扣款」開 modal
- [ ] 欄位：金額（必填、>0）、原因（選填）
- [ ] 送出後 reload，type='spend'
- [ ] **餘額不足**：輸入 > 現有餘額 → alert 中文錯誤訊息（translateRpcError）

### 3.4 退款 modal
- [ ] 欄位：金額（必填、>0）、原因（必填、≥4 字）
- [ ] 原因留空 → 前端 `required` 阻擋送出
- [ ] 送出後 reload，type='refund'

### 3.5 調整 modal
- [ ] 欄位：變動金額（必填、不為 0、可正可負）、原因（必填、≥4 字）
- [ ] 送出後 reload，type='adjust'；balance_after 對
- [ ] **role gate (UI)**：assistant / store_staff 帳號登入 → 「⚙ 調整」按鈕**不顯示**
- [ ] HQ admin (role='') / owner / store_manager 登入 → 顯示
- [ ] store_staff 用 dev tool 強制送 RPC → 後端 RAISE，alert 顯示

### 3.6 反向 icon
- [ ] 點 row 的「↩ 反向」→ 開 modal、預填要反向的 ledger 摘要
- [ ] 欄位：原因（必填、≥4 字）
- [ ] 送出後 reload；新 reversal row 出現在最上；原 row 在表中不變（reverses 反查讓它失去 icon）
- [ ] 重複點同一 row 反向 → RPC RAISE → alert

### 3.7 reload pattern
- [ ] 任何成功操作後，`reloadTick` 觸發 useEffect 重撈、餘額卡片 + ledger 都更新

### 3.8 錯誤翻譯
- [ ] RPC 各種 RAISE 訊息（reason required / Insufficient wallet / cannot reverse / permission denied）都經 `translateRpcError` 轉成中文 alert（若 dictionary 未涵蓋，至少不 crash）

### 3.9 Modal 樣式
- [ ] 樣式視覺上對齊 `MemberMergeModal` 風格
- [ ] dark mode 顯示正常
- [ ] 送出按鈕在 loading 狀態 disabled

---

## 4. Regression

- [ ] 既有 wallet read-only 顯示沒壞（餘額 + 50 筆 ledger）
- [ ] 既有「積分流水」tab 與「測試操作」tab 完全沒動
- [ ] 既有 `rpc_wallet_topup` 行為不變（沒被新 migration 重 define）
- [ ] 既有 `rpc_wallet_spend` 行為不變
- [ ] member 合併 (`rpc_merge_guest_member`) 仍能搬走 wallet
- [ ] 訂單流程完全沒受影響（Phase A 不碰訂單）
- [ ] LIFF 顧客端任何頁不受影響
- [ ] admin app build + type-check 過

---

## 5. 驗收門檻

§1-§4 全勾、**無 console error**、**Supabase dev push 成功**、**`fn_check_wallet_consistency()` 回 0 rows**、**`pnpm build` 過** 才能標 done。

PR merge 後依使用者偏好同步 GitHub Issues + Wiki（會員模組頁）。
