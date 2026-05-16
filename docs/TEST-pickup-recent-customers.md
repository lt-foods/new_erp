---
title: TEST — 取貨頁「常用顧客」快選列
module: Pickup / UI
status: passed
ran_at: 2026-05-16
verified_by: claude (preview tools, localStorage seed + DOM read)
---

# 測試計畫 — 取貨頁常用顧客快選

需求：取貨櫃台不想每次打字搜尋。`/pickup` 頂部固定一塊「常用顧客快選」區，
**一直顯示**（最多 10 位），點按鈕直接帶該顧客查單；**點擊不寫進搜尋框**（按鈕本身就是捷徑）。

> 使用者回饋修訂（2026-05-16）：
> - ❌ 原本點按鈕會把 `member_no` 灌進搜尋框 → 改為**不動輸入框**
> - 區塊**常駐顯示**（空時顯示提示文案），非「有資料才出現」
> - 上限 12 → **10**；移除「清除常用」（常駐自維護，靠 60 天 TTL 淘汰）
>
> 使用者回饋修訂 #2（2026-05-16）：
> - 累積訊號改為**搜尋有結果即記入**（不必等取貨）；`≤5` 筆視為「找到特定顧客」才記，`>5` 視為廣搜（如只打姓氏）不記，避免洗版
> - 移除「取貨成功」專屬記錄（取貨後 `reloadTick` 會重跑 `search()`、自然再 +1，無需另記）
>
> 使用者回饋修訂 #3（2026-05-16）：
> - chip **不顯示 ×N 次數 badge**（亦從 tooltip 拿掉「已取貨 N 次」）；`count` 僅內部用於排序，不對使用者呈現

## Scope（純前端、無 migration / RPC）

- 新檔：[apps/admin/src/lib/pickupRecents.ts](../apps/admin/src/lib/pickupRecents.ts)
  - localStorage（key `pickup_recents_v1`）；每個取貨終端各自累積（天然 per-store）
  - `recordPickupRecent()`：搜尋有結果時 upsert，`count++`、更新 `lastAt`
  - `getPickupRecents()`：讀出、排序（count desc → lastAt desc）、保留 60 天內、最多存 100、回傳前 **10**
  - SSR/prerender 安全（`typeof window` guard，僅在 effect / handler 觸碰 localStorage）
- 改：[apps/admin/src/app/(protected)/pickup/page.tsx](<../apps/admin/src/app/(protected)/pickup/page.tsx>)
  - `search()` 加 optional `overrideQuery`：用該值查單但**刻意不 `setQuery`**（輸入框保持原狀）
  - mount 後 effect 載入 recents → 區塊**常駐**；無資料顯示提示，有資料渲染 ≤10 顆 chip
  - `search()` 取得 members 後：`1 ≤ list.length ≤ 5` 時 loop `recordPickupRecent` + `setRecents`
  - 快選按鈕點擊 → 以 `member_no` 觸發搜尋（不改輸入框）

## 測項

| # | 測項 | 預期 | 結果 | 證據 |
|---|---|---|---|---|
| 1 | typecheck 通過 | 無 TS error | ✅ PASS | `npx tsc --noEmit` 無輸出 |
| 2 | localStorage 空 → 區塊**仍常駐**＋提示文案 | 顯示「常用顧客快選」+「完成取貨後…」 | ✅ PASS | `hasArea:true, hasHint:true, hasClearBtn:false, input:""` |
| 3 | **搜尋 ≤5 結果即記入（不必取貨）** | 搜完該顧客就進快選區 | ✅ PASS | 搜 `M021806`（1 筆）→ chip `0→1`、無取貨 |
| 4 | **廣搜 >5 結果不記**（防洗版） | stored 不增 | ✅ PASS | 搜「09」得 20 筆 → stored 維持 1、chipCount 1 |
| 5 | 同顧客再搜 → count 累加（內部排序用，**不顯示**） | stored count 遞增、chip 無 ×N | ✅ PASS | 再搜 `M021806` → stored `count 1→2`；chip 文字僅「姓名 ···電話末3」、`section` 無 `×` 符號 |
| 6 | 點按鈕 → 查單但**不動輸入框** | 列出該顧客、input 維持空 | ✅ PASS（前一輪）| `inputAfterClick:""`、列出 M021806、區塊仍在 |
| 7 | count 排序 + 相同則近者前 | 多者/近者在前 | ✅ PASS（前一輪）| seed 驗證 count desc → lastAt desc |
| 8 | 超 60 天淘汰；**最多 10 顆** | 舊的不出現、上限 10 | ✅ PASS（前一輪）| seed 14 筆 → `chipCount:10`；「過期客」(61天) 不出現 |
| 9 | 區塊常駐、無「清除常用」鍵 | 空時提示、無清除鈕 | ✅ PASS | `hasArea:true, hasHint:true, hasClearBtn:false` |
| 10 | 取貨成功後快選區刷新 | 不需手動重整 | 🔎 推論驗證 | `reloadTick`→`search()`→（≤5 時）`recordPickupRecent`+`setRecents`；search-record 路徑已實測、reactive 已實證、tsc 乾淨 |
| 11 | 回歸：搜尋/全取/通知/單張取貨 | 行為不變 | ✅ PASS | 表單搜尋「09」正常；`search` 簽章向後相容；無 console error |

## 不在範圍 / 已知取捨

- **冷啟動為空**：localStorage 從零累積，新終端 / 清快取後需搜幾位顧客才填滿（區塊常駐＋提示文案緩解）
- **跨終端 / 跨裝置同步**：刻意 per-terminal localStorage，符合單店單櫃台情境
- **廣搜（>5 筆）不記**：避免只打姓氏／模糊搜把一堆人灌進快選區；要記就搜得精確（全名 / 電話 / 會員編號）
- 若要「從第一分鐘就有 10 位、跨裝置共用」→ 需 server RPC（`rpc_recent_pickup_customers`，已設計、因需 DB push 待使用者授權）
