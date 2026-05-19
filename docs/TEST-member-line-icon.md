# member-line-icon 測試項目 — 後台會員列表已綁 LINE 顯示 icon

**對應 UI 變更:** `apps/admin/src/app/(protected)/members/page.tsx`
**判斷依據:** `members.line_user_id` 非空（與 `apps/admin/src/components/MemberDetail.tsx:255` `hasLine = !!member.line_user_id` 一致）
**無 migration / 無 RPC：** §1、§2 不適用（純前端顯示，沿用既有 `members` select 加 `line_user_id` 欄）

## 0. 資料前置（read-only sanity）

- [ ] `members` 表存在 `line_user_id` 欄
  ```sql
  select column_name from information_schema.columns
  where table_name='members' and column_name='line_user_id';
  ```
- [ ] 至少有 1 筆 `line_user_id` 非空、且 1 筆為空的會員，icon 有/無兩態才可測
  ```sql
  select
    count(*) filter (where line_user_id is not null) as bound,
    count(*) filter (where line_user_id is null)     as unbound
  from members where status not in ('merged','deleted');
  ```

## 3. UI 行為（preview / 碼審）

### 3.1 列表載入
- [ ] `/members` 載入無 console error
- [ ] `members` select 已含 `line_user_id`，列表筆數 / 分頁數不變（與改動前一致）

### 3.2 已綁 LINE 會員
- [ ] `line_user_id` 非空的會員，姓名列顯示 LINE icon（綠底官方色）
- [ ] icon 位於姓名旁，與既有「樂樂」badge、🔔 push icon 並排，排版不換行、不擠壓

### 3.3 未綁 LINE 會員
- [ ] `line_user_id` 為空的會員，**不**顯示 LINE icon

### 3.4 安全（呼應「LINE User ID 一律馬賽克」記憶）
- [ ] icon 不渲染 LINE User ID 本身；DOM / title / aria-label 皆不得出現原始 `Uxxxx...` 字串
- [ ] icon 有可存取名稱（aria-label，如「已綁定 LINE」），但內容不含 ID

### 3.5 互動不受影響
- [ ] 點該列仍可開「會員明細」modal
- [ ] 「編輯」「🔎 查訂單」按鈕仍正常、`stopPropagation` 未被破壞

## 4. Regression

- [ ] 搜尋（會員編號 / 姓名 / 手機）仍正常
- [ ] 門市篩選、排序（各欄）、分頁仍正常
- [ ] 「顯示已合併 / 已刪除」勾選仍正常
- [ ] `?id=N` 直接開 detail modal 仍正常
- [ ] 訂單數 / 未取貨金額 / 儲值 / 🔔 push icon / 樂樂 badge 全部不受影響（新增欄位未動既有資料流）
- [ ] `MemberDetail` 的 LINE User ID 顯示仍為馬賽克（未被本次改動波及）

## 5. 驗收門檻

§0 資料前置確認、§3-§4 全勾、**無 console error**、**build + type-check 過** 才可標 done。
（本功能無 migration，Supabase dev push 不適用。）
