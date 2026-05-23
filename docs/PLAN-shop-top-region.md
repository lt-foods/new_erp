# /shop 頂部進入區 layout 規劃

**對應頁面：** [apps/member/src/app/shop/page.tsx](apps/member/src/app/shop/page.tsx)
**現況截圖：** 使用者於 2026-05-23 提供（PageShell「商品」title → 直接到「團購商品 💕 / 50 團」+ tab + grid，**中間無任何 banner / 入口**）
**規劃目標：** 把「進入區」(PageShell title → 「團購商品」section 之間) 重新設計，留出空間給 banner、捷徑、公告，但不犧牲商品 grid 的可見性。

---

## 1. 現況 vs 期望

### 1.1 現況（截圖）
```
┌─────────────────────────────────┐
│ 🐱 商品                          │  ← PageShell sticky header (32px bold)
├─────────────────────────────────┤
│                                  │
│ 團購商品 💕              50 團  │  ← 直接接 grid section
│ [最新] [最熱銷] [近期售出]      │
│ ┌────┬────┐                      │
│ │商品│商品│                      │
└─────────────────────────────────┘
```

問題：頂部沒有「主題 / 行銷 / 個人化」入口，使用者只能在 50 團 grid 裡平面瀏覽，缺：
- 主題開團（美食列車、未來其他類別）的優先曝光
- 限時搶購的緊迫感入口
- 公告／取貨提醒等任務型訊息

### 1.2 期望（本規劃完成後）
```
┌─────────────────────────────────┐
│ 🐱 商品                    🔔3  │  ← header 右側加通知鈴 (P1)
├─────────────────────────────────┤
│ 🎁 你有 1 筆訂單可取貨 →        │  ← 取貨提醒條 (P1, 有才出現)
├─────────────────────────────────┤
│ 📢 母親節活動 5/10 -- 5/12 →   │  ← 公告跑馬燈 (P2, 有才出現)
├─────────────────────────────────┤
│ ┌─────────────────────────────┐ │
│ │ 🚂 美食列車                  │ │  ← P0 (剛 ship,有 food_train 才出現)
│ │   嚴選美食 · 限時開團 5 團   │ │
│ │                          ›  │ │
│ └─────────────────────────────┘ │
│ ┌─────────────────────────────┐ │
│ │ ⚡ 限時專區                  │ │  ← P0 (既有,有 fast 才出現)
│ │   最快結單 · 01:19:39       │ │
│ │                          ›  │ │
│ └─────────────────────────────┘ │
├─────────────────────────────────┤
│ 團購商品 💕              50 團 │
│ [最新] [最熱銷] [近期售出]     │
│ ┌────┬────┐                     │
└─────────────────────────────────┘
```

---

## 2. 候選元素清單

| # | 元素 | 用途 | 出現條件 | 資料來源 | 期別 |
|---|------|------|----------|----------|------|
| A | **美食列車 banner**（綠） | 主題專區入口 | tenant 有 ≥1 個 `category='food_train' AND status='open'` | `list_active_campaigns` payload 含 category | **P0** ✅ 已做 |
| B | **限時專區 banner**（紅/橘倒數） | 限時搶購入口 | tenant 有 ≥1 個 `close_type='fast' AND status='open'` | 同上 close_type | **P0** ✅ 既有 |
| C | **取貨提醒條** | 提醒會員去取貨 | 該會員有 status='ready' 的 customer_orders（已到貨待取） | liff-api 新 action `get_pending_pickups` | **P1** |
| D | **公告跑馬燈** | 店家後台發公告（活動 / 休團 / 系統） | 有 active 公告且未過期 | 新表 `announcements` + liff-api 新 action | **P2** |
| E | **通知未讀鈴**（header rightAction） | 未讀通知導去 /notifications | 未讀 count > 0 顯示紅點 | 既有 `useUnreadNotifications` hook（底部 tab 已用） | **P1** |
| F | **分類 icon grid**（4x2） | 蝦皮式分類入口 | 需要先設計「分類」schema（本期只有 food_train 一類） | TBD | **P2**（等多類別後） |
| G | **搜尋列** | 商品 / 團名搜尋 | 永遠出現（但 PWA 可先不做、用底部 tab + grid 取代） | 既有 `list_active_campaigns` + 前端 filter | **P2** |
| H | **熱門商品橫向 carousel** | 跟「最熱銷」tab 重疊 | 跟既有 tab 重複，不建議 | — | **不做** |
| I | **新會員 / 生日專區** | 個人化行銷 | 該會員符合條件 | TBD（profile + 生日邏輯） | **P3** |

