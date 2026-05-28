---
title: 設備模擬器規格
module: AFMP / Integration
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Simulator, Demo, LoadTest, Contract]
---

# 設備模擬器規格（Device Simulator）

> 由於真實 ATM agent 與硬體不在實作範圍，**設備模擬器是本環境唯一能端到端展示與壓測平台的方式**，列為一級交付物。
> 模擬器實作與真實 agent **相同的[介面合約 v1](20-device-agent-contract-v1.md)**（wss+mTLS+REST），平台無法分辨來源——因此平台可在無硬體下被完整驗證。

## 1. 目標

1. **Demo**：對 NOC/現金/維修看板呈現逼真的機隊行為。
2. **壓測**：驗證攝取吞吐（數千～數萬台、目標 50–80k msg/s）。
3. **流程驗證**：故障→事件→工單、低水位→補鈔、缺漏→補拉、白名單違規→告警。
4. **合約一致性**：模擬器送出的訊息須通過 `AFMP.Contracts` 的 JSON Schema。

## 2. 形式

- 獨立 .NET console/worker：`simulator/AFMP.Simulator`（未來與平台同 repo 根 `atm-dms/`）。
- 驅動 N 台合成 ATM，各自持模擬 client 憑證（由本機測試 CA 簽發），連到 Gateway。

## 3. 場景腳本（YAML 範例）

```yaml
fleet:
  tenantId: DEMOBANK
  devices: 2000
  region: [台北, 新北, 桃園, 台中, 高雄]
  models: [Hitachi-AR, Hitachi-RT, NCR-SS]
behaviors:
  heartbeatSec: 45
  txnRatePerMin: { withdrawal: 6, inquiry: 3, deposit: 1 }
  cash:
    startLevelPct: 80
    dispenseDrainRate: realistic   # 依交易扣鈔
scenarios:
  - name: 連假提領潮
    at: "+0m"; effect: txnRate x2.5; duration: 4h
  - name: 缺鈔
    devices: 30; effect: cassette.empty(denom=1000); at:"+30m"
  - name: 故障注入
    devices: 10; effect: fault(DSP_JAM, critical); at:"+10m"
  - name: 離線抖動
    devices: 15; effect: flap(offline 2m / online 5m); at:"+5m"
  - name: 白名單違規
    devices: 3; effect: securityEvent(whitelistViolation); at:"+20m"
  - name: EJ 產生
    all: true; effect: ejBatch(every=1h)
```

## 4. 可模擬之合約訊息

涵蓋全部上行型別：Heartbeat、StatusEvent、CashState（含扣鈔聯動）、Transaction（含面額拆解 + 代碼化 cardToken）、EjBatchMeta + REST 上傳、FaultEvent、SecurityEvent、CommandAck。
並能**接收下行命令**並回 `CommandAck`（模擬軟體派送/內容/設定/白名單/重啟流程）。

## 5. 真實感模型

- 交易量依**時段曲線**（上班前/午休/下班/假日）。
- 出鈔扣鈔與 `CashState` 一致（交易→鈔匣計數遞減→低水位）。
- 面額分佈、拒鈔率、卡故障率可參數化。
- 時鐘偏移注入（驗 `clockSkewMs` 校正）、seq gap 注入（驗缺漏補拉）。

## 6. 與 CI / POC 的整合

- **合約一致性測試**：CI 跑模擬器樣本訊息 → schema 驗證 + 平台處理 smoke test。
- **POC 驗收腳本**（見 `07-delivery` 驗證）：
  1. 起 2k 台 → 看板即時上線、地圖佈點。
  2. 注入故障 → 事件台出現事件 → 自動派工 → 行動工單可接。
  3. 觸發缺鈔 → 現金總覽告警 → 產生補鈔建議單。
  4. 連假潮 → 預測模組需求上升 → 補鈔排程反映。
  5. 白名單違規 → 安全告警 + 稽核留存。

## 7. 非目標

- 不模擬真實 XFS/硬體驅動、不模擬實體鈔票、不取代真實 agent 的安全強度——僅在**合約層**等價，用於平台側驗證與展示。
