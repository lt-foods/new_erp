# General 轉檔 Platform — Road Map

> 一個通用、可擴充的檔案轉換平台。聚焦 ECAD / MCAD 工程檔案，支援同步與非同步兩種輸出模式，內建任務通知與狀態查詢。本文件同時涵蓋產品願景與技術架構，作為跨 PM / 工程 / 管理層的共同藍圖。

---

## 0. 文件資訊

| 項目 | 內容 |
|---|---|
| 文件版本 | v0.1 (Draft) |
| 最後更新 | 2026-05-28 |
| 定位 | 產品 + 技術完整版 Road Map |
| 系統定位 | **獨立平台**(self-contained service,不綁定現有 ERP/Supabase;預留未來整合介面) |
| 階段模型 | MVP → Phase 2 → Phase 3(以能力成熟度分階段,不綁死日期) |
| 主要使用者 | 工程師 / 設計團隊 / 自動化系統(CI、PLM、PDM) |
| 對標對象 | CloudConvert、Zamzar、Autodesk Platform Services (APS/Forge)、CAD Exchanger Cloud、Adobe PDF Services API、AWS MediaConvert(非同步任務模型) |

---

## 1. 願景與問題陳述

### 1.1 願景

打造一個**「丟進去任何工程檔、拿得到任何目標格式」**的轉檔平台:對使用者隱藏背後各家 CAD/EDA 工具的複雜度,以一致的 API 與 UI 提供穩定、可追蹤、可擴充的檔案轉換服務。

### 1.2 問題陳述

工程協作中,檔案格式碎片化是長年痛點:

- **ECAD** 各家工具(Altium、KiCad、Cadence、Mentor)輸出格式不互通,交付常需 Gerber / ODB++ / IPC-2581 多版本並存。
- **MCAD** 原生格式(SolidWorks、CATIA、Creo、NX)互相鎖定,跨廠商協作仰賴 STEP / IGES 等中性格式。
- 轉檔工作目前散落在各工程師桌機、手動操作、無紀錄、無版本、難稽核。
- 大型 3D 模型 / 多層 PCB 轉檔耗時,**同步等待**會卡住流程,需要**非同步 + 通知**模型。

### 1.3 成功的樣子(North Star)

> 任一工程師或系統,透過單一 API / UI,在不關心底層工具的情況下,把來源檔轉成目標格式;小檔即時拿到結果,大檔丟了就走、完成自動通知,且每一筆轉檔都可查詢、可重現、可稽核。

---

## 2. 範圍(Scope)

### 2.1 In Scope

- 檔案輸入(上傳 / URL 拉取 / 後續 API 串接)。
- 檔案輸出(下載連結 / 推送回呼)。
- 多檔案類型轉換,**優先序**:中性交換格式 → ECAD 主流 → MCAD 主流。
- **同步**(small / fast)與**非同步**(large / batch)兩種輸出模式。
- 任務狀態查詢(輪詢 + 即時)。
- 通知(Webhook / Email / 站內 / 後續 IM)。
- 轉換設定檔(Conversion Profile)與參數化轉換。
- 基本的認證、配額、稽核。

### 2.2 Out of Scope(目前)

- 線上檔案編輯 / CAD 視覺化編修(僅做轉換與輕量預覽)。
- 與特定 ERP / PLM 的深度業務整合(預留介面,非本期目標)。
- 自研 CAD 幾何核心(採用既有引擎 / 商用 SDK / OSS 工具鏈)。
- 計費金流(先做用量計量 metering,計費另議)。

---

## 3. 名詞定義

| 名詞 | 定義 |
|---|---|
| **Job(轉檔任務)** | 一次轉換請求的最小單位,含來源檔、目標格式、參數、狀態。 |
| **Source / Target** | 來源格式與目標格式。 |
| **Converter / Engine** | 實際執行轉換的引擎(可為 OSS CLI、商用 SDK、自寫 adapter)。 |
| **Conversion Profile** | 預先定義的一組轉換參數(例:Gerber→PDF 黑白、STEP→glTF 含貼圖)。 |
| **Sync mode** | 同步:請求阻塞直到拿到結果,適合小檔 / 快速轉換。 |
| **Async mode** | 非同步:立即回傳 Job ID,結果以通知 / 查詢取得。 |
| **Neutral format** | 中性 / 開放交換格式(STEP、IGES、ODB++、IPC-2581、glTF…)。 |

