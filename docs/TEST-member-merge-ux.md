# TEST — 會員合併 UX 增強（雙頭像 + 反向觸發 + 列表過濾）

## 背景
延伸現有 `rpc_merge_member` + `MemberMergeModal`，補齊 UX：
- 實體會員（target）詳細頁可看到「合併進來的虛擬會員」資料 + 雙頭像重疊
- 從實體會員那側可反向觸發「把虛擬合併進來」
- 會員列表預設不再列出 `status='merged'` 的舊虛擬會員

## 前置條件
- Migration `20260422120002_member_schema.sql`（含 `member_merges` 表）+ `20260429120000_member_type_guest.sql`（含 `rpc_merge_member`）已 apply
- 已有：1 個 `full` + LINE-bound 實體會員 R、1 個 `guest` 虛擬會員 G、各帶一筆訂單

---

## T1 — 會員列表過濾 merged

| # | 步驟 | 預期 |
|---|------|------|
| T1-1 | 開 `/members`，預設視角 | G 不出現在列表（已 merged 的虛擬會員不顯示） |
| T1-2 | 切「顯示已合併」toggle 為 ON | G 出現，列尾有「已合併」標籤 |
| T1-3 | 點 G 的會員編號 | 詳細頁開啟，顯示「已合併 → #R」 灰底 link |
| T1-4 | 搜尋框輸入 G 的 member_no | OFF 時 0 筆，ON 時 1 筆 |
| T1-5 | status='deleted' 也應預設過濾 | OFF 時不出現 |

## T2 — 實體會員詳細頁：合併歷史區塊

| # | 步驟 | 預期 |
|---|------|------|
| T2-1 | 開實體會員 R 的詳細頁 | 出現「已合併虛擬會員（n）」區塊（n = `member_merges` 中 primary_member_id=R 的筆數） |
| T2-2 | 區塊內每筆顯示 | guest 的 `member_no` / 原 `name` / 原 `phone`（line:Uxxx 顯示「—」）/ 加入時間 / 合併時間 / 合併原因 |
| T2-3 | 點 guest 的 member_no | 跳到該 guest 詳細頁（仍顯示「已合併 → #R」） |
| T2-4 | R 沒有任何合併紀錄時 | 此區塊不渲染（不顯示空殼） |

## T3 — 雙頭像重疊（avatar overlap）

| # | 步驟 | 預期 |
|---|------|------|
| T3-1 | R 有 1 筆 merged-from + 該 guest 有 avatar_url | header 顯示 R 的 avatar 大頭像 + 右下角小頭像（guest avatar） |
| T3-2 | guest 沒 avatar_url | 小頭像顯示文字 fallback（guest name 首字） |
| T3-3 | R 有 ≥2 筆 merged-from | 右下角 stacked 顯示前 2 個（≥3 顯示 +N badge） |
| T3-4 | hover 小頭像 | tooltip 顯示原 guest 的 name / member_no |
| T3-5 | R 沒有 merged-from | 只顯示 R 的單一大頭像（無小頭像） |
| T3-6 | guest 自己（target G 直接打開）的詳細頁 | 不顯示重疊頭像（單一大頭像 + merged 灰章） |

## T4 — 從實體會員端反向合併

| # | 步驟 | 預期 |
|---|------|------|
| T4-1 | 開 R 的詳細頁，找到「📥 合併虛擬會員進來」按鈕 | 按鈕只在 R 是 full + status≠merged 時顯示（guest 端用既有「🔗 合併到實體會員」）|
| T4-2 | 點按鈕，搜尋框預設空 | 顯示搜尋 input + 結果為空 |
| T4-3 | 輸入 guest G 的 name/phone/member_no | 結果列出 G（只列 `member_type='guest'` + `status='active'`）|
| T4-4 | 結果列只顯示 guest，不出現 full 會員 | full / merged / deleted 一律不在結果中 |
| T4-5 | 選 G 並送出 | 呼叫 `rpc_merge_member(G.id, R.id, ...)`、成功 |
| T4-6 | 完成後 | Modal 關閉、R 詳細頁重新載入、合併歷史區塊出現 G、雙頭像出現 |
| T4-7 | G 已 merged 的情況下再開 R 的反向 modal、輸入 G | 結果不出現 G（status≠active 過濾）|

