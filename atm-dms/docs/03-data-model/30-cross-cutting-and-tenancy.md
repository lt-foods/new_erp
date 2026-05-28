---
title: 資料模型 — 跨模組與多租戶
module: AFMP / DataModel
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [DataModel, Tenancy, Audit, Outbox, Append-only]
---

# 資料模型：跨模組與多租戶

## 1. 全域設計模式

| 模式 | 規範 |
|---|---|
| **租戶欄位** | 每張業務表皆有 `tenant_id`；EF Core **global query filter** 強制隔離 |
| **附加式 ledger / 事件流** | 狀態、現金、交易/EJ、事件生命週期皆 append-only（不可變、可回溯、可重算）|
| **現況投影** | 可變的「現況表」是事件流的投影，可由 ledger 重建 |
| **Transactional Outbox** | 業務寫入與整合事件發布同一交易，確保一致 |
| **時序** | 高頻資料（狀態/水位/交易指標）入 TimescaleDB hypertable + continuous aggregate + retention |
| **稽核** | 特權操作寫 `audit_log`（hash chain 防竄改）|
| **軟刪除** | 主檔用 `status`/`is_active`，不實體刪除（稽核可追溯）|

通用稽核欄位：`created_at, created_by, updated_at, updated_by, tenant_id, version(樂觀鎖)`。

## 2. 租戶與身分（核心表）

```
Tenant（銀行）           1───* User
  id (=tenantId)              id, tenant_id, idp_subject, name, email, status, mfa_enabled
  code, name, type            
  hosting(saas|onprem)   Role 1───* RolePermission *───1 Permission
  data_region                 id, tenant_id, name        id, key（如 device.read）
  status                 UserRole（user×role，可帶 resource scope: region/site）
```

- 角色與權限詳見 `05-cross-cutting/50-authn-authz-rbac.md`。
- `UserRole` 可附**資源範圍**（region/site）→ 細到區域/據點的可見性。

## 3. 稽核軌跡（防竄改）

`audit_log`（append-only）：

| 欄位 | 說明 |
|---|---|
| id, tenant_id | |
| actor_user_id | 操作者（或 system/agent）|
| action | 如 `incident.assign`, `ej.view`, `whitelist.update`, `dispute.resolve` |
| target_type / target_id | 操作對象 |
| before / after (jsonb) | 變更前後（敏感值遮罩）|
| occurred_at | |
| prev_hash / hash | **hash chain**：`hash = H(prev_hash + 本筆正規化內容)` |

- 涵蓋：特權操作、**EJ 存取**、設定/白名單/派送變更、差錯解決、角色變更。
- 防竄改：任何中間竄改會破壞 hash chain，稽核可驗證完整性。
- 保留期依金管會/銀行政策（見 `61`）。

## 4. 跨模組共用實體

| 實體 | 用途 |
|---|---|
| `Tenant` / `User` / `Role` / `Permission` / `UserRole` | 身分授權 |
| `AuditLog` | 稽核（hash chain）|
| `Device`（主檔）| 被各模組以 `device_id` 參照（**唯一可被跨模組讀的主檔，經 Contracts 介面）**|
| `Site` / `Region` | 據點/區域階層 |
| `NotificationRule/Channel/EscalationPolicy/Log` | 告警引擎（見 `51`）|
| `device_inbound` | 攝取 inbound log（見 `21`）|
| `outbox` | 整合事件發件箱 |

> 模組間**不直接 join 他模組的表**；需要他模組資料時，透過整合事件投影出自己需要的唯讀副本，或經 Contracts 公開查詢。`device_id`、`tenant_id`、`rrn` 等為跨模組關聯鍵。

## 5. 多租戶隔離實作

- 連線/Token 解析出 `tenantId` → 注入 `ITenantContext` → EF global filter 自動加 `WHERE tenant_id = @t`。
- **禁止**任何查詢省略租戶過濾；以 `AFMP.ArchitectureTests` + 整合測試掃描把關。
- SaaS：共用 DB + row filter；大型租戶可 schema-per-tenant。
- on-prem：`tenantId` 釘死單一值。
- blob（MinIO）：tenant 前綴 + 各自加密金鑰；秘密在 Vault 分租戶路徑。

## 6. 時序 vs 關聯式 切分

| 類型 | 儲存 | 例 |
|---|---|---|
| 主檔/生命週期/案件 | 關聯式表 | Device, Site, Incident, WorkOrder, ReplenishmentOrder, Dispute |
| 高頻事件/快照/指標 | Timescale hypertable | DeviceStatusEvent, CashLevelSnapshot, Transaction(指標), 連續彙總 |
| 不可變帳 | append-only 表（可為 hypertable）| CashLedger, IncidentEvent, AuditLog |
| blob | 物件儲存 | EJ 批次、韌體、行銷內容 |