---

## 4. 使用者與使用場景(Personas & Use Cases)

| Persona | 目標 | 典型場景 |
|---|---|---|
| **硬體 / PCB 工程師** | 產出製造交付檔 | Altium 設計 → 一鍵轉 Gerber X2 + ODB++ + IPC-2581 交廠。 |
| **機構工程師** | 跨廠商交換 3D 模型 | SolidWorks → STEP 給供應商;客戶 CATIA → STEP → 內部 Creo。 |
| **採購 / 供應商窗口** | 取得可預覽輕量檔 | 收到原生 CAD,轉 glTF/PDF 做線上預覽與報價。 |
| **自動化系統 (CI/PLM)** | 無人值守批次轉換 | Git push 後自動轉檔出圖、產生製造包,完成回呼通知。 |
| **平台管理員** | 監控與治理 | 查看任務量、失敗率、引擎健康、用量配額、稽核軌跡。 |

### 4.1 代表性 User Stories

- 作為工程師,我要上傳一個 STEP 檔並選擇轉成 glTF,**小檔我希望馬上拿到結果**。
- 作為工程師,我要送出一個 800MB 的組裝體轉換,**不想在頁面上等**,完成後用 Email / Webhook 通知我。
- 作為自動化系統,我要用 API 送出轉檔、拿到 Job ID,之後**輪詢狀態**或**接收 Webhook**取得結果連結。
- 作為管理員,我要查詢任一 Job 的**完整生命週期軌跡**(誰送的、用哪個引擎、耗時、成功與否、輸出在哪)。

---

## 5. 核心功能需求

### 5.1 檔案輸入(Input)

| 能力 | 說明 | 階段 |
|---|---|---|
| 直接上傳 | 多檔上傳、拖放、分片 / 續傳(大檔) | MVP(分片於 Phase 2) |
| 預簽章上傳 | 前端直傳物件儲存(presigned URL),避開 API 中轉 | MVP |
| URL 拉取 | 提供來源 URL,平台自行下載 | Phase 2 |
| ZIP / 多檔輸入 | ECAD 常為一組檔(Gerber set、含網表 / 鑽孔) | MVP(ECAD 必要) |
| 格式自動偵測 | 依副檔名 + magic number + 內容嗅探判斷來源格式 | MVP |
| 輸入驗證 | 檔案完整性、大小上限、病毒掃描(Phase 2) | MVP / P2 |

### 5.2 檔案輸出(Output)

| 能力 | 說明 | 階段 |
|---|---|---|
| 下載連結 | 產出存物件儲存,回傳有時效的 presigned URL | MVP |
| 多輸出 | 一個 Job 可同時產生多個目標格式 / 檔案 | Phase 2 |
| 打包輸出 | 多檔結果自動 ZIP | MVP(ECAD) |
| 回呼推送 | 完成後 Webhook 推送結果 metadata + 連結 | MVP |
| 結果保存期 | TTL 過期自動清除(可設定 / 配額) | MVP |
| 衍生預覽 | 產生縮圖 / 輕量 3D 預覽(glTF) | Phase 2 |

### 5.3 支援檔案類型(格式優先序)

> 策略:**先把中性 / 開放格式做穩**(可涵蓋最多互通需求且無授權風險),再逐步補原生格式(多需商用 SDK / 廠商工具)。

#### Tier 0 — 中性 / 開放交換格式(MVP 主力)

| 領域 | 格式 |
|---|---|
| MCAD 中性 | **STEP (AP203/214/242)**、**IGES**、STL、3MF、Parasolid (x_t) |
| MCAD 預覽 | **glTF / GLB**、OBJ、PLY |
| ECAD 中性 | **Gerber (RS-274X / X2)**、**ODB++**、**IPC-2581**、Excellon(鑽孔) |
| 文件 / 圖面 | PDF、DXF、DWG、SVG、PNG |

