# 總倉退回貨處理 — D 測試載入器小修審查

日期：2026-09-07

角色：Codex 側 GPT-5.5 阿審（獨立 review）
範圍：只審本輪作者修改 `tests/return-disposition/fixture.cjs`、`tests/return-disposition/README.md`。未修改功能碼、SQL、既有測試或其他報告；未連 GitHub / Supabase；未讀 env / 密鑰；未安裝套件；未重跑會建立資料庫的 fixture loader。

## 實際檢查

已讀：

- `tests/return-disposition/fixture.cjs`
- `tests/return-disposition/README.md`
- `supabase/migrations/20260707000020_trial_expiry_enforcement.sql`
- `supabase/migrations/20260515000002_rpc_store_self_service.sql`
- `supabase/migrations/20260612000030_v_picking_demand_no_po.sql`
- `supabase/migrations/20260612000040_approve_restock_via_picking_workstation.sql`
- `supabase/migrations/20260907010000_hq_return_disposition_core.sql`
- `supabase/migrations/20260907020000_hq_return_disposition_sources.sql`

已執行：

```powershell
node --check tests/return-disposition/fixture.cjs
```

結果：exit 0。

```powershell
git diff --check -- tests/return-disposition/fixture.cjs tests/return-disposition/README.md
```

結果：exit 0；只有 Git 對 LF/CRLF 的提醒，沒有 whitespace error。

```powershell
node -e 'const {Client}=require("pg"); const c=new Client({host:"127.0.0.1",port:56427,user:"returnlocal",database:"return_disposition_test_d3"}); const q="SELECT to_regprocedure(''public._current_tenant_id()'') IS NOT NULL AS tenanthelper, to_regprocedure(''public._next_transfer_no()'') IS NOT NULL AS transferhelper, to_regprocedure(''public.trim_scale(numeric)'') IS NULL AS no_trim_scale, EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = ''public'' AND p.proname = ''rpc_mark_orders_shipping_for_wave'' AND pg_get_functiondef(p.oid) LIKE ''%RAISE EXCEPTION%'') AS shippingstub_raise"; c.connect().then(()=>c.query(q)).then(r=>{console.log(JSON.stringify(r.rows[0]));}).finally(()=>c.end()).catch(e=>{console.error(e.message); process.exit(1);});'
```

結果：exit 0。

```json
{"tenanthelper":true,"transferhelper":true,"no_trim_scale":true,"shippingstub_raise":true}
```

另有一次 `psql` 查詢嘗試失敗，原因是本機 PATH 找不到 `psql`，未查到 DB、未改資料。

## 核對結果

- `_current_tenant_id`：loader 從 `20260707000020_trial_expiry_enforcement.sql` 載入，該檔是真正加上 `tenants.status` 守門的版本；全 migrations 搜到後續沒有再重建 `_current_tenant_id`。
- `_next_transfer_no`：loader 從 `20260515000002_rpc_store_self_service.sql` 載入，該檔定義 `TR{YYMMDD}{seq4}`；全 migrations 搜到後續沒有再重建 `_next_transfer_no`。
- `trim_scale`：本輪已從 fake helper 刪除；只讀假 DB 查到 `public.trim_scale(numeric)` 不存在，符合「不要用假 trim_scale 掩蓋缺依賴」。
- `rpc_mark_orders_shipping_for_wave`：本輪從 no-op 改成 RAISE；只讀假 DB 查到 stub 內含 `RAISE EXCEPTION`，符合 fail-closed。
- `--with-all`：程式碼採明確檔名載入 A/B/C/F，不掃 pattern；本工地目前只有 A、B，C/F 未交件不算 D 自身缺陷。

## P0

無。

## P1

無。

## P2

### P2-1：`--with-all` 的 `v_picking_demand_no_po` 前置不是最新版，文件要講清楚這是輕量載入限制

證據：

- `fixture.cjs:827` 載入 `20260612000030_v_picking_demand_no_po.sql`。
- 全 migrations 搜到 `20260612000040_approve_restock_via_picking_workstation.sql:53` 後續又 `CREATE OR REPLACE VIEW public.v_picking_demand_no_po AS`。

影響：目前 CEO 已驗 `--with-all` 可套前置 030/A/B，到 C 缺檔才停，這對「缺檔即 fail」是有用的；但不能把它說成完整 ERP 最新狀態。若 F 未來依賴 040 收緊後的 view 語意，這個 loader 會偏離正式系統。

建議：README 明寫 `--with-all` 目前只載 F 所需的輕量前置，不代表完整 ERP 最新 view；若 F 測試需要派貨工作台最新語意，再改載 040 或補明確對拍。

### P2-2：README / 程式註解仍殘留「真實輕量（trim_scale 等）」說法

證據：

- `fixture.cjs:399` 註解仍寫 `🔧 真實輕量（trim_scale 等）`。
- README 載入流程仍寫 helper stubs 分成「通知類 no-op / 庫存類 RAISE / 真實輕量」，但本輪已刻意刪掉 fake `trim_scale`。

影響：不影響 loader 執行；但下一個人可能誤以為 `trim_scale` 已由 fixture 提供，進而誤判缺依賴。

建議：之後順手把註解改成「sequences / 簡單 stub」，不要再點名 `trim_scale`。

## 限制

- 我沒有重跑 `node tests/return-disposition/fixture.cjs --db-name ...`，因為那會建立新假 DB；本輪只做靜態 review、語法檢查、diff whitespace 檢查，以及對既有 `return_disposition_test_d3` 的只讀查詢。
- 本 loader 是最小測試載入器，不含完整 ERP。C/F 未交件、以及業務 helper 仍 fail-closed，不算 D 小修自己的 P1；若未來宣稱支援某條完整路徑，就要載入該路徑真 helper 或補明確測試。
