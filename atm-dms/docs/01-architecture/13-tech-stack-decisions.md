---
title: 技術選型總表
module: AFMP / Architecture
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [TechStack, .NET, Decisions]
---

# 技術選型總表（Tech Stack Decisions）

> 原則：以 **.NET** 為核心、以**單一資料引擎**降低 on-prem 營運門檻、以成熟可自架元件滿足金融落地需求。各重大決策另有 ADR。

| 關注點 | 選擇 | 理由 / 取捨 | ADR |
|---|---|---|---|
| Framework | **.NET 9 / ASP.NET Core** | 現行、效能佳、長期支援 | — |
| API 風格 | 管理 API 用 **Controllers**；攝取/health/webhook 用 **Minimal API** | Controllers 的 filter/版本化適合龐大 CRUD；Minimal API 低負擔適合熱路徑 | — |
| 資料存取 | **EF Core**（CRUD/生命週期）+ **Dapper**（熱讀/對帳/報表）| EF 生產力 + migration；Dapper 高量讀 | — |
| 主資料庫 | **PostgreSQL + TimescaleDB** | 單引擎兼關聯式 + 時序；複雜查詢/地理勝 Influx；避免大規模 SQL Server 授權成本。SQL Server 為銀行強制時 fallback（EF provider 抽象）| [ADR-003](../decisions/ADR-003-postgres-timescale.md) |
| 時序儲存 | TimescaleDB hypertable + continuous aggregate + retention | 遙測/水位/交易指標，免第二套 DB | [ADR-003](../decisions/ADR-003-postgres-timescale.md) |
| 即時推送 | **SignalR**（Redis backplane）| 原生 .NET，驅動看板與機端控制面 | — |
| 訊息匯流排 | **MassTransit + RabbitMQ** | on-prem 最易營運；outbox/retry/saga；>~100k msg/s 才評估 Kafka | [ADR-006](../decisions/ADR-006-rabbitmq-masstransit.md) |
| 背景作業 | **Hosted Services**（流處理）+ **Hangfire**（排程/可復原）| Hangfire 有持久化 + 儀表板，適合對帳/派送/預測排程；cron 複雜化再考慮 Quartz | — |
| 快取 | **Redis** | 快取、SignalR backplane、限流、去重鍵 | — |
| 物件儲存 | **MinIO**（on-prem）/ S3 相容 | EJ、韌體、內容 blob | — |
| 秘密/金鑰 | **HashiCorp Vault**（on-prem）/ Key Vault | 秘密、金鑰輪替 | — |
| ML | **ML.NET in-process**（v1）；Python/MLflow sidecar（v2 選配）| v1 留在 .NET；為資料科學團隊預留 | — |
| 前端 | **React + TypeScript** + MapLibre/Leaflet + 圖表庫 | 互動地圖/即時 UI 生態、人才、團隊既有 TS/React；Blazor Server 在地圖/圖表生態與連線成本不利 | [ADR-005](../decisions/ADR-005-react-frontend.md) |
| 行動（外勤）| **React Native** | 共用 web 技術/技能；接工單 API + push | — |
| API 閘道/代理 | **YARP**（in-.NET）或 NGINX | TLS 終結、路由、限流 | — |
| 認證 | OIDC/OAuth2（**Duende IdentityServer** 自架 或 銀行 IdP 聯邦）| on-prem 可自主；可聯邦 AD | — |
| 觀測性 | **OpenTelemetry** + Serilog + Prometheus/Grafana | trace/metric/log 一致 | — |
| 容器/編排 | Docker + **Kubernetes**（SaaS）/ Compose（小型 on-prem）| 配合銀行成熟度 | — |
| CI/CD | GitHub Actions / Azure DevOps + Helm | blue-green/滾動 | — |
| IaC | Terraform（雲）+ Ansible（on-prem）| 兩拓撲皆可重現 | — |

## 關鍵取捨說明

- **模組化單體 vs 微服務**：v1 選單體，降低 on-prem 認證/稽核/營運複雜度；保留 Ingestion Gateway 可拆。詳 [ADR-002](../decisions/ADR-002-modular-monolith.md)。
- **PostgreSQL+Timescale vs SQL Server / InfluxDB**：一套引擎處理關聯式 + 時序，省授權、省營運；銀行強制時以 EF provider 切回 SQL Server。
- **RabbitMQ vs Kafka**：v1 量級 RabbitMQ 足夠且易營運；超大規模/長期重播需求再評估 Kafka（MassTransit 提供遷移路徑）。
- **React vs Blazor**：互動地圖/即時儀表板生態與人才取向 React。
- **gRPC 不用於機端邊界**：行內防火牆/代理摩擦、瀏覽器/legacy 工具弱；機端走 wss+JSON（對齊 XFS4IoT），gRPC 僅保留給未來內部服務間。
