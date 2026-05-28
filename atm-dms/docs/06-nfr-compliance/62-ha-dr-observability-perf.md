---
title: HA / DR / 觀測性 / 效能
module: AFMP / NFR
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [HA, DR, Observability, Performance, SLO]
---

# HA / DR / 觀測性 / 效能

## 1. 可用性目標

- **平台控制平面 99.9%**。
- app 層 **active-active** 多副本（無狀態）。
- 機端攝取：inbound log + agent at-least-once + 去重 → **故障切換不丟遙測**（見 `21`）。

## 2. DR

| 指標 | 目標 |
|---|---|
| RTO | ≤ 1 小時 |
| RPO | ≤ 5 分鐘 |
| DB | 主 + 同步副本（Patroni 自動切換）+ 非同步 DR 副本（異地）|
| 訊息 | RabbitMQ 叢集 + quorum queue |
| blob | MinIO 分散式 + 異地備援 |
| 備援演練 | 定期切換演練 + runbook |

## 3. 觀測性（Observability）

- **OpenTelemetry**：trace / metric / log 一致；跨 Gateway→Bus→Workers 追蹤。
- **Serilog** 結構化日誌（含 correlationId、tenantId、deviceId；不含敏感值）。
- **Prometheus + Grafana**：系統與業務指標。
- **Health checks**：各容器 liveness/readiness。
- **關鍵 SLO 儀表板**：機端連線率、攝取延遲、佇列積壓、投影落後、DB 複寫延遲。

## 4. 效能與規模設計點

| 指標 | 設計點 |
|---|---|
| 機台數 | 2 萬/租戶（彙總可更多）|
| 攝取吞吐 | 50–80k msg/s 持續、150k 突發 |
| EJ 量 | 每日數十 GB（走 REST + 物件儲存）|
| 看板查詢 | < 2s（projection + continuous aggregate + Redis）|
| 攝取延遲 | 收件→ACK 低延遲；收件→看板秒級 |

## 5. 擴展策略

- **Ingestion Gateway** 無狀態，依連線數水平擴展（單 wss sticky 到一實例）。
- **Workers** 競爭消費，依佇列積壓水平擴展。
- **DB**：Timescale 時間分區 + continuous aggregate 控查詢成本；讀副本分流報表。
- 超大規模再評估：拆出 Gateway 為獨立服務、RabbitMQ→Kafka（見 `13`/ADR-002/006）。

## 6. 容量與成本

- Timescale retention：原始 inbound 短期、彙總長存，控存儲成本。
- on-prem 小型：Compose 單機可降門檻（犧牲部分 HA），大型走 K8s 叢集。

## 7. 韌性模式

- 冪等處理、Outbox、重試 + 退避、熔斷（外部介接）、bounded queue 背壓、毒訊息隔離（dead-letter）。
