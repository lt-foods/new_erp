---
title: 設備 Agent ↔ 平台 介面合約 v1
module: AFMP / Integration
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Contract, Agent, XFS4IoT, wss, mTLS, Ingestion]
---

# 設備 Agent ↔ 平台 介面合約 v1（Device Agent Contract）

> **本文件是整個系統最關鍵的合約**：所有模組的資料模型與流程都依賴此處定義的訊息。
> 範圍提醒：機端 agent **不在本專案實作範圍**；此合約定義平台所**接收/發送**的訊息，並供[設備模擬器](22-device-simulator-spec.md)與真實 agent 共同遵循。
> 合約**版本化**（`schemaVer`），置於 `src/shared/AFMP.Contracts`。

## 1. 通道設計（對齊 XFS4IoT / CWA 17852）

| 通道 | 協定 | 方向 | 用途 |
|---|---|---|---|
| 控制/遙測面 | **wss（WebSocket Secure）+ JSON**，agent 主動外連 | 雙向 | 心跳、狀態、現金、交易、故障、安全事件；平台下令 |
| 大量傳輸面 | **HTTPS REST（分塊/可續傳）** | 上傳/下載 | EJ 批次上傳、韌體/內容下載（加密壓縮 blob）|
| Legacy 週邊 | **SNMP trap**（adapter）| 上行 | 多廠牌/舊週邊，於 Gateway 正規化為標準事件 |

理由與被否決選項（gRPC 等）見 [ADR-004](../decisions/ADR-004-agent-protocol-wss-json.md)。

## 2. 通用訊息封套（Envelope）

每筆 wss 訊息皆含：

```jsonc
{
  "msgId": "uuid",          // 去重鍵（idempotency）
  "deviceId": "BANK-SITE-ATM001",
  "tenantId": "BANKCODE",
  "type": "Heartbeat|StatusEvent|CashState|Transaction|EjBatchMeta|FaultEvent|SecurityEvent|CommandAck",
  "schemaVer": "1.0",
  "seq": 1024,              // 該機台單調遞增（排序/缺漏偵測）
  "occurredAt": "2026-05-28T03:12:00.123Z",  // 設備時鐘
  "sentAt": "2026-05-28T03:12:00.500Z",
  "payload": { /* 依 type */ }
}
```

- `tenantId` 由 mTLS 憑證綁定驗證，**不信任** payload 自稱。
- `msgId` 去重；`(deviceId, seq)` 用於排序與缺漏偵測（gap → `telemetry_gap` 系統事件）。

## 3. 上行訊息型別（Agent → 平台）

### 3.1 Heartbeat（每 30–60s）
```jsonc
{ "agentVer":"2.3.1", "online":true, "clockSkewMs":120, "uptimeSec":864000 }
```
- 缺心跳 N 次 → 平台判 `Offline`（見狀態機）。

### 3.2 StatusEvent（模組狀態變化）
```jsonc
{
  "module":"dispenser|depositor|cardReader|epp|receipt|network|supervisorDoor",
  "state":"ok|warn|fault|offline",
  "prevState":"ok",
  "vendorCode":"H-DSP-0042",      // 原廠碼（保留）
  "detail":"shutter sensor blocked"
}
```

### 3.3 CashState（現金水位，快照 + 差異）
```jsonc
{
  "mode":"snapshot|delta",
  "cassettes":[
    {"cassetteId":"C1","kind":"dispense|deposit|recycle|reject",
     "denom":1000,"currency":"TWD","count":1850,"capacity":2500,
     "status":"ok|low|empty|full|jam"}
  ]
}
```

### 3.4 Transaction（逐筆交易）
```jsonc
{
  "txnType":"withdrawal|deposit|inquiry|transfer|reversal",
  "amount":3000,"currency":"TWD",
  "denomBreakdown":[{"denom":1000,"qty":3}],
  "responseCode":"00",
  "rrn":"612345678901","stan":"004321",
  "cardToken":"tkn_9f3a...",        // ★ 已於機端代碼化/遮罩（PCI）
  "channel":"onus|interbank",
  "result":"approved|declined|reversed"
}
```
> **合約硬性要求**：卡號（PAN）**必須**在機端代碼化/遮罩後才上傳；平台不接受、不儲存明文 PAN（縮小 PCI 範圍，見 `06-nfr-compliance/60`）。