---

## 3. 推薦排版（從上到下）

**原則**：任務型 > 行銷型 > 瀏覽型。任務型在前讓使用者「先做事再逛」。

| 位置 | 元素 | 出現條件 | 高度估算 |
|------|------|----------|----------|
| 0 | PageShell 標題 + 通知鈴 (E) | 永遠 | sticky 64px + safe-area |
| 1 | **取貨提醒條** (C) | 有待取訂單 | 44px（單行） |
| 2 | **公告跑馬燈** (D) | 有公告 | 36px（單行） |
| 3 | **美食列車 banner** (A) | 有 food_train | 16:8 比例 ≈ 195px |
| 4 | **限時專區 banner** (B) | 有 fast | 16:8 比例 ≈ 195px |
| 5 | 「團購商品」section + tab + grid（既有） | 永遠 | 滾動到底 |

**首屏（375x812 iPhone）能看到**：標題 + 1 個提醒/公告 + 1 個 banner + 「團購商品」section 標題上緣。**第二屏**：第二個 banner + grid 第一排。

### 3.1 雙 banner 都存在時的折衷
- 兩個都顯示（不互斥），總高 ≈ 400px → 滑一下就看到 grid，使用者習慣可接受
- 排序固定：美食列車 在上（綠色，主題行銷更主動）、限時專區 在下（紅色高 contrast 仍醒目）
- 若未來有第 3 個主題 banner 出現，要改 horizontal scroll 卡片條，不能上下繼續疊

### 3.2 視覺 contrast 避撞色
| Banner | 主色 | 次要識別 |
|--------|------|----------|
| 美食列車 | emerald-500 → teal-600 漸層 + 🚂 | 永遠不放倒數（用「N 團熱賣中」靜態文字） |
| 限時專區 | brand-gradient(玫紅) + ⚡ | 動態倒數（最快結單時間） |

→ 兩者用「動 vs 靜」+「色相」雙軸區分，不會混淆。

---

## 4. 每區塊規格細節

### 4.1 取貨提醒條（C, P1）
```
┌──────────────────────────────────────┐
│ 🎁 你有 1 筆訂單可取貨 → /orders?tab=ready │
└──────────────────────────────────────┘
```
- 樣式：`bg-amber-50` + `text-amber-900`，圓角 12px，44px 高
- 出現條件：`SELECT COUNT(*) FROM customer_orders WHERE member_id=$ AND status='ready'` > 0
- 0 筆時整條不渲染（不留空白）
- 點擊 → `/orders?tab=ready`
- 顯示文案：`你有 N 筆訂單可取貨`（N 來自 RPC）
- 資料新鮮度：跟 campaign list 同次 fetch（liff-api action 加 `with_pending_pickups: true` 一起回）

### 4.2 公告跑馬燈（D, P2）
```
┌──────────────────────────────────────┐
│ 📢 母親節活動 5/10 -- 5/12 全店滿千... │  ← marquee 或單行截斷
└──────────────────────────────────────┘
```
- 樣式：`bg-zinc-100` + `text-zinc-700`，36px 高
- 出現條件：有 active 且未過期的公告（取最新一筆 or marquee 輪播）
- 需先建 schema：
  ```sql
  CREATE TABLE announcements (
    id BIGSERIAL PRIMARY KEY,
    tenant_id UUID NOT NULL,
    title TEXT NOT NULL,
    url TEXT,                            -- 可選, 點擊跳轉
    starts_at TIMESTAMPTZ DEFAULT NOW(),
    ends_at TIMESTAMPTZ,                 -- NULL=永久
    priority INT DEFAULT 0,              -- 排序
    created_at TIMESTAMPTZ DEFAULT NOW()
  );
  ```
- admin 後台需配套 CRUD 頁
- liff-api action `list_announcements`

### 4.3 通知未讀鈴（E, P1）
```
header right slot:
  🔔 (右上紅點數字: 3)
```
- 用 PageShell 既有 `rightAction` prop（不用改 PageShell）
- 取既有 hook `useUnreadNotifications`（已存在於底部 tab）
- 點 → `/notifications`
- count=0 顯示灰色鈴、無紅點；count > 0 顯示品牌色 + 紅點數字（>9 顯示「9+」）
- 提醒：iOS PWA 通知是底部 tab 也有，這裡是「主動位置」入口；不衝突，但要 audit 是否真的需要兩處（可能只在 /shop 加，其他頁不加）

