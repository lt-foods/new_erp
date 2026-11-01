# 商品向量標籤 × 每日熱度排序

> 2026-11-01 · 規劃文件，尚未實作。
> 接續 `docs/PLAN-行銷策略系統-熱銷比.md`（2026-08-09）：那份講「開團前預估會不會熱」，
> 這份講「用向量把商品分群、每天從點擊／下單找出哪一類正在熱」，兩者共用同一套標籤與統計。
> 文中數字都是 2026-11-01 對線上庫實際查的，不是估計。

---

## 一頁結論

**可以做，外面的標準做法叫「兩段式推薦」：召回（向量找相似）＋ 排序（點擊／轉換統計＋探索）。
但套到團購店之前，先認清三件事，否則會照電商的樣板做出一套沒人用的東西。**

1. **你的「點擊」不在 app 裡。** 近 30 天訂單來源：LINE 社群 +1（`line_bot`）**45.7%**、
   店員手 key（`manual`）19.3%、商城 app（`liff`+`pwa`）**31.0%**。
   所以「點擊率」在你這裡 = **貼文留言 +1 率** 為主、**app 瀏覽→下單** 為輔。
   只看 app 的 CTR 會漏掉七成生意（線上 852 個團「買家數 ÷ 瀏覽人數」平均 117%，就是這個原因）。
2. **87% 商品只開過一次團**（前文數字），所以每天學的對象不是「哪個商品」，是「**哪一類商品**」
   （標籤群／向量群）。向量的價值正是把一次性商品歸到可累積統計的群。
3. **目前最大的洞是標籤覆蓋率**：4,390 個商品只有 1,732 個有標籤（39%），
   **近 30 天新增 960 個、0 個有標籤**。規則標籤只在 8/9 跑過一次，沒有掛在新品上架流程。
   前文回測證明標籤是預測主力（單獨 ρ=0.32），標籤斷了後面全部失效。
   **向量自動貼標就是先解這個。**

---

## 一、資料現況（2026-11-01）

| 項目 | 數字 | 意義 |
|---|---|---|
| 商品 / 有標籤 | 4,390 / 1,732（39%） | 向量第一個用途：補標 |
| 近 30 天新商品 / 其中有標籤 | 960 / **0** | 標籤規則沒接上架流程 |
| 標籤數 | 50（含子類） | 字彙夠用，先不要加 |
| 近 30 天開團 / 訂單 / 買家 | 1,059 團 / 22,527 單 / 2,617 人 | 量夠每日統計 |
| `campaign_views`（app 瀏覽） | 41,336 次 / 2,505 人（8/5 起） | **每 (團,會員) 一列累加，沒有每日明細** |
| LINE 貼文 / 留言 | 1,829 篇 / 2,870 則 +1（9/7 起） | 有貼文↔團對應、有留言時間，**沒有貼文曝光數** |
| 貼文內商城連結 | `/shop/c/<id>`，**無 utm/ref** | 分不出從哪個社群點進來 |
| 曝光（列表上出現過哪些卡片） | 沒記 | 修不了 position bias |
| 取消率（30–60 天前的單） | 3.4% | 完成率可當第三個訊號 |
| `vector` extension | 0.8.0 可裝、**未裝** | 一行 SQL |
| `pg_cron` / `pg_net` | 已啟用 | 排程與呼叫 Edge Function 沿用既有模式 |
| LLM / embedding 呼叫 | 無 | 要新開一支 Edge Function |

---

## 二、外面怎麼做

### 2.1 商品向量（product embedding）

把「品名＋短名＋既有標籤＋描述前 300 字」丟 embedding 模型 → 一個 1,024～1,536 維向量，
兩個商品的相似度 = cosine。蝦皮、Amazon、Instacart 都這樣做。四個用途，依對你的價值排序：