#### Tier 1 — ECAD 主流原生(Phase 2)

| 工具 | 來源格式 |
|---|---|
| KiCad | `.kicad_pcb` / `.kicad_sch`(OSS,優先) |
| Altium Designer | `.PcbDoc` / `.SchDoc` |
| Cadence Allegro | `.brd` |
| Mentor / Siemens (PADS, Xpedition) | 各自原生 |
| Eagle | `.brd` / `.sch` |

#### Tier 2 — MCAD 主流原生(Phase 2 → 3,多需商用 SDK)

| 工具 | 來源格式 |
|---|---|
| SolidWorks | `.sldprt` / `.sldasm` |
| CATIA | `.CATPart` / `.CATProduct` |
| Creo (Pro/E) | `.prt` / `.asm` |
| Siemens NX | `.prt` |
| Autodesk Inventor / Fusion | `.ipt` / `.iam` |

#### 格式支援矩陣(節錄,X = 規劃支援)

| Source \ Target | STEP | glTF | PDF | Gerber | ODB++ | IPC-2581 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| STEP | — | X | X(3D PDF) | | | |
| IGES | X | X | | | | |
| SolidWorks | X | X | X | | | |
| KiCad PCB | | | X | X | X | X |
| Altium PcbDoc | | | X | X | X | X |
| Gerber set | | | X | — | X | X |
| ODB++ | | | X | X | — | X |

> 完整矩陣於實作時以「能力註冊表(Capability Registry)」維護,API 提供 `GET /capabilities` 動態查詢。

### 5.4 同步 vs 非同步輸出模式

平台**雙模式**設計,由請求參數或檔案特性(大小 / 預估耗時)決定:

#### 同步(Synchronous)

- 適用:小檔、快速轉換(預估 < N 秒,例如中性格式互轉、出圖)。
- 流程:請求 → 即時轉換 → HTTP 回傳結果(或結果連結)。
- 設計:設逾時門檻;若超過,**自動降級為非同步**並回傳 Job ID(202 Accepted),避免長連線。

#### 非同步(Asynchronous)

- 適用:大檔、批次、重運算(大型組裝體、多層板、原生格式)。
- 流程:請求 → 立即回 `202 + Job ID` → 進佇列 → Worker 處理 → 完成發通知 → 以查詢 / Webhook 取結果。
- 保證:至少一次處理、可重試、冪等(同一 idempotency key 不重複建立)。

| 維度 | 同步 | 非同步 |
|---|---|---|
| 回應 | 結果本身 / 直接連結 | Job ID(202) |
| 適用檔案 | 小 / 快 | 大 / 慢 / 批次 |
| 取得結果 | HTTP response | 查詢 API + Webhook 通知 |
| 逾時策略 | 超門檻自動轉非同步 | 不阻塞 |
| 併發控制 | 受同步池上限保護 | 佇列削峰、可水平擴展 |

### 5.5 狀態查詢(Status)

- 每個 Job 有明確**狀態機**:
  `queued → running → succeeded / failed / canceled / expired`
  (細分:`validating`、`downloading`、`converting`、`uploading`)
- 提供:
  - `GET /jobs/{id}` — 單筆狀態 + 進度 + 結果連結 + 錯誤碼。
  - `GET /jobs` — 清單 / 篩選(狀態、時間、格式、使用者)。
  - **即時更新**:SSE / WebSocket 推播進度(Phase 2),MVP 先用輪詢 + `Retry-After`。
- 狀態含:進度百分比(若引擎可回報)、佇列位置、預估剩餘時間、重試次數、引擎版本。

### 5.6 通知(Notification)

| 通道 | 說明 | 階段 |
|---|---|---|
| **Webhook** | 任務完成 / 失敗推送(含簽章驗證、重試 + 死信) | MVP |
| **Email** | 完成 / 失敗信,含結果連結 | MVP |
| 站內通知 | UI 內通知中心 | Phase 2 |
| IM(Slack / Teams / LINE) | 群組 / 個人通知 | Phase 3 |
| 事件訂閱 | 可選擇訂閱哪些事件(started / progress / done / failed) | Phase 2 |

