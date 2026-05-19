# member-status-tags 測試項目 — 後台會員列表狀態用文字 tag + 移除「編號」欄

**對應 UI 變更:** `apps/admin/src/app/(protected)/members/page.tsx`
**設計演進:** 原 #302 的 LINE icon（SVG）改為文字 tag；🔔 push emoji 改為「通知」tag；列表移除「編號」欄
**判斷依據:** LINE = `members.line_user_id` 非空（與 `MemberDetail.tsx` `hasLine` 一致）；通知 = `rpc_members_with_push`
**無 migration / 無 RPC：** §1、§2 不適用（純前端顯示）

## 0. 資料前置（read-only sanity）

- [ ] 至少 1 筆 `line_user_id` 非空、1 筆為空 → LINE tag 有/無兩態可測
- [ ] 至少 1 筆有 web push 訂閱 → 通知 tag 可測
- [ ] 視需要 1 筆 `status='merged'`、1 筆 `'deleted'` → 驗證標籤搬遷後仍正確

## 3. UI 行為（preview / 碼審）

### 3.1 列表載入
- [ ] `/members` 載入無 console error
- [ ] 表頭欄位為：姓名 / 取貨店 / 手機 / 訂單數 / 未取貨金額 / 儲值 / 加入時間 / 最後登入 / 更新 /（操作）—— **無「編號」欄**
- [ ] 每列 `<Td>` 數 = 表頭欄數 = 10；骨架列 / 空狀態 colSpan = 10（不錯位）

### 3.2 狀態以文字 tag 呈現（非 icon / emoji）
- [ ] 已綁 LINE：姓名旁顯示綠色「LINE」tag；未綁不顯示
- [ ] 已開啟通知：顯示藍色「通知」tag（hover title「已安裝 App 並開啟通知」）；無訂閱不顯示
- [ ] 既有「樂樂」amber tag 不受影響
- [ ] 不再出現 LINE SVG icon、不再出現 🔔 emoji
- [ ] tag 不換行（whitespace-nowrap），多 tag 並排不擠壓姓名

### 3.3 編號欄移除後的連帶
- [ ] `已合併` / `已刪除` 標籤改顯示在姓名列（原在編號欄），顏色不變、語意不變
- [ ] merged/deleted 會員姓名以灰字（text-zinc-400）呈現
- [ ] 點該列仍可開「會員明細」modal（列 onClick 仍在）
- [ ] modal 標題仍顯示 `#會員編號`（member_no 仍存在資料層）
- [ ] 「編輯」「🔎 查訂單」按鈕仍正常（`?q=<member_no>` 連結未壞、`stopPropagation` 正常）

### 3.4 安全（「LINE User ID 一律馬賽克」記憶）
- [ ] LINE tag 不含原始 `Uxxxx...`；DOM / title 皆無 LINE User ID

## 4. Regression
- [ ] 搜尋（會員編號 / 姓名 / 手機）仍正常 —— 編號雖不顯示，搜尋條件保留
- [ ] 門市篩選、排序（姓名/取貨店/加入/最後登入/更新）、分頁仍正常；排序不再有「編號」選項
- [ ] 「顯示已合併 / 已刪除」勾選仍正常
- [ ] `?id=N` 直接開 detail modal 仍正常
- [ ] 訂單數 / 未取貨金額 / 儲值 不受影響
- [ ] `MemberDetail` LINE User ID 仍為馬賽克（未被本次波及）

## 5. 驗收門檻
§0 確認、§3-§4 全勾、**無 console error**、**build + type-check 過** 才可標 done。
（本功能無 migration，Supabase dev push 不適用。）