| 用途 | 做法 | 你現在的對應 |
|---|---|---|
| **自動貼標** | kNN：找最近的 20 個已標商品投票，≥40% 同標籤就建議；或 zero-shot：標籤名稱也做向量，商品離哪個最近貼哪個 | 取代「品名 regex 規則」，規則對 960 個新品一個都沒貼到 |
| 重複商品比對 | 新候選 vs 既有商品 cosine ≥ 0.85 → 提示「可能是同一個」 | 候選池 BRIEF 裡的「70% 相似」目前是字串比對 |
| 冷啟動 | 新品沒歷史 → 借最近 k 個相似品的滲透率 | 前文 Phase 1 的 reference product |
| 相關商品 | 詳情頁「看了這個的人也看」 | 商城目前沒有 |

模型選擇（都是 API，Edge Function `fetch` 就能打，不用 host）：

| 模型 | 中文 | 費用 | 備註 |
|---|---|---|---|
| OpenAI `text-embedding-3-small`（1536 維） | 可 | US$0.02 / 1M tokens | 最省事；4,390 商品 × ~300 tokens ≈ 1.3M ≈ **US$0.03**，每月新品 1,000 筆可忽略 |
| Voyage `voyage-multilingual-2`（1024 維） | 好 | US$0.12 / 1M | 多語言分數高於 OpenAI small |
| 開源 `bge-m3` | 最好 | 自己 host | 中文 benchmark 最強，但要多養一台機器，現階段不值 |

存 pgvector + HNSW index（`vector_cosine_ops`）。4 千筆其實連 index 都不用，但一次做好。
**一定要存 `model` 欄位**：換模型要全部重算，兩個模型的向量不能互比。

圖片向量（CLIP）排第二階段：你的商品圖多是廠商圖，文字已經夠分。

### 2.2 每日熱度排序

電商首頁／搜尋排序的標準零件，每一個都是為了修一種「數字騙人」：

| 零件 | 修什麼 | 做法 |
|---|---|---|
| **貝式平滑** | 1 瀏覽 1 下單 = 100% 轉換衝到第一名 | `(成功 + α) / (曝光 + α + β)`，α/β 用全站平均 × 虛擬樣本數（例如 20） |
| **時間衰減** | 上個月爆款永遠霸榜 | 指數衰減，半衰期 3～7 天（Hacker News / Reddit 排序同理） |
| **探索（Thompson Sampling）** | 新品沒曝光 → 沒點擊 → 永遠沒曝光 | 每次排序從 `Beta(α+成功, β+失敗)` 抽一個數當分數，不確定的東西自然偶爾浮上來 |
| **位置偏差** | 排第一本來就多 3 倍點擊 | 點擊 ÷ 該位置的平均 CTR；**沒有曝光紀錄就修不了** |
| **探索槽** | 自我實現預言（推得多→賣得好→推更多） | 固定 10% 位置隨機放，或留 holdout 不推（前文 Phase 5） |

架構一律**兩段式**：召回（標籤／向量取 100～200 候選）→ 排序（熱度分 × 業務規則：結單時間、庫存、毛利）。
排序分數不要只有一個數字，要連「信心」一起給（樣本數少 → 信心低 → 介面顯示「資料不足」，
這是前文 §6 第 3 條）。

### 2.3 團購店跟一般電商差在哪

| 一般電商 | 你 |
|---|---|
| 商品常駐，統計累積在 SKU 上 | 87% 商品只開一次團 → 統計累積在**標籤群 / 向量群** |
| 曝光 = 列表上看到 | 曝光 = **貼文發到幾個社群**（主）＋ 列表上看到（輔） |
| 點擊 = 點進詳情頁 | 點擊 = **+1 留言**（主）＋ app 瀏覽（輔） |
| 全站同一個母體 | 每團觸及店數 / 社群數不同（平均 9.9 家），**分母要用觸及**，同 CDI/BDI 那套 |
| 排序直接影響營收 | 排序只影響 31% 的 app 單；**最值錢的用法是「開團前選品」和「貼文誰先發」** |

---

## 三、漏斗：吸引力到底怎麼定義

