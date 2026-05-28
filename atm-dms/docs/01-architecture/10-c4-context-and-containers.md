---
title: C4 — 系統情境與容器視圖
module: AFMP / Architecture
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [C4, Architecture, Context, Container]
---

# C4 — 系統情境與容器視圖

## L1 — 系統情境（Context）

```
            ┌──────────────────────────────────────────────────────┐
            │                  AFMP 平台（本系統）                    │
            │     ATM 機隊監控管理（Devices/Cash/Txn/Maintenance）    │
            └──────────────────────────────────────────────────────┘
   ▲ wss+mTLS (telemetry/status/EJ/txn/command)   ▲ HTTPS/SignalR
   │ HTTPS REST (EJ/firmware/content bulk)         │
┌──┴───────────────┐                          ┌────┴───────────────┐
│  ATM/AVM 機隊     │                          │  使用者（Web/行動）  │
│  (機端 Agent)     │                          │  NOC/現金組/外勤/稽核 │
└──────────────────┘                          └────────────────────┘
   ▲ ISO 8583 / batch          ▲ settlement feed        │ orders/confirm
┌──┴────────────┐   ┌──────────┴────────┐   ┌───────────┴──────────┐
│ 金融轉接 Switch │   │ 核心系統 Core Bank │   │  CIT 運鈔系統          │
└───────────────┘   └───────────────────┘   └──────────────────────┘
            │ 多通道通知（push/IM/email/SMS/voice）
   ┌────────┴─────────────────────────────────────────┐
   │  通知閘道（FCM/APNs, LINE/Teams, SMTP, SMS, Voice）  │
   └──────────────────────────────────────────────────┘
```

**外部系統**
- ATM/AVM 機隊（機端 agent）：唯一資料源頭，雙通道（wss 控制/遙測 + REST 大量傳輸）。
- Switch（ISO 8583）/ Core Banking：對帳用交易與入帳資料。
- CIT 運鈔系統：補鈔單下達與裝鈔確認。
- 通知閘道：多通道告警送出。
- 銀行 IdP/AD：SSO 聯邦（選配）。

## L2 — 容器視圖（Containers）

```
┌───────────────────────────── AFMP 部署單元 ─────────────────────────────┐
│                                                                          │
│  ┌──────────────┐   ┌────────────────────┐   ┌──────────────────────┐   │
│  │ 反向代理/閘道  │   │ Ingestion Gateway   │   │  Web/API Host        │   │
│  │ (YARP/NGINX) │   │ (wss/mTLS, REST)    │   │ (ASP.NET Core + SignalR)│ │
│  └──────┬───────┘   └─────────┬──────────┘   └──────────┬───────────┘   │
│         │                     │ inbound log              │               │
│         │            ┌────────▼─────────┐                │               │
│         │            │  Message Bus      │◄───────────────┤               │
│         │            │  (RabbitMQ)       │                │               │
│         │            └────────┬─────────┘                │               │
│         │                     │                          │               │
│  ┌──────▼──────────┐  ┌───────▼──────────┐   ┌───────────▼───────────┐   │
│  │  前端 (React SPA) │  │  Workers          │   │  Forecasting (ML.NET) │   │
│  │  /行動 RN        │  │ (Hosted+Hangfire) │   │                       │   │
│  └─────────────────┘  └───────┬──────────┘   └───────────────────────┘   │
│                               │                                          │
│  ┌─────────────┐  ┌───────────▼────────────┐  ┌──────────┐  ┌─────────┐  │
│  │   Redis      │  │ PostgreSQL + Timescale │  │  MinIO   │  │  Vault  │  │
│  │ cache/backplane│ │ 關聯式 + 時序           │  │ blob(EJ/韌體)│ │ 秘密   │  │
│  └─────────────┘  └────────────────────────┘  └──────────┘  └─────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 容器清單

| 容器 | 技術 | 職責 |
|---|---|---|
| 反向代理/閘道 | YARP / NGINX | TLS 終結、路由、限流 |
| **Ingestion Gateway** | ASP.NET Core（獨立程序）| 終結 wss/mTLS、驗證、寫 inbound log、發布到匯流排；REST 大量傳輸 |
| Web/API Host | ASP.NET Core + SignalR | 管理 API、即時推送、前端服務 |
| Workers | Hosted Services + Hangfire | 流處理、對帳批次、派送、預測排程、告警評估 |
| Forecasting | ML.NET（v1 in-process）| 現金需求預測 |
| 前端 | React + TS | 看板/地圖/工作台 |
| 行動 | React Native | 外勤工單 |
| PostgreSQL + TimescaleDB | — | 主檔/生命週期 + 時序 |
| Redis | — | 快取、SignalR backplane、限流、去重 |
| RabbitMQ | — | 內部事件匯流排（MassTransit）|
| MinIO/S3 | — | EJ/韌體/內容 blob |
| Vault | HashiCorp / Key Vault | 秘密、金鑰 |

> Ingestion Gateway 是**唯一對外（機端）開放**、且擴展/可用性需求最特殊者，因此在 v1 即設計為**獨立程序**，可於需要時水平擴展或拆出為獨立服務而不需重寫（見 ADR-002）。

## 關鍵資料流

1. **遙測攝取**：Agent → Gateway（驗證+inbound log+ACK）→ RabbitMQ → Workers 投影到狀態/現金/交易表 → SignalR 推前端。
2. **下令**：使用者/排程 → API → 命令佇列 → Gateway → Agent → `CommandAck` 回流。
3. **對帳**：Switch/Core feed → Workers 正規化 → 三方比對 → 例外佇列。
4. **告警→工單**：事件 → 規則引擎 → 通知引擎 + 事件/工單建立 → 派工 → 行動 app。