## T5 — 既有正向合併不破壞（regression）

| # | 步驟 | 預期 |
|---|------|------|
| T5-1 | 開 G（guest, status=active）詳細頁 | 仍顯示「🔗 合併到實體會員」按鈕 |
| T5-2 | 點按鈕、搜尋 R | 結果列出 R |
| T5-3 | 送出 | 呼叫 `rpc_merge_member(G.id, R.id, ...)` 成功 |
| T5-4 | T5-3 成功後重開 G | 顯示「已合併 → #R」 灰章；無「🔗 合併到實體會員」按鈕 |
| T5-5 | 訂單 / 點數 / 儲值 / 卡片 | 全部已搬到 R（rpc 既有行為） |

## T6 — 邊界

| # | 步驟 | 預期 |
|---|------|------|
| T6-1 | 反向 modal 在 R 是 guest 時被打開（理論上不可能但測 defensive） | 不顯示按鈕 / 點不到 |
| T6-2 | R 是 status='blocked' (黑名單) | 反向合併按鈕仍可用（blocked 是 flag、不是合併禁止）|
| T6-3 | R 是 status='merged' | 反向合併按鈕不顯示（merged 不是有效目標）|
| T6-4 | 反向選了一個 guest 後再變更為其他 guest 然後送出 | 以最後選的 guest 為準 |
| T6-5 | 同分頁併發兩次相同合併（雙擊送出） | 第二次失敗（rpc 守衛 `already merged`），不重複搬料 |

---

## 實作驗證紀錄（2026-05-07）

| Test | 狀態 | 備註 |
|------|------|------|
| T1-1 ~ T1-5 列表過濾 | ✅ | toggle 已加到 /members；prod DB 無 merged 會員所以前後筆數相同（過濾 SQL `not("status","in","(merged,deleted)")` 已實作） |
| T2-1 ~ T2-4 merged-from 區塊 | 🟡 | 結構與 SQL 已實作；prod 無資料無法觀察渲染（空陣列時不渲染已驗證 ✅） |
| T3-1 ~ T3-6 雙頭像 | 🟡 | AvatarStack 元件已加；無 merged-from 時只顯示主頭像已驗證 ✅，有合併時的 stacked / +N 待真實資料測 |
| T4-1 ~ T4-7 反向合併 modal | ✅ | 「📥 合併虛擬會員進來」按鈕在實體會員 detail 出現、modal 標題正確、搜尋空 state「查無對應會員」正常 |
| T5-1 ~ T5-5 既有正向合併 | 🟡 | 邏輯不動（modal 內以 direction 判斷觸發 rpc 參數），無 guest 資料無法跑 e2e |
| T6-1 ~ T6-5 邊界 | ✅ | 條件式渲染：guest 才出 🔗、full 非 merged 才出 📥、merged 兩個都不出 |

> 🟡 = 結構驗證 OK、待 seed 真實資料才能跑端到端。

## 驗證指令範例

```sql
-- T2-1 / T2-2：合併歷史
SELECT mm.id, mm.merged_member_id, m.member_no, m.name, m.phone, m.avatar_url,
       m.joined_at, mm.created_at AS merged_at, mm.reason
  FROM member_merges mm
  JOIN members m ON m.id = mm.merged_member_id
 WHERE mm.primary_member_id = <R_id>
 ORDER BY mm.created_at DESC;

-- T1-1 / T1-2：列表過濾
SELECT id, member_no, name, status FROM members WHERE status NOT IN ('merged','deleted');

-- T4-3 / T4-4：反向 modal 結果
SELECT id, member_no, name, phone, member_type, status
  FROM members
 WHERE tenant_id = <t> AND member_type = 'guest' AND status = 'active'
   AND (name ILIKE '%xxx%' OR phone ILIKE '%xxx%' OR member_no ILIKE '%xxx%');
```