```
曝光                 興趣                 下單                取貨
貼文發到 N 個社群  →  +1 留言 / app 瀏覽  →  customer_orders  →  picked_up / cancelled
line_note_posts      line_note_comments     (source 分通路)      (取消率 3.4%)
line_note_promos     campaign_views
```

三個比率，各自有意義，合成前先分開看：

| 比率 | 算法 | 抓到什麼 |
|---|---|---|
| **留言率** | +1 留言人數 ÷ 貼文觸及社群的會員數 | LINE 社群那 46% 的興趣訊號 |
| **瀏覽轉換** | 下單人數（`source IN ('liff','pwa')`）÷ app 瀏覽人數 | 商城那 31% 的興趣訊號 |
| **完成率** | 取貨 ÷ 下單 | 撲空／貨差／衝動下單的反向訊號 |

熱度分 = 三者加權（起始 0.5 / 0.3 / 0.2）→ 貝式平滑 → 半衰期 5 天 → 聚合到標籤群與向量群。
**每日輸出是「這週冷凍麵點熱、清潔用品冷」，不是「商品 #1234 熱」**——後者 87% 情況下沒有下一次。

---

## 四、分階段

### Phase A — 先把資料接上（1～2 週；沒有這些後面全是猜）

| 要做 | 為什麼 | 工作量 |
|---|---|---|
| 新品上架自動跑 `rpc_apply_product_tag_rules`（trigger 或 cron 每小時掃沒標籤的） | 960 個新品 0 標籤，先用既有規則補一輪 | 小 |
| 每日快照表 `campaign_daily_stats(date, campaign_id, views, viewers, orders, buyers, comments, cancelled)`，pg_cron 每晚聚合 | `campaign_views` 是累加表，看不到「第幾天」；前文 Phase 1 也要它 | 小 |
| 貼文連結帶 `?src=ln&cm=<community_id>`，`track_campaign_view` 收 `source` | 分得出哪個社群的人點進來，留言率與瀏覽轉換才能對上同一群人 | 小（`lineNoteRender.buildShopLink` + liff-api + 會員端詳情頁） |
| 商城列表曝光：卡片進畫面時 batch 送 `track_impressions` | 修 position bias 的唯一方法；第一版可先用「列表載入 = 曝光」近似 | 中 |
| 貼文觸及人數：`line_note_communities` 補 `member_count`（LINE 社群 API 或人工填） | 留言率的分母 | 小 |

### Phase B — 向量標籤（2 週）

- `CREATE EXTENSION vector;`
  `product_embeddings(product_id PK, model TEXT, embedding vector(1536), text_hash TEXT, updated_at)` + HNSW。
- Edge Function `product-embed`：pg_cron 每 10 分鐘撿「`text_hash` 跟現在算出來的不一樣」的商品，
  批次 100 筆打 embedding API，寫回。走既有 `line-note-tick` 的 pg_net → Edge Function 模式。
  API key 走 `Deno.env.get` → PR 敏感設定第一格要勾（CLAUDE.md 規矩）。
- `rpc_suggest_product_tags(product_id)`：kNN 20 個已標商品投票，回 `(tag, 票數比例)`。
  `product_tag_map.source` 加 `'embed'` 值；人工確認過的改 `'manual'`（重跑一律保留，既有語意）。
- **先回測再上**：拿 1,732 個已標商品做 leave-one-out，看 precision / recall；
  precision ≥ 0.85 的標籤群才自動貼，其餘只「建議、不自動寫」。
- 順手：候選池重複比對改用向量；開團頁「相似品參考」改用向量（前文 Phase 1 的 reference product）。

### Phase C — 每日熱度排序（2 週）

- `rpc_campaign_heat(p_days)`：從 `campaign_daily_stats` 算三比率 → 貝式平滑 → 衰減 →
  回 `(campaign_id, product_id, heat, confidence, 留言率, 瀏覽轉換, 完成率)`。
