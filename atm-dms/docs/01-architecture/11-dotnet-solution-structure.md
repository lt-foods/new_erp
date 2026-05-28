---
title: .NET 解決方案結構
module: AFMP / Architecture
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [.NET, Solution, ModularMonolith, MediatR]
---

# .NET 解決方案結構（Solution Structure）

採**模組化單體**（決策見 [ADR-002](../decisions/ADR-002-modular-monolith.md)）。單一可部署主機，模組邊界以獨立 project 隔離，模組間**不共用 entity**，僅透過 **MediatR 指令/查詢** 與**內部整合事件**通訊。

## 1. Solution 佈局（`AFMP.sln`）

```
src/
  AFMP.Host                  # 組合根：管理 API（Controllers）+ SignalR
  AFMP.IngestionGateway      # 獨立程序：device wss/mTLS + REST → 匯流排
  AFMP.Workers               # 背景主機：流處理、排程、對帳批次、告警評估

  modules/
    Devices/                 # 機台主檔與狀態監控
    Cash/                    # 現金庫存與補鈔
    Transactions/            # 交易監控與對帳
    Maintenance/             # 故障告警與維修工單
    Distribution/            # 遠端軟體派送 + 行銷內容推播
    Security/                # 程式白名單 / 設備身分
    Notifications/           # 告警通知引擎
    Forecasting/             # 現金預測（ML.NET）

  shared/
    AFMP.SharedKernel         # TenantId、稽核、ValueObject、Result<T>、Clock
    AFMP.Contracts            # ★ device 介面合約 DTO/schema（版本化）
    AFMP.Messaging            # MassTransit 設定、整合事件定義
    AFMP.Persistence          # EF Core、Timescale 存取、Outbox、Migration
    AFMP.Telemetry            # OpenTelemetry 接線

tests/
  AFMP.ArchitectureTests      # 模組邊界守則（禁跨模組 entity 參照）
  AFMP.<Module>.Tests
  AFMP.Contracts.ConformanceTests  # 模擬器/agent 合約一致性
```

## 2. 單一模組的內部分層（每個 modules/<X>）

```
modules/Devices/
  Devices.Domain/            # 實體、聚合、ValueObject、Domain Event、狀態機
  Devices.Application/       # MediatR Commands/Queries/Handlers、介面（port）
  Devices.Infrastructure/    # EF 設定、repo 實作、外部 adapter
  Devices.Endpoints/         # API endpoints（Controller 或 Minimal）、SignalR Hub
```

- **Domain**：純領域，無框架相依。狀態機（見 `03-data-model/35`）在此。
- **Application**：用 MediatR 處理用例；定義 port（介面），由 Infrastructure 實作。
- **Infrastructure**：EF Core `IEntityTypeConfiguration`、Dapper 查詢、外部系統 adapter。
- **Endpoints**：HTTP/SignalR 入口，薄層轉呼 Application。

## 3. 模組間通訊規則（守則）

1. 模組**不得**參照他模組的 Domain/Infrastructure。
2. 同步呼叫：透過 `AFMP.Contracts` 中公開的 **MediatR 請求介面**（公開合約）。
3. 非同步：透過 `AFMP.Messaging` 發布**整合事件**（如 `DeviceWentOffline`, `CashBelowThreshold`, `FaultRaised`）。
4. **架構測試**（`AFMP.ArchitectureTests`，用 NetArchTest/ArchUnitNET）於 CI 強制上述邊界。

### 代表性整合事件

| 事件 | 發布模組 | 訂閱模組 |
|---|---|---|
| `DeviceStatusChanged` | Devices | Maintenance, Notifications |
| `CashLevelUpdated` | Cash | Forecasting, Notifications |
| `CashBelowThreshold` | Cash | Maintenance(可選), Notifications |
| `FaultRaised` | Devices/Maintenance | Maintenance, Notifications |
| `IncidentSlaBreachImminent` | Maintenance | Notifications |
| `ReconExceptionFound` | Transactions | Notifications |
| `WhitelistViolation` | Security | Maintenance, Notifications |

## 4. 組合根（Composition Root）

- `AFMP.Host` 啟動時，各模組以 `IModule.Register(IServiceCollection, IConfiguration)` 自我註冊（DI、EF 設定、endpoint、consumer）。
- 三個可部署單元（Host / IngestionGateway / Workers）**共用同一組模組組件**，但啟用不同的「角色」：
  - Host：API + SignalR + 讀模型。
  - IngestionGateway：只載入 `AFMP.Contracts` + `AFMP.Messaging` + 攝取管線。
  - Workers：consumer、排程、對帳、預測、告警評估。

## 5. 為何「可拆出 Ingestion Gateway」是設計重點

- 機端連線（數萬 wss）與管理 API 的擴展曲線、可用性、攻擊面完全不同。
- 把 Gateway 做成獨立程序（但同 solution、同合約）→ 之後要獨立水平擴展或拆成獨立服務時，**零重寫**，只需調整部署。

## 6. 持久化與 Migration

- `AFMP.Persistence` 集中管理 `DbContext`（每模組可有自己的 `DbContext`，共用同一連線/schema）。
- Migration 以 EF Core 管理；TimescaleDB hypertable 與 continuous aggregate 以 SQL migration 補充。
- 全表 `TenantId` + EF **global query filter**（見 `03-data-model/30`）。
