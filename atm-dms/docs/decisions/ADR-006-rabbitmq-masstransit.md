---
title: ADR-006 訊息匯流排 RabbitMQ + MassTransit
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, Messaging, RabbitMQ, MassTransit, Kafka]
---

# ADR-006：訊息匯流排採 RabbitMQ + MassTransit

## 狀態
Accepted（draft-v1）

## 背景
需在攝取與運算間解耦、可靠發布整合事件（Outbox）、支援競爭消費與重試；多為 on-prem 部署。

## 決策
採 **RabbitMQ**（叢集 + quorum queue）為 broker，**MassTransit** 為 .NET 抽象（提供 outbox、retry、saga、dead-letter）。

## 被否決 / 延後選項
- **Kafka**：高吞吐 + 長期重播強，但營運較重、on-prem 門檻高。**延後**：當持續攝取 >~100k msg/s 或需長期事件重播時再評估；MassTransit 提供遷移路徑。
- Azure Service Bus：雲鎖定，on-prem 不適。

## 理由
- on-prem 最易營運、團隊熟悉度高。
- MassTransit 抽象 broker，未來可換 Kafka 降低重寫。
- v1 量級 RabbitMQ 足夠。

## 取捨
- RabbitMQ 不適合長期事件重播（以 inbound log 補足重建來源，見 `21`）。

## 影響
- 攝取/HA（`21`）、解決方案（`11`）、擴展（`62`）。