- `rpc_tag_heat(p_days)` / `rpc_cluster_heat`：同樣的分數聚合到標籤群與向量群（向量群用 kNN 鄰居加權平均）。
- 用在三個地方，**依價值排序**：
  1. **開團前選品**：候選池 / 商品清單加「同類近 14 天熱度」欄（標籤群 + 向量近鄰）。決策發生在開團前，這裡最值錢。
  2. **LINE 貼文與結單提醒的發送順序**：每帳號每分鐘 12 則上限（CLAUDE.md 10/8 那條），
     誰先發誰拿到流量 → `line_note_jobs` 排隊改依熱度 + 結單時間。
  3. **商城「推薦」排序**：Thompson Sampling + 10% 探索槽，影響 31% 的 app 單。
- 後台「熱度看板」一頁：今日 / 本週標籤群熱度、上升最快的群、**推了沒人理的團**（貼了 ≥3 個社群、0 留言 0 瀏覽）。

### Phase D — 之後

個人化（會員的瀏覽／購買向量 → 這團該推給誰，對應前文 Phase 4）、圖片向量、holdout uplift（前文 Phase 5）。
前文說會員預測類功能等歷史滿 180 天、約 11 月中 —— 現在就是了，Phase D 可以緊接 C。

---

## 五、驗收（先寫好）

| 指標 | 現在 | 目標 |
|---|---|---|
| 標籤覆蓋率 | 39% | ≥ 95% |
| 自動貼標 precision（leave-one-out） | — | ≥ 0.85 才自動寫入 |
| 熱度分 vs 下週實際滲透率 Spearman ρ（每週自動跑） | — | ≥ 0.40 才拿去排商城；0.30 以下只當參考 |
| 0 買家團比率（前文） | 8.4% | < 5% |
| 推了沒人理的團被提早發現 | — | 貼文 24 小時 0 留言 → 看板上亮 |

---

## 六、坑

1. **不要拿 app 瀏覽當全部的點擊。** 七成訂單不經 app；「買家 ÷ 瀏覽」會算出 117%。
2. **分母一定是觸及，不是全站。** 同前文 §6 第 1 條，否則永遠是發最多社群的團最熱。
3. **向量相似 ≠ 會賣。** 前文回測 kNN 相似品 ρ=0.322，比單純標籤平均還差。
   向量是拿來**貼標、找候選、比重複**；熱度要靠統計。
4. **embedding 文本要固定模板**，改模板或模型就是全部重算；`text_hash` 與 `model` 兩欄缺一不可。
5. **自動貼標要有人工覆寫且重跑不覆蓋**，沿用 `product_tag_map.source` 的語意。
6. **熱度高 → 多推 → 更熱** 的迴圈，從第一天就留探索槽；不然三個月後看板上只剩那幾類。

---

## 附錄：相關檔案

- 前文：`docs/PLAN-行銷策略系統-熱銷比.md`、`docs/BRIEF-社群商品候選池與商品行事曆.md`
- 標籤：`supabase/migrations/20260809000020_product_tags.sql`、`20260809000060_product_tag_subcategories.sql`
- 瀏覽：`supabase/migrations/20260805000000_campaign_views.sql`（`rpc_track_campaign_view`）、
  `apps/member/src/app/shop/c/[id]/CampaignDetailClient.tsx`
- 商城排序：`apps/member/src/app/shop/page.tsx`（`new` / `hot` / `recent`）、
  `supabase/functions/liff-api/index.ts` `listActiveCampaigns`
- 訂單來源：`customer_order_items.source`（`apps/admin/src/lib/orderSource.ts`）
- LINE 貼文：`supabase/migrations/20260908010000_line_note_bridge.sql`、
  `20261026000000_line_note_campaign_promo.sql`、`supabase/functions/_shared/lineNoteRender.ts`（`buildShopLink`）
- 排程範例：`line-note-tick`（pg_cron + pg_net → Edge Function）
- 回測腳本：`scripts/analysis-campaign-demand-backtest.py`（熱度 ρ 的每週回測沿用它的架構）
