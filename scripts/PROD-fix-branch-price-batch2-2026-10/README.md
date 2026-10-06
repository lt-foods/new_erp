# PROD-fix：第二批分店價錯價修正（九月＋十月，2026-10）

> **狀態：⛔ 這個資料夾是「留紀錄」。** 要不要執行、什麼時候執行，由老闆決定，並由老闆本人貼進 Supabase SQL Editor。沒有任何自動流程會跑這些檔。
>
> 🔴 刻意**不放在 `supabase/migrations/`**（那裡的檔會被當成結構變更套用）。照 `scripts/PROD-fix-*` 的既有慣例放一次性的正式庫資料修正。
>
> 做法完全沿用第一批 `scripts/PROD-fix-sep-branch-price-2026-09/`（2026-09-30 已在正式庫執行成功），只換商品清單、加上十月檢查。

## 做什麼、為什麼

- 又有一批商品的「分店價」打錯：共 94 個規格，正確價以老闆的 Excel 為準。
- 九月月結和店家每日對帳都是照「派車那一刻」查到的分店價算錢，所以九月草稿月結與十月已派出的貨都跟著算錯。
- 修正放在同一個交易裡：
  1. A 類 93 個規格：從 2026-09-01 00:00（台北）起改成正確價，用系統改價函式 `rpc_upsert_price`。
  2. B 類 1 個規格（10/05 才建立的版本）：刪掉那個版本（原樣留在備份），用改價函式從**同一個開始時間**重開正確價。
  3. 重新產生 2026 年 9 月的月結草稿。
- **十月不產生月結**（月份還沒結束）；十月靠價目表改對，月底產生時就是正確價。執行前只要已經有任何一張十月月結，修正檔會整筆停下。
- 八月的帳不受影響：修正檔逐筆比對八月每一筆帳，有任何一筆變了就整筆取消。

## 檔案與順序

| 順序 | 檔 | 會不會寫入 | 說明 |
|---|---|---|---|
| 0-D | `0D_precheck_readonly.sql` | 只查不改 | 核對正式庫關鍵程式、清單 94 個規格、B 類、十月月結、九月月結基準；列出操作人帳號 |
| 0-A | `0A_preview_readonly.sql` | 只查不改 | 每家店：九月草稿、照錯價重算、照正確價重算；拆出改價造成的差與其他異動造成的差；十月改價造成的差 |
| 0-B | `0B_adjustments_readonly.sql` | 只查不改 | 九月有效人工調整逐筆列出（預設一筆都不作廢） |
| 0-C | `0C_august_baseline_readonly.sql` | 只查不改 | 八月逐筆基準（改前先存） |
| 0-E | `0E_other_changes_readonly.sql` | 只查不改 | 九月草稿上次產生後的其他異動拆解 |
| 0-F | `0F_other_changes_by_date_readonly.sql` | 只查不改 | 0-E 按日期拆開 |
| 1 | `1_backup_WRITES_backup_schema_only.sql` | **只新增備份** | 在網站讀不到的專用位置（schema `ops_price_fix_b2`，不碰第一批的 `ops_sep_price_fix`）存備份 |
| 1-B | `1B_backup_permission_check_readonly.sql` | 只查不改 | 備份後馬上跑，確認網站帳號讀不到備份；查不到 API 開放清單時要到 Supabase 畫面人工確認 |
| 2 | `2_fix_WRITES.sql` | **✅ 會寫入** | 改價＋重產九月月結，同一交易；先鎖再查，任何一項不過就整筆取消 |
| 3 | `3_verify_readonly.sql` | 只查不改 | 事後驗算（九月、十月、八月、B 類） |
| 4 | `4_restore_WRITES.sql` | **✅ 會寫入** | 只還原這一批；修正後有任何新異動就停下改人工對帳 |

建議順序：0-D → 0-A、0-B、0-C（老闆看完說「走」）→ 1 → 1-B → 2 → **馬上** 3，3 全部通過才恢復派車收貨。

## 需要老闆親自做的事

- **2 修正**：檔案最上面的操作人 UUID 要填老闆本人（0-D 列出）；本資料夾的版本刻意留空，空的會直接停。
- **貼的時機**：2 和 4 會短暫鎖住月結、價格、派車相關的表，拿不到鎖就立刻放棄。請在沒人操作後台、倉庫沒在派車收貨退貨時貼。

## 還原

- 貼 `4_restore_WRITES.sql`：先確認修正之後沒人動過這些資料（價格、月結、調整、爭議，九月與十月這批商品的派車／收貨／退貨／店轉店）。都沒動過才逐欄換回備份並驗算；只要有一筆被動過就停下、什麼都不改。
- 實務上，**恢復派車之後就不能自動還原**，所以 2 貼完要立刻跑 3。

## 審查紀錄

- 唯讀盤點與修正指令都由 Codex 獨立審查：第 1 輪 P0=0／P1=1（執行前已有十月月結只警告不停）→ 已修成硬停，複審 P0=0／P1=0。
- 清單的佔位規格（`G01846-??`）在 0-D 查明只有一個規格後換成 `G01846-01`（七支同改、只改這一行）。

## 內容一致性（md5）

本資料夾檔案＝本機審查過的版本（原檔名為中文），逐支相同：

| 檔 | md5 |
|---|---|
| 0A_preview_readonly.sql | 65f32620f42a7dc6371c669f5896f72a |
| 0B_adjustments_readonly.sql | a9d66ee497dcefe89ecdd7172b059259 |
| 0C_august_baseline_readonly.sql | aa96fce9361610f2de8aee4732013da6 |
| 0D_precheck_readonly.sql | f2af3390e411f10712f6226d3f03f536 |
| 0E_other_changes_readonly.sql | 98fa492f7fb007afd4863664215257d9 |
| 0F_other_changes_by_date_readonly.sql | 683f1d8e2004443b8f2787f4f8a6763a |
| 1_backup_WRITES_backup_schema_only.sql | fdca78d3fd9dd92e4b23d8aacd228801 |
| 1B_backup_permission_check_readonly.sql | b99e217d149a6d7a2b012c21c68609c0 |
| 2_fix_WRITES.sql | 51a92046c65617b426ea6228b43a37a4 |
| 3_verify_readonly.sql | e87326602d69893324c7dfaea0010589 |
| 4_restore_WRITES.sql | 196f5921b33ad46135ca4cd2f110c608 |

實際執行的 2 修正只多填操作人 UUID 一行，其餘逐字相同。