### 4.4 美食列車 banner（A, P0 - 已 ship）
- 維持目前實作（剛 merge 的 PR）
- 文案：`{N} 團熱賣中`，N = `visible.filter(c => c.category === 'food_train').length`
- 點 → `/shop/food-train`

### 4.5 限時專區 banner（B, P0 - 既有）
- 維持目前實作
- 點 → `/shop/flash`

### 4.6 分類 icon grid（F, P2 — 等多分類）
**先不做**。理由：目前只有 food_train 一個分類，做 grid 沒意義（一格 icon vs 一個 banner，banner 資訊密度高、視覺更突出）。等 category enum 累積到 ≥4 個值（如生鮮、衣物、節慶...）再轉成 grid。

到時的 mock：
```
┌────┬────┬────┬────┐
│ 🚂 │ 🥬 │ 👕 │ 🎉 │
│美食│生鮮│衣物│節慶│
├────┼────┼────┼────┤
│ ⚡ │ 🎁 │ 🏷 │ ··· │
│限時│優惠│折扣│更多│
└────┴────┴────┴────┘
```

---

## 5. Edge cases / 0-data 狀態

| 場景 | 表現 |
|------|------|
| 完全沒 open campaign | 標題 → 既有 empty state（🛒「目前沒有進行中的團購」）；P1/P2 元素仍可出現 |
| 只有食物列車、無 fast | 美食列車 banner 出現、限時 banner 不出現；grid 顯示食物列車那團 |
| 只有 fast、無食物列車 | 反之 |
| 兩個 banner 同時、加公告加取貨 | 進入區 ≈ 1.5 屏；可接受（使用者預期滾動） |
| 無公告無待取訂單 | 進入區只剩 banner，乾淨 |
| Loading | 既有 skeleton 處理（每個區塊獨立 skeleton；現況 banner 沒 skeleton，本期可加） |
| 推播載入失敗 | 任一區塊 fetch error → 該區塊不渲染（silent），不能整頁紅字 |

---

## 6. 性能考量

- **首屏 LCP**：banner 圖片用 `loading="eager"` + `decoding="async"`；其他 banner 圖 lazy
- **資料合併**：取貨提醒、公告、開團列表合進**一次** liff-api 呼叫（新 action `get_shop_home` 包 3 個 payload），避免瀑布
- **快取**：保留現有 `shopCache` SPA 快取機制（剛 PR 加的「進詳情再返回不 reload」）；新欄位也納入快取 key

---

## 7. 分期實作建議

### Phase 1 — 已 ship（[PR #340](https://github.com/lt-foods/new_erp/pull/340)）
- ✅ **A. 美食列車 banner**
- ✅ **B. 限時專區 banner** → **改 horizontal carousel**（scroll-snap + dots + auto-play 4s + 觸碰暫停 8s）
- ✅ **C. 取貨提醒條**（有 status='ready' 訂單才出現；amber 條置頂；點擊到 /orders）

### Phase 2（之後再說）
- **D. 公告跑馬燈** — 不做（用 LINE 群組 / OA 取代）
- **E. 通知未讀鈴** — 不做（底部 tab 已 cover）
- liff-api 合併 `get_shop_home` 多 payload — 半天（性能優化，需要時再做）

### Phase 3（多分類後）
- **F. 分類 icon grid** — 等 category 累積到 ≥4 個值

### 不做（明確 out of scope）
- **G. 搜尋列**：底部 tab 已 cover 主要 nav，grid 50 團內可滾，不急
- **H. 熱門 carousel**：跟「最熱銷」tab 重疊
- **I. 新會員 / 生日**：個人化複雜度高、目前 ROI 不明

---

## 8. 一些待你拍板的點

1. **通知鈴位置**：要不要做？底部 tab 已有「通知」tab + 紅點 badge。多一個 header 鈴是 redundancy（好處：在 /shop 不用視線移到底部）
2. **取貨提醒條**：是「滿足條件才出現」還是「永遠在最上方、0 時顯示『目前無待取貨』」？前者乾淨、後者更主動
3. **雙 banner 順序**：「美食列車 在上、限時 在下」可接受嗎？還是反過來（限時通常更急迫）
4. **公告跑馬燈**：需要嗎？團購店家常用群組 LINE 發公告，不一定要進 app

請挑要做的、要刪的，下一輪我把 P1 那批做掉。