> Webhook 設計參考業界慣例:HMAC 簽章、時間戳防重放、指數退避重試、可在 UI 重送、提供事件記錄查詢。

---

## 6. 非功能性需求(NFR)

| 類別 | 目標 |
|---|---|
| **效能** | 同步轉換 P95 < 設定門檻;非同步佇列在尖峰可水平擴展 Worker。 |
| **可靠性** | 任務至少一次處理;失敗自動重試(可設上限);死信佇列保留可重放。 |
| **可擴展性** | 轉換引擎以**插件 / Adapter** 模式接入,新增格式不動核心;Worker 無狀態可橫向擴充。 |
| **可用性** | API 與佇列高可用;單一引擎故障不影響其他格式。 |
| **安全** | 傳輸 / 靜態加密、檔案隔離沙箱執行、結果連結時效化、租戶資料隔離。 |
| **隱私 / 合規** | 檔案 TTL 自動刪除、可稽核、可符合資料保留政策。 |
| **可觀測性** | 全鏈路 tracing、結構化日誌、指標(任務量 / 成功率 / 耗時 / 引擎健康)。 |
| **成本** | 用量計量(metering);Worker 依佇列長度自動伸縮,閒置縮容。 |

---

## 7. 系統架構(技術)

### 7.1 高階架構

```
                         ┌──────────────────────────────┐
   Client / API / CI ───▶│   API Gateway / Auth / Quota  │
                         └───────────────┬──────────────┘
                                         │
                  ┌──────────────────────┼──────────────────────┐
                  │ (sync, small)        │ (async, large/batch)  │
                  ▼                      ▼                       │
          ┌──────────────┐     ┌──────────────────┐             │
          │ Sync Executor │     │  Job Orchestrator │            │
          │ (inline pool) │     │  + Metadata DB    │            │
          └───────┬───────┘     └─────────┬────────┘            │
                  │                        │ enqueue             │
                  │                        ▼                     │
                  │              ┌───────────────────┐           │
                  │              │   Message Queue    │          │
                  │              └─────────┬─────────┘           │
                  │                        │ pull                │
                  ▼                        ▼                     │
          ┌───────────────────────────────────────────┐         │
          │            Worker Pool (stateless)          │        │
          │   ┌────────────────────────────────────┐    │       │
          │   │  Converter Adapter Layer (plugins) │    │        │
          │   │  ECAD engines │ MCAD engines │ ...  │    │       │
          │   └────────────────────────────────────┘    │       │
          └───────────────┬──────────────┬──────────────┘        │
                          │              │                        │
                          ▼              ▼                        ▼
                  ┌──────────────┐  ┌──────────────┐   ┌──────────────────┐
                  │ Object Store │  │ Metadata DB  │   │ Notification Svc  │
                  │ (in/out/tmp) │  │ (jobs/audit) │   │ webhook/email/IM  │
                  └──────────────┘  └──────────────┘   └──────────────────┘
```

### 7.2 核心元件

| 元件 | 職責 |
|---|---|
| **API Gateway** | 認證、授權、配額 / 速率限制、請求驗證、路由(sync/async)。 |
| **Job Orchestrator** | 建立 Job、寫 metadata、入佇列、狀態機管理、重試 / 冪等。 |
| **Message Queue** | 削峰、解耦、優先序佇列(大小檔分流)、死信佇列。 |
| **Worker Pool** | 無狀態消費者,拉任務 → 呼叫對應引擎 → 回報進度 / 結果;依負載自動伸縮。 |
| **Converter Adapter Layer** | 統一介面包裝各引擎(CLI / SDK / 服務);**插件式**註冊能力。 |
| **Object Store** | 來源 / 中繼 / 輸出檔儲存,presigned 上傳下載,TTL 清理。 |
| **Metadata DB** | Job、檔案、Profile、稽核軌跡、能力註冊表。 |
| **Notification Service** | Webhook / Email / IM,簽章、重試、事件記錄。 |
| **Capability Registry** | 動態維護「哪個來源→目標由哪個引擎支援、參數為何」。 |

