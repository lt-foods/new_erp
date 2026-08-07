# TEST — 月結月界改台北時區（received_at 歸屬月份）

來源：Alex（2026-08-07）：「月結單現在用什麼時間點計算？」→ 確認歸屬時間點是
`transfers.received_at`（分店收貨時間）後，發現月界比較是 TIMESTAMPTZ vs DATE，
用 DB session timezone（UTC）切 —— 實際月切點是台北時間每月 1 號**早上 08:00**，
1 號凌晨 00:00–08:00 收的貨會被算進上個月。

20260803000000（每日進貨對帳）日界已用 Asia/Taipei，檔頭當時就註明這個不一致
（全量 7439 筆只有 2 筆落在邊界窗，先不動生成器）——本次就是補上生成器那一支。

Migration：`20260807000000_settlement_taipei_month_boundary.sql`
- `rpc_generate_hq_to_store_settlement` v5（基底 20260801000000 v4）：
  月界改 `v_range_start / v_range_end TIMESTAMPTZ`＝台北時間該月 1 號 00:00 起、
  次月 1 號 00:00 止（半開區間）。A–F 匯總、筆數統計、A–F 明細 insert 共 13 處
  一致替換；其餘（settlement_month 主鍵、人工調整、鎖定跳過、無活動砍 draft）不動。
- `rpc_update_free_transfer_amount` v3（基底 20260715000120 v2）：
  入帳月份判定 `DATE_TRUNC('month', received_at)` →
  `DATE_TRUNC('month', received_at AT TIME ZONE 'Asia/Taipei')`，
  鎖定檢查與改完重算的月份跟生成器 v5 同一套歸屬。

影響範圍：
- 只影響 draft/sent/disputed 重算；confirmed/settled/remitted/cancelled 生成器
  本來就跳過，**歷史鎖定月不會變動**。
- 邊界窗轉倉單（每月 1 號台北 00:00–08:00 收貨）下次按「產生」重算時會移到
  正確月份。既有 draft 在下次重算前維持舊數字。

## 測試項目

### 部署驗證（線上，2026-08-07，Management API 部署 HTTP 201）
- [x] V1 兩支 function 線上定義含 `Asia/Taipei`（pg_get_functiondef，兩支皆 true）。
- [x] V2 邊界窗盤點：全量正好 2 筆（= 20260803000000 檔頭預告的那 2 筆）——
      TR2605190091 / TR2605200092，皆自由轉貨（三峽店/文山店 → 古華店），
      received_at 2026-05-31 17:18 UTC = 台北 6/1 凌晨 01:18，新月界歸 6 月。
      受影響的 2026-05 / 2026-06 結算全為 draft/sent（無鎖定月），
      下次「產生」重算即套用新歸屬。

```sql
-- V1
SELECT p.proname,
       pg_get_functiondef(p.oid) LIKE '%Asia/Taipei%' AS has_taipei_boundary
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('rpc_generate_hq_to_store_settlement',
                     'rpc_update_free_transfer_amount');

-- V2（邊界窗：台北 1 號 00:00–08:00 = UTC 前一日 16:00–月首 00:00）
SELECT t.id, t.transfer_no, t.transfer_type, t.received_at,
       (t.received_at AT TIME ZONE 'Asia/Taipei')::DATE AS taipei_date
  FROM transfers t
 WHERE t.status IN ('received','closed')
   AND EXTRACT(DAY  FROM t.received_at AT TIME ZONE 'Asia/Taipei') = 1
   AND EXTRACT(HOUR FROM t.received_at AT TIME ZONE 'Asia/Taipei') < 8
 ORDER BY t.received_at;
```

### 邏輯驗證（DO block + RAISE rollback，或 preview 環境）
- [ ] T1 邊界單歸屬：造一筆 received_at = 該月 1 號台北 03:00（= UTC 前月末日
      19:00）的 hq_to_store 轉倉單 → 產生後應入**當月**月結（舊版會入前月）。
- [ ] T2 月尾不漏：received_at = 月末日台北 23:59 → 入當月（與舊版相同）。
- [ ] T3 月結 vs 每日對帳一致：跨月邊界日的 `rpc_store_inbound_daily_summary`
      日金額逐日加總 = 該月月結 branch_amount（不含人工調整）。
- [ ] T4 鎖定月不動：confirmed 月份的邊界單重算後不移動（生成器跳過鎖定月）。
- [ ] T5 估價修正歸屬：邊界窗自由轉貨行改估價 → 回傳 `month` 為台北月份、
      重算的也是該月。
