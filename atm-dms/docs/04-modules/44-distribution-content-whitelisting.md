---
title: 功能規格 — 軟體派送 / 內容推播 / 程式白名單
module: AFMP / Modules / Distribution & Security
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Spec, Distribution, Content, Whitelisting, Security]
---

# 功能規格：軟體派送 / 內容推播 / 程式白名單（DMS 對等能力）

此三項為 DMS 既有核心能力，AFMP 提供對等並現代化（分階段 rollout、即時狀態、防竄改稽核）。

## A. 遠端軟體派送（Remote Software Distribution）

### 功能
1. 套件上傳（含版本、sha256、簽章）→ 物件儲存。
2. 鎖定**機群**（device_group）+ 排程 + 分階段 rollout（分批比例）。
3. 每台狀態追蹤（由 `CommandAck` 驅動）：received→inProgress→succeeded/failed。
4. 錯誤率超閾值自動 `Halted`，可 `RolledBack`（狀態機 `35` §6）。
5. 簽章驗證 + 與白名單聯動（派送後自動更新白名單）。

### 流程
建立派送任務 → 選機群/排程 → 啟動 → 分批下令（`DistributeSoftware`）→ 機端走 REST 下載加密套件 → 安裝 → 回 Ack → 看板顯示進度 → 完成/回滾。

### 畫面
派送任務清單、任務詳情（per 機台進度條）、套件庫、排程行事曆。

## B. 行銷內容推播（Marketing Content Push）

### 功能
1. 內容資產管理（圖/影片/版位）。
2. 行銷活動（campaign）：鎖定機群 + 排程 + 顯示規則（時段/輪播）。
3. 推播（`PushContent`）+ 顯示確認回報。

### 流程
上傳資產 → 建活動 → 選機群/排程 → 推播 → 機端確認顯示 → 看板追蹤覆蓋率。

### 畫面
內容資產庫、活動管理、推播狀態。

## C. 程式白名單（Application Whitelisting）

### 功能（安全控管）
1. 白名單政策：允許執行的程式（hash/path/簽署者）。
2. 推送政策（`UpdateWhitelist`）→ 機端封鎖未授權執行。
3. 機端違規 → `SecurityEvent(whitelistViolation)` → 平台**告警 + 保留違規證據**（合規舉證）。
4. 違規可自動衍生 incident（見 M4）。

### 流程
定義/更新政策 → 推送機群 → 機端 enforce → 違規上報 → 告警 + 稽核留存 + （可選）開事件。

### 畫面
白名單政策管理、違規事件清單（含證據）、政策推送狀態。

## 共用設計

- 皆透過**下行命令 + `CommandAck`**（合約 `20` §4）驅動，狀態機統一（`35` §6）。
- 皆以 `device_group` 鎖定（`31`）。
- 所有變更/推送/違規寫**稽核軌跡**（`30` §3）。

## 對標檢核（vs DMS）

| DMS | AFMP |
|---|---|
| 遠端軟體派送（排程/分群）| ✅ + 分階段 rollout + 自動回滾 + 即時進度 |
| 行銷內容派送 | ✅ + 顯示確認/覆蓋率 |
| 程式白名單（封鎖+告警）| ✅ + 違規證據保留 + 自動開事件 |

## 依賴

- 合約：`DistributeSoftware/PushContent/UpdateWhitelist` + `CommandAck`（`20`）。
- 安全模組（白名單）、Distribution 模組。整合事件：`WhitelistViolation`。
- 安全/合規：`60`、`61`。