### 7.3 轉換引擎抽象(關鍵設計)

```
interface Converter {
  id():           string          // e.g. "step-to-gltf@cad-exchanger"
  supports():     {source, target, params schema}[]
  validate(input): Result
  convert(input, params, ctx): Stream<Progress> -> Output
  healthcheck():  Status
}
```

- 每個引擎打包成**獨立容器**(隔離依賴 / 授權 / 沙箱),Worker 依 Job 路由到對應引擎容器。
- 新增格式 = 寫一個 Adapter + 註冊到 Capability Registry,**不動核心**。
- ECAD / MCAD 引擎可混用 OSS(KiCad CLI、OpenCASCADE、gerbv)與商用 SDK(CAD Exchanger、Datakit、Teigha/ODA、HOOPS Exchange)。

### 7.4 同步 / 非同步流程細節

**同步**:Gateway → Sync Executor(有限併發池) → 直接呼叫引擎 → 結果回傳;若超逾時門檻 → 轉存 Job、回 202 + Job ID。

**非同步**:Gateway → Orchestrator 建 Job(`queued`)→ 入 Queue → Worker 領取(`running`)→ 進度回報 → 完成寫結果(`succeeded`)→ 觸發通知。失敗進重試,超上限入死信(`failed`)。

---

## 8. API 設計(草案)

> RESTful + Webhook;非同步採 202 + 輪詢 / 推播,符合業界長任務慣例。

```
POST   /v1/jobs                # 建立轉檔任務(sync 或 async)
GET    /v1/jobs/{id}           # 查詢單筆狀態 / 結果
GET    /v1/jobs                # 任務清單 / 篩選
POST   /v1/jobs/{id}/cancel    # 取消任務
GET    /v1/jobs/{id}/result    # 取得結果連結(presigned)
GET    /v1/capabilities        # 查詢支援的來源/目標/參數矩陣
POST   /v1/uploads             # 取得 presigned 上傳 URL
GET    /v1/jobs/{id}/events    # SSE 即時進度(Phase 2)
POST   /v1/webhooks            # 註冊 / 管理 Webhook 端點
```

**建立任務請求(範例)**

```json
{
  "mode": "auto",                 // sync | async | auto(依大小/耗時自動決定)
  "source": { "upload_id": "u_123" },
  "targets": [
    { "format": "gltf", "profile": "preview-textured" },
    { "format": "step", "params": { "schema": "AP242" } }
  ],
  "notify": { "webhook": "https://...", "email": "me@corp.com" },
  "idempotency_key": "build-4711"
}
```

**同步回應(小檔)**:`200` + 結果連結。
**非同步回應**:`202` + `{ "job_id": "...", "status": "queued", "poll": "/v1/jobs/..." }`。

**Webhook 事件(範例)**

```json
{
  "event": "job.succeeded",
  "job_id": "j_789",
  "outputs": [{ "format": "gltf", "url": "https://...", "bytes": 10485760 }],
  "signature": "sha256=...",
  "timestamp": "2026-05-28T10:00:00Z"
}
```

---

## 9. 資料模型(核心實體)

```
Job
 ├─ id, tenant_id, created_by, created_at
 ├─ mode (sync|async), status, progress, queue_pos
 ├─ source_file_id, target_specs[], params
 ├─ engine_id, engine_version, retries, idempotency_key
 ├─ started_at, finished_at, duration_ms, error_code/msg
 └─ output_file_ids[]

File           : id, kind(source|intermediate|output), format,
                 bytes, checksum, storage_uri, ttl_expires_at
ConversionProfile : id, name, source, target, default_params
Capability     : source, target, engine_id, params_schema, status
WebhookEndpoint: id, url, secret, subscribed_events[], status
AuditLog       : actor, action, job_id, detail, timestamp
UsageMetric    : tenant_id, period, job_count, bytes, compute_ms
```

---

## 10. 安全與合規