### 3.5 EjBatchMeta（+ REST 上傳）
```jsonc
{ "batchId":"ej_20260528_001","timeRange":["...","..."],
  "lineCount":1280,"sha256":"...","sizeBytes":824311,"enc":"aes-256-gcm","comp":"zstd",
  "uploadUrlHint":"/ingest/ej/{batchId}" }
```
- meta 走 wss；blob 本體走 REST（分塊/可續傳）上傳到物件儲存。

### 3.6 FaultEvent
```jsonc
{ "faultCode":"DSP_JAM","component":"dispenser","severity":"critical|major|minor",
  "vendorCode":"H-ERR-118","detail":"note jam at escrow" }
```

### 3.7 SecurityEvent（白名單/竄改/門禁/設定漂移）
```jsonc
{ "kind":"whitelistViolation|tamper|doorOpen|configDrift|usbInsert",
  "subject":"C:\\unknown.exe","action":"blocked|allowed|detected","detail":"hash mismatch" }
```

### 3.8 CommandAck（對下令的回應）
```jsonc
{ "commandId":"cmd_abc","status":"received|inProgress|succeeded|failed",
  "code":"OK|ERR_DISK|ERR_VERIFY","detail":"..." }
```

## 4. 下行訊息型別（平台 → Agent）

| Command | payload 重點 | 對應 Ack 生命週期 |
|---|---|---|
| `DistributeSoftware` | packageId, version, downloadUrl, sha256, schedule | received→inProgress→succeeded/failed |
| `PushContent` | campaignId, assets[], schedule, displayRule | received→succeeded/failed |
| `UpdateConfig` | configKey/value set, applyAt | received→succeeded/failed |
| `UpdateWhitelist` | policyId, entries[](hash/path/signer), mode | received→succeeded/failed |
| `RequestEjUpload` | timeRange / batchId | received→inProgress→succeeded |
| `RunDiagnostic` / `Reboot` | target, level | received→succeeded/failed |

- 每個下令有唯一 `commandId`；平台依 `CommandAck` 更新派送/設定/工單狀態。
- 下令送達需 agent 線上；離線時排隊，待上線重送（at-least-once + 去重）。

## 5. 設備身分、納管與安全

- **傳輸**：wss 與 REST 皆 **mTLS**；每台 ATM 持唯一 client 憑證。
- **納管（Provisioning）**：bootstrap token → CSR → 內部 CA 簽發**短期憑證**；定期輪替；長期對齊 **TR-34** 金鑰配送（視 Hitachi/硬體支援）。
- **綁定**：Gateway 驗證 `(憑證指紋 ↔ deviceId ↔ tenantId)`，不符即拒。
- **限流**：per-device token bucket（Redis），防單台異常/被入侵灌爆。
- **PII**：見 3.4，卡號機端代碼化。

## 6. 傳遞語意（Delivery Semantics）

| 屬性 | 規範 |
|---|---|
| 上行可靠度 | at-least-once；平台以 `(deviceId,msgId)` 去重 |
| 排序 | per-device `seq` 單調；跨機台不要求排序 |
| 缺漏 | seq gap → 平台補拉（`RequestEjUpload`/狀態快照）並記 `telemetry_gap` |
| 冪等 | 所有處理器冪等（upsert-by-key；ledger append 以 `(deviceId,seq)` 防重）|
| 時鐘 | 以 `occurredAt`（設備）為事件時間，`clockSkewMs` 校正；平台落地另記 `receivedAt` |
| 背壓 | wss credit 流控 + Gateway bounded channel；超載仍寫 inbound log 不丟（見 `21`）|

## 7. 版本化與相容

- `schemaVer` 採語意化；平台同時支援 **N 與 N-1**。
- 合約以 JSON Schema 定義於 `AFMP.Contracts`，並有**一致性測試**（`AFMP.Contracts.ConformanceTests`）：模擬器/agent 樣本訊息須通過 schema 驗證。
- 破壞性變更須出新 major 並提供過渡期雙版本並行。

## 8. 訊息 ↔ 模組消費對照（自洽檢查）

| 訊息 | 主要消費模組 |
|---|---|
| Heartbeat / StatusEvent | Devices（狀態）、Maintenance（衍生故障）|
| CashState | Cash、Forecasting |
| Transaction | Transactions（監控/對帳）、Cash（出鈔扣帳）|
| EjBatchMeta + blob | Transactions（EJ viewer/對帳）|
| FaultEvent | Maintenance（事件/工單）|
| SecurityEvent | Security（白名單）、Maintenance、Notifications |
| CommandAck | Distribution / Security / Maintenance（對應下令）|

> 驗收：上表每個上行型別都有歸宿，每個下令都有 `CommandAck` 生命週期——確保合約自洽、無孤兒訊息。
