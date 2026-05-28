---
title: 功能規格 — M4 故障告警與維修工單
module: AFMP / Modules / Maintenance
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Spec, Maintenance, Incident, WorkOrder, SLA, Dispatch]
---

# 功能規格：M4 故障告警與維修工單

對標 DMS「故障紀錄 + 多通道告警」，升級為**自動分類 + 自動派工 + SLA + 重複故障分析 + 行動外勤**（整合/取代「外勤筋斗雲」）。

## 功能清單

1. **故障/異常偵測**：來源 = agent FaultEvent + 規則引擎（門檻/心跳缺失/速率）+ ML 異常（v2）。
2. **自動分類 + 嚴重度**：故障碼 → 分類；嚴重度由最高 fault 決定。
3. **事件關聯/去重**：同機台短時間多 fault 關聯同一 incident，避免工單爆量。
4. **自動派工**：依工程師技能/區域 + 廠商 coverage + SLA 配對。
5. **SLA 計時 + 升級**：回應/解決時限計時；逾時/未回應升級（見 `51`）。
6. **零件 / RMA / 廠商管理**：零件庫存、退修、廠商 SLA。
7. **重複故障分析**：滾動視窗群聚 → 慢性機台 / 系統性零件失效。
8. **行動外勤 app**：派工接收、導航、簽到/簽退、零件登錄、簽核結案。

## 主要使用者流程

- **故障到結案**：FaultEvent → 去重關聯成 incident → 分類 → 自動派工 → 工程師行動 app 收通知 → 出發/到場/維修 → 登錄零件 → 簽退 → incident 結案；SLA 風險觸發升級。
- **預防性維護**：依重複故障/保養週期排預防工單。
- **廠商協作**：指派廠商（限見其工單）、追 SLA、RMA。

## 畫面

| 畫面 | 重點 |
|---|---|
| 告警主控台 | 即時告警流、嚴重度、確認/抑制 |
| 事件看板（Kanban）| 依狀態欄（New→Closed）拖拉 |
| 工單詳情 | 派工、檢查表、零件、簽核 |
| 派工/排程 | 工程師/廠商配對、行事曆 |
| 零件 & RMA | 庫存、退修追蹤 |
| SLA 儀表板 | 達成率、逾時風險、MTTR |
| 重複故障報表 | 慢性機台/零件分析 |
| **行動工單 app** | 接單、導航、打卡、結案 |

## 自動派工邏輯（v1）

1. incident 分類 + 嚴重度 → 取適用 `sla_policy`。
2. 候選 = 區域涵蓋 + 技能符合的 engineer/vendor。
3. 排序：就近 + 負載 + SLA 餘裕；指派最佳者 → 工單 `Assigned` + 通知。
4. 拒接/逾時 → 退回重派 + 升級。
5. v2：以歷史修復時間/成功率 ML 優化配對。

## 對標檢核（vs DMS）

| DMS | AFMP |
|---|---|
| 故障紀錄 | ✅ |
| 多通道告警（含傳真）| ✅ 現代化通道（push/IM/...），**傳真退役** |
| — | ✅ 自動分類 + 自動派工 + SLA + 升級 |
| — | ✅ 重複故障分析、零件/RMA |
| — | ✅ 行動外勤 app（整合/取代外勤筋斗雲）|

## 依賴

- 資料模型：`34`。狀態機：`35` §2/§3。合約：FaultEvent / SecurityEvent（`20`）。
- 通知引擎：`51`。整合事件：`FaultRaised`、`IncidentSlaBreachImminent`。
- 訂閱：`DeviceStatusChanged`、`WhitelistViolation`、`CashBelowThreshold`(可選)。
