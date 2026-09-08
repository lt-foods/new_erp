# 短撿出倉釋放占用量審查（2026-09-08）

## P0

無。

## P1

無。

## P2

無。

## 檢查結果

- `v_picking_demand_by_po`：通過。PO wave 計量三處都改成 `CASE WHEN pw.status = 'shipped' THEN COALESCE(pwi.picked_qty, pwi.qty) ELSE pwi.qty END`，且 `pw.status <> 'cancelled'` 仍保留。
- `rpc_create_wave_from_po`：通過。可派量、借調守衛、補貨 cap 三處 `SUM(pwi.qty)` 口徑都改成 shipped 才用 `picked_qty`，未 shipped 仍用 `qty`。
- 已撿未出倉：通過。公式只有 `pw.status = 'shipped'` 才釋放短撿量，所以 picked 但未 shipped 仍以 `qty` 占用，不會出倉前雙派。
- 影響範圍：通過。差異只新增 `supabase/migrations/20260908000000_release_short_picked_wave_qty.sql` 與 `scripts/verify-short-picked-wave-release.sql`；未改前端、正式庫，migration 只重建相關 view/function。
- 驗證 SQL：通過。用假資料覆蓋「進貨量 > 計畫量 > 實撿量」情境，可抓到舊口徑仍吃計畫量、新口徑釋放未實撿量。

## 已跑指令

- `git -c safe.directory='D:/1人公司/_worktrees/new_erp_shortpick_release_20260908' diff --check`：通過；只有 LF/CRLF 提醒。
- `$env:NODE_PATH='D:/1人公司/new_erp_piaopiao_tong_suppliers_20260902/node_modules'; node scripts/check-sql-syntax.cjs supabase/migrations/20260908000000_release_short_picked_wave_qty.sql scripts/verify-short-picked-wave-release.sql`：通過，2 個 SQL 檔皆可解析。
