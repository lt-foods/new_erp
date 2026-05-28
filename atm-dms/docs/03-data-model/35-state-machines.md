---
title: 狀態機 — 機台 / 事件 / 工單 / 補鈔 / 對帳
module: AFMP / DataModel
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [StateMachine, Device, Incident, WorkOrder, Replenishment, Recon]
---

# 狀態機（State Machines）

> 狀態機驅動全系統流程，置於各模組 Domain 層。本檔為單一真實來源；其他文件引用此處。

## 1. 機台 Device

```
Provisioned ──enroll──► Enrolled ──firstHeartbeat──► Online
   Online ⇄ Degraded        （非致命模組故障但仍可交易）
   Online ──missHeartbeatN──► Offline ──heartbeat──► Online
   (any) ──maintenanceStart──► Maintenance ──maintenanceEnd──► Online
   (any) ──decommission──► Decommissioned
```

| 狀態 | 意義 |
|---|---|
| Provisioned | 已建主檔、未納管 |
| Enrolled | 已發憑證、納管完成 |
| Online | 正常連線運作 |
| Degraded | 連線但部分模組故障（仍可交易）|
| Offline | 失聯（缺心跳）|
| Maintenance | 維修中（不計入停機 SLA）|
| Decommissioned | 除役 |

- `Degraded` 由 `device_module.state` 出現 warn/fault 但 dispenser/network 仍 ok 時推導。
- 妥善率計算：`Maintenance` 視政策決定是否扣除；`Offline/Degraded(致命)` 計停機。

## 2. 事件 Incident

```
New ──triage──► Triaged ──assign──► Assigned ──dispatch──► Dispatched
   ──onsite──► OnSite ──work──► InProgress ──resolve──► Resolved ──close──► Closed
   (Resolved/Closed) ──reopen──► Reopened ──► InProgress
   (any active) ──escalate──► Escalated（並行旗標，續走原流程）
```

- `New→Resolved` 計 MTTR；`sla_response_due`（到 Assigned）、`sla_resolve_due`（到 Resolved）計 SLA。
- `Escalated` 為附加狀態（逾時/未回應），不取代主流程。
- 每次轉移寫 `incident_event`（append-only）。

## 3. 工單 Work Order（與事件並行，含外勤動作）

```
Created ──assign──► Assigned ──accept──► Accepted ──depart──► Traveling
   ──arrive──► CheckedIn ──work──► InProgress ──complete──► CheckedOut ──verify──► Closed
   Assigned ──reject──► Created（退回重派）
```

- `CheckedIn/CheckedOut` 對映行動 app 的 GPS/時間打卡。
- 工單 `Closed` 連動其 `incident` 可進 `Resolved`。

## 4. 補鈔單 Replenishment Order

```
Draft ──plan──► Planned ──dispatchToCIT──► Dispatched ──pickup──► InTransit
   ──arrive&load──► Loaded ──confirm──► Confirmed ──reconcile──► Reconciled
   (Draft/Planned/Dispatched) ──cancel──► Cancelled
```

| 狀態 | 意義 |
|---|---|
| Draft | 系統/人員建立草稿（可由預測自動生成）|
| Planned | 確認裝載量與時窗 |
| Dispatched | 已交付 CIT 運鈔 |
| InTransit | 運送中 |
| Loaded | 已到場裝鈔 |
| Confirmed | CIT/機台確認裝載 |
| Reconciled | 與 cash_ledger/清點對帳完成 |

- `Confirmed` 寫 `cash_ledger`（movement=replenish）。

## 5. 對帳 Recon Match / Dispute

```
Pending ──compare──► Matched
Pending ──compare──► Exception ──open──► UnderReview ──resolve──►
        Resolved{ Adjusted | WrittenOff | CustomerCredited }
```

- `Exception` 之分類見 `33`/`23`（EJ-only/Switch-only/…）。
- `Exception` 自動開 `dispute` 進差錯佇列。

## 6. 派送 Distribution Job（軟體/內容）

```
Created ──schedule──► Scheduled ──rolloutStart──► Rolling
   ──(per device CommandAck)──► PartiallyDone ──allAck──► Completed
   Rolling ──errorThreshold──► Halted ──rollback──► RolledBack
```

- 分階段 rollout：依機群分批；錯誤率超閾值自動 `Halted`，可 `RolledBack`。
- 每台狀態由 `CommandAck`（見合約 §4）驅動。

## 狀態轉移權限（摘要）

| 轉移 | 角色 |
|---|---|
| incident.assign / dispatch | Ops/NOC |
| work_order.accept/checkin/checkout | Field Engineer / Vendor（限指派）|
| replenishment.plan/approve | Cash Team |
| dispute.resolve | Ops/Compliance |
| distribution.rollout/rollback | Bank Admin / MDS Operator |

（完整 RBAC 見 `05-cross-cutting/50`。）