- **認證 / 授權**:API Key / OAuth2;多租戶資料隔離(tenant scoping)。
- **沙箱執行**:每個轉換在隔離容器中跑,限制網路 / 檔案系統 / 資源,防惡意檔案利用引擎漏洞。
- **資料保護**:傳輸 TLS、靜態加密;結果連結 presigned 且時效化;檔案 TTL 自動刪除。
- **輸入防護**:大小上限、格式白名單、病毒掃描(Phase 2)、解壓炸彈防護。
- **稽核**:每筆 Job 全生命週期可追溯(誰、何時、何引擎、結果)。
- **配額 / 速率限制**:防濫用,保護同步池與 Worker。

---

## 11. 可觀測性與維運

- **指標**:任務量、成功 / 失敗率、各格式耗時分佈、佇列長度、Worker 使用率、引擎健康。
- **日誌**:結構化、含 Job ID 關聯,可端到端追蹤。
- **追蹤**:分散式 tracing 貫穿 Gateway → Queue → Worker → Engine。
- **告警**:失敗率 / 佇列積壓 / 引擎當機 / 死信成長 觸發告警。
- **儀表板**:即時平台健康、用量趨勢、Top 失敗原因。

---

## 12. Road Map(MVP → Phase 2 → Phase 3)

> 以**能力成熟度**分階段,不綁死日期;每階段有明確交付物與退出標準。

### Phase 0 — 基礎建設(Foundation)

- [ ] 物件儲存 + presigned 上傳 / 下載
- [ ] Metadata DB、Job 狀態機骨架
- [ ] API Gateway + 認證 + 基本配額
- [ ] Converter Adapter 介面定義 + Capability Registry 骨架
- [ ] CI / 部署 / 可觀測性基線

**退出標準**:能建立 Job、存取檔案、查狀態(尚無真實轉換)。

### Phase 1 — MVP(可用的最小閉環)

**目標**:單一閉環跑通 — 上傳 → 轉換 → 通知 → 取結果,聚焦 **Tier 0 中性格式**。

- [ ] **輸入**:直接上傳 + presigned + ZIP(ECAD set)+ 格式自動偵測
- [ ] **格式(Tier 0)**:
  - MCAD:STEP ↔ IGES、STEP → glTF/GLB、STEP → STL
  - ECAD:Gerber set → PDF、Gerber ↔ ODB++ ↔ IPC-2581(以 OSS 引擎為主)
  - 文件:DXF/DWG → PDF/SVG
- [ ] **同步模式**:小檔即時轉換 + 逾時自動降級非同步
- [ ] **非同步模式**:Queue + Worker + 重試 + 死信 + 冪等
- [ ] **狀態查詢**:`GET /jobs/{id}` 輪詢 + 進度欄位
- [ ] **通知**:Webhook(簽章 + 重試)+ Email
- [ ] **輸出**:presigned 下載 + 多檔 ZIP + TTL 清理
- [ ] **最小 UI**:上傳、選目標格式、看狀態、下載
- [ ] **基本治理**:配額、稽核軌跡、用量計量

**退出標準(成功指標)**:
- Tier 0 主要格式對轉成功率 ≥ 95%
- 同步小檔 P95 在門檻內;非同步大檔可穩定完成並通知
- 全部 Job 可查詢、可重現、有稽核紀錄

### Phase 2 — 擴充與體驗(Scale & Experience)

**目標**:擴大格式涵蓋(ECAD/MCAD 主流原生)、強化即時性與整合性。

- [ ] **格式 Tier 1(ECAD 原生)**:KiCad(OSS 優先)、Altium、Allegro、Eagle → 中性 / 出圖
- [ ] **格式 Tier 2 起步(MCAD 原生)**:SolidWorks / Inventor → STEP/glTF(導入商用 SDK)
- [ ] **輸入**:URL 拉取、大檔分片 / 續傳、病毒掃描
- [ ] **輸出**:多目標並行、衍生預覽(縮圖 / glTF)、3D PDF
- [ ] **即時狀態**:SSE / WebSocket 進度推播
- [ ] **通知**:站內通知中心、事件訂閱粒度、Webhook 管理 UI
- [ ] **Conversion Profile**:預設參數範本 + 自訂
- [ ] **批次轉換**:一次多檔 / 多目標的 batch Job
- [ ] **自動伸縮**:Worker 依佇列長度 HPA;成本最佳化
- [ ] **儀表板**:用量 / 健康 / 失敗分析

