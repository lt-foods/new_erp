---
title: AFMP 架構藍圖 — 文件索引
module: AFMP
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ATM, AFMP, DMS, 金融自動化, 架構藍圖, .NET]
---

# AFMP 架構藍圖 — 文件索引

對標 MDS 三商電腦 DMS、以 .NET 為核心的銀行 ATM 機隊監控管理平台之**完整規格與架構藍圖**。
範圍：僅設計**中央管理平台本體**；機端 agent 以**介面合約**定義，並規劃**設備模擬器**供開發/展示。

## 文件地圖

| 區 | 檔案 | 內容 |
|---|---|---|
| 00 概觀 | [00-vision-and-goals](00-overview/00-vision-and-goals.md) | 願景、定位、業務目標 |
| | [01-stakeholders-and-kpis](00-overview/01-stakeholders-and-kpis.md) | 利害關係人、KPI |
| | [02-glossary-中英對照](00-overview/02-glossary-中英對照.md) | 術語中英對照 |
| 01 架構 | [10-c4-context-and-containers](01-architecture/10-c4-context-and-containers.md) | C4 L1/L2 |
| | [11-dotnet-solution-structure](01-architecture/11-dotnet-solution-structure.md) | .NET 解決方案結構 |
| | [12-deployment-topology-onprem-saas](01-architecture/12-deployment-topology-onprem-saas.md) | 部署拓撲 |
| | [13-tech-stack-decisions](01-architecture/13-tech-stack-decisions.md) | 技術選型總表 |
| 02 整合 | [20-device-agent-contract-v1](02-integration/20-device-agent-contract-v1.md) | **agent↔平台合約（最關鍵）** |
| | [21-ingestion-and-ha](02-integration/21-ingestion-and-ha.md) | 攝取與高可用 |
| | [22-device-simulator-spec](02-integration/22-device-simulator-spec.md) | 設備模擬器 |
| | [23-recon-feeds-iso8583-core](02-integration/23-recon-feeds-iso8583-core.md) | 對帳介接 ISO 8583/Core |
| 03 資料模型 | [30-cross-cutting-and-tenancy](03-data-model/30-cross-cutting-and-tenancy.md) | 跨模組/租戶 |
| | [31-module1-devices](03-data-model/31-module1-devices.md) | 機台 |
| | [32-module2-cash](03-data-model/32-module2-cash.md) | 現金 |
| | [33-module3-transactions](03-data-model/33-module3-transactions.md) | 交易/對帳 |
| | [34-module4-maintenance](03-data-model/34-module4-maintenance.md) | 故障/工單 |
| | [35-state-machines](03-data-model/35-state-machines.md) | **狀態機** |
| 04 模組 | [40-devices-functional-spec](04-modules/40-devices-functional-spec.md) | 機台功能規格 |
| | [41-cash-functional-spec](04-modules/41-cash-functional-spec.md) | 現金功能規格 |
| | [42-transactions-functional-spec](04-modules/42-transactions-functional-spec.md) | 交易功能規格 |
| | [43-maintenance-functional-spec](04-modules/43-maintenance-functional-spec.md) | 維修功能規格 |
| | [44-distribution-content-whitelisting](04-modules/44-distribution-content-whitelisting.md) | 派送/內容/白名單 |
| 05 跨模組 | [50-authn-authz-rbac](05-cross-cutting/50-authn-authz-rbac.md) | 認證授權 RBAC |
| | [51-notification-escalation-engine](05-cross-cutting/51-notification-escalation-engine.md) | 告警通知引擎 |
| | [52-cash-forecasting](05-cross-cutting/52-cash-forecasting.md) | 現金預測 |
| | [53-reporting-analytics](05-cross-cutting/53-reporting-analytics.md) | 報表分析 |
| 06 NFR/合規 | [60-security-pci](06-nfr-compliance/60-security-pci.md) | 安全/PCI |
| | [61-fsc-金管會-compliance](06-nfr-compliance/61-fsc-金管會-compliance.md) | 金管會合規 |
| | [62-ha-dr-observability-perf](06-nfr-compliance/62-ha-dr-observability-perf.md) | HA/DR/觀測/效能 |
| 07 交付 | [70-roadmap](07-delivery/70-roadmap.md) | 分階段 roadmap |
| | [71-risks-assumptions-openquestions](07-delivery/71-risks-assumptions-openquestions.md) | 風險/假設/開放問題 |
| 決策 | [ADR-001](decisions/ADR-001-multitenancy-hosting.md) … [ADR-006](decisions/ADR-006-rabbitmq-masstransit.md) | 架構決策紀錄 |

## 驗收清單

- [ ] 四模組各有：資料模型 + 功能規格 + 狀態機
- [ ] agent 合約每個訊息型別都在某模組被消費；下令型別都有 `CommandAck`
- [ ] 逐項對照 DMS 功能皆有對等或更佳設計
- [ ] 六份 ADR 齊備
- [ ] 含中英對照詞彙表
