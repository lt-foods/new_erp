---
title: 分階段交付 Roadmap
module: AFMP / Delivery
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Roadmap, Delivery, Phases]
---

# 分階段交付 Roadmap

## Phase 0 — 基礎（Foundations）

- Solution 骨架（模組化單體，見 `11`）。
- 租戶模型 + Auth/RBAC + 稽核（hash chain）。
- 持久化：PostgreSQL + TimescaleDB；Outbox。
- 訊息匯流排（MassTransit + RabbitMQ）。
- **agent 介面合約 v1.0**（`20`）+ **設備模擬器**（`22`）。
- Ingestion Gateway MVP（攝取 + inbound log + ACK）。
- CI/CD + 觀測性骨架。

## Phase 1 — v1 MVP（四模組基線）

依序但可部分並行：

1. **M1 機台/狀態**：主檔 + 即時看板 + 地圖 + 上下線。
2. **M4 故障/工單**：故障→事件→工單→手動+自動派工 + SLA + 通知（**無傳真**）。
3. **M2 現金/補鈔**：水位 + 低水位告警 + 手動補鈔 + CIT 協作 + **SARIMA 統計預測**。
4. **M3 交易/對帳**：交易流 + EJ viewer + 日結 + **三方對帳** + 差錯佇列。
5. **跨模組**：軟體派送、內容推播、白名單、通知/升級引擎、核心報表、**金管會異常通報工作流**。

**v1 完成定義（DoD）**：四模組可用 + 模擬器端到端 POC 通過（見驗證）+ 對標 DMS 功能皆有對等。

## Phase 2 — v2+

- **ML 現金預測**（XGBoost + 機台分群）+ 補鈔最佳化。
- 進階分析 / 重複故障 ML。
- **行動外勤 app**（整合/取代外勤筋斗雲）。
- **即時異常交易監控**（INETCO 式，含詐欺/現金）。
- 多廠牌 SNMP adapter 廣度。
- Kafka 遷移（視規模）。
- 自助報表產生器。
- 預測性維護。

## Phase 3 — 平台化

- 開放 API / 整合市集。
- 跨銀行標竿（MDS 加值，匿名彙總）。
- 金管會**零信任**強化。

## 相依與里程碑

```
Phase0 合約+模擬器 ──► Phase1 各模組（依合約訊息）
M1 先行（看板基礎）► M4（依 M1 狀態/故障）
M2 與 M3 可並行（皆依攝取）；M3 需 Switch/Core 介接（開放問題 Q2）
跨模組（派送/白名單/通知）貫穿
```

## 風險緩衝

- 合約（`20`）需最早凍結並以模擬器驗證 → 降低後續返工。
- Switch/Core 介接能力未定 → M3 對帳先以 EJ + 批次檔啟動，即時介接後補。