**退出標準**:ECAD 主流原生覆蓋率達標;批次與即時體驗上線;平台可在尖峰自動擴展。

### Phase 3 — 平台化與智慧化(Platform & Intelligence)

**目標**:從工具走向平台,強化生態整合與自動化。

- [ ] **格式 Tier 2 完整**:CATIA、Creo、NX 原生(HOOPS Exchange / Datakit 等)
- [ ] **整合介面**:對外 SDK(JS/Python)、PLM/PDM/CI 連接器、預留 ERP 整合 hook
- [ ] **IM 通知**:Slack / Teams / LINE
- [ ] **進階能力**:轉換管線(pipeline,多步串接)、規則式自動轉檔(watch folder / event-driven)
- [ ] **品質檢測**:轉換後幾何 / 圖層校驗、差異報告
- [ ] **智慧化**:格式 / 參數推薦、失敗自動診斷、相似檔去重快取
- [ ] **計費**:基於 metering 的計量計費
- [ ] **自助引擎接入**:第三方可註冊自有 Converter(plugin marketplace 雛形)

**退出標準**:成為可被多系統依賴的轉檔平台,具完整生態整合與營運模型。

---

## 13. 風險與緩解

| 風險 | 影響 | 緩解 |
|---|---|---|
| 原生 CAD 格式需商用 SDK,授權成本高 | 進度 / 成本 | Tier 0 中性格式先行;原生格式分階段、按需採購;Adapter 解耦可替換引擎 |
| 大型模型轉換耗時 / 耗資源 | 體驗 / 成本 | 非同步 + 自動伸縮 + 進度回報;資源上限與逾時保護 |
| 轉換正確性 / 幾何失真 | 信任 | 自動校驗(Phase 3)、回歸測試集、版本鎖定引擎 |
| 惡意檔案攻擊引擎漏洞 | 安全 | 沙箱隔離、資源限制、病毒掃描、最小權限 |
| 引擎版本升級造成行為改變 | 穩定性 | 引擎版本紀錄於 Job、可重現、灰度升級 |
| 格式爆炸(N×M 組合) | 維護 | Capability Registry 動態管理;以中性格式作 hub 減少組合 |

---

## 14. 業界對標(設計參考)

| 平台 | 借鑑點 |
|---|---|
| **CloudConvert / Zamzar** | 通用轉檔 API、Job 模型、Webhook、presigned 上傳下載、能力查詢 |
| **Autodesk Platform Services (APS/Forge)** | 工程檔(CAD)雲端轉換、衍生資料(derivatives)、glTF/SVF 預覽、非同步 manifest |
| **CAD Exchanger Cloud** | ECAD/MCAD 多格式互轉引擎、中性格式為樞紐 |
| **Adobe PDF Services API** | 非同步任務 + 輪詢 / Webhook、文件衍生 |
| **AWS MediaConvert** | 大型媒體非同步任務模型、佇列 / 優先序 / 進度 / 事件通知(可類比重運算轉檔) |
| **Tetra4D / HOOPS** | 3D PDF、CAD 視覺化與資料萃取 |

**共通設計範式**:統一 Job 模型、同步小檔 + 非同步大檔、presigned 直傳、Webhook + 輪詢雙取結果、能力動態查詢、引擎插件化、以中性格式為轉換樞紐。

---

## 15. 開放問題(待確認)

- [ ] 商用 CAD SDK 採購預算與時程(影響 Tier 1/2 排程)?
- [ ] 同步逾時門檻具體秒數 / 檔案大小界線?
- [ ] 資料保留政策(結果 TTL、是否需長期歸檔)?
- [ ] 多租戶模型:單租戶內部用,還是對外多客戶?
- [ ] 是否需要與現有 ERP/Supabase 的整合節點(雖定位獨立,但是否預留)?
- [ ] 部署環境(自架 K8s / 雲端 managed / 混合)?

---

> 本文件為 v0.1 Draft,後續依「開放問題」釐清與各 Phase 實作回饋持續迭代。
