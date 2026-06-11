# dispatch-price-guard Test Run — 2026-06-11

**執行環境：** 拋棄式 `supabase/postgres:17.6.1.134` 容器 + 依賴切片
（product/member/inventory/purchase/sales/stores_order/inventory_v02/picking_waves/virtual_product
+ 20260514000000 prices scope 擴充 + 本次 `20260705000000_dispatch_price_guard.sql`），
auth.uid()/auth.jwt() 以 stub 提供。測試腳本：`scripts/test-dispatch-price-guard.sql`（自帶 fixture、結尾 ROLLBACK）。
> 為何不用 `supabase db reset` 全鏈：本機重放在 `20260508120000` 斷（timestamp 亂序引用
> `rpc_transfer_order_partial` 8 參數版，該簽名 20260509000005 才建立）、`20260629000020` 亦有問題 —
> 既有問題與本次無關，prod 不受影響（prod 按部署順序）。

### Summary
- Total: 29 items（§1×5、§2×11、§3×7、§4×6）
- Passed: 16
- Failed: 0
- Blocked: 13（sandbox 無法跑 admin 登入 UI、prod token 缺、月結/restock 需完整鏈）

### SQL 直測結果（18/18 PASS）

```
PASS 1.2  rpc_outbound 單一 overload、10 參數            | 10
PASS 1.3  三支出倉 RPC prosrc 含 _missing_dispatch_prices
PASS 2.1h 無價 SKU → 缺兩種        | TG-NP …【缺成本價、缺分店價】
PASS 2.2h 只有成本 → 只缺分店價    | TG-CO …【缺分店價】
PASS 2.3h 價格=0 視同缺
PASS 2.4h 兩價齊全 → NULL
PASS 2.9h 虛擬 SKU 跳過 → NULL
PASS 2.11h 一次列出全部缺價 SKU    | TG-CO…【缺分店價】；TG-NP…【缺成本價、缺分店價】
PASS 2.1  wave 缺價擋下＋中文訊息  | 無法派貨：…→ TG-NP 守衛測試商品（無價）【缺成本價、缺分店價】
PASS 2.1b 擋下後 wave 仍 picked、無 transfer | picked / transfers=0
PASS 2.4  補價後派貨成功、wave shipped | {"wave_id":1,"item_count":3,"store_count":1,"transfer_ids":[1]}
PASS 2.5  avg=0 出庫用現行成本價   | np=45.0000 ok=50.0000
PASS 2.5b avg>0 出庫仍用 avg_cost  | avg=7.0000
PASS 2.8  batch：hq_to_store 缺價進 failed | failed=[{id:2, reason:"無法派貨：…【缺分店價】"}], succeeded=[3,4]
PASS 2.8b 被擋 transfer 維持 draft、庫存未動
PASS 2.8c 店↔店缺價不檢查、照常 shipped
PASS 2.9  hq_to_store 虛擬 SKU 不擋、out_movement_id NULL
PASS 2.10 9 參數具名呼叫照常 resolve（無 function-is-not-unique）
```

### 對應測試文件逐項

| 項 | 結果 | 證據 / 備註 |
|---|---|---|
| §1.1 helper 存在 | ✅ | 直接呼叫成功（上表 2.xh 全組） |
| §1.2 outbound 9→10、單一 overload | ✅ | pg_proc：1 列、pronargs=10 |
| §1.2 GRANT | ✅* | 改前改後皆無顯式 GRANT（沿用 Supabase default ACL），posture 不變 |
| §1.3 三支 prosrc 含守衛 + 既有行為保留 | ✅ | prosrc 檢查 + 2.4 全流程過（picked_qty 修補/audit/張數核對都在路徑上） |
| §2.1/2.2/2.3/2.4/2.5/2.8/2.9/2.10/2.11 | ✅ | 上表 |
| §2.6 月結 end-to-end | ⏸ Blocked | 月結函式未動；計費輸入＝出庫 movement.unit_cost 已驗（45/50/7）。prod 部署後建議抽一張實單對帳 |
| §2.7 rpc_ship_restock_pr_received | ⏸ Blocked | 需 JWT context＋restock 完整鏈；守衛段與 wave 版逐字相同、prosrc 已確認含守衛 |
| §3 UI（7 項） | ⏸ Blocked | sandbox 連不到本機 Supabase、admin 登入跑不完（既有限制）；build/type-check 綠、碼審過 → 留使用者 preview 自審 |
| §4 hq/inbox 批次派貨 | ✅(RPC 層) | 2.8 failed[]/succeeded 語意即 inbox 批次的後端行為；UI 呈現留自審 |
| §4 自由轉貨店↔店 | ✅ | 2.8c |
| §4 退貨/取貨 leg | ⏸ Blocked | 未实跑；resolution 層已證（2.10），無 9 參數歧義 |
| §4 e2e seed 缺 cost/branch | ✅ 已修 | `scripts/e2e/01-master.sql` 補 cost=retail×0.6 / branch=retail×0.8 |
| §4 /wms/picking 原功能 | ⏸ Blocked | build 綠＋碼審（改動皆為附加 UI，不動原矩陣/FIFO 邏輯）；留自審 |

### Gate status
- Build（next build 含 type-check）: ✅
- Migration 套用: ✅ 本機乾淨 DB；❌ prod 未部署（`SUPABASE_ACCESS_TOKEN` 不在環境，Management API 走不了）
- Console errors during UI run: 未執行（sandbox 限制）

### Verdict
**NOT DONE** — 程式碼層全綠（SQL 18/18、build 綠），剩三件待辦：
1. prod 部署（待 token；指令見 PR 描述）
2. prod 缺價覆蓋率探測 + 必要時批次補價（部署前必做，避免上線當下全倉被擋）
3. /wms/picking 缺價 pill＋補價 UI 使用者自審

### Suggested test doc updates
- §2.10 可加註：「resolution 層以 9 具名參數直呼驗證即可，全流程回歸交給各功能自身測試」
