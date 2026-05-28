---
title: 功能規格 — M1 機台主檔與狀態監控
module: AFMP / Modules / Devices
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Spec, Devices, Dashboard, Map]
---

# 功能規格：M1 機台主檔與狀態監控

對標 DMS「即時色彩狀態看板」，升級為**事件驅動即時推送 + 互動地圖**。

## 功能清單

1. **機台主檔 CRUD + 批次匯入**（CSV/Excel）：vendor/model/type/site/region/版本。
2. **據點/區域/負責人階層**：多層 region → site → device。
3. **即時狀態看板**：色彩磚（綠/黃/紅/灰）依 Online/Degraded/Offline/Maintenance；即時推送（SignalR）。
4. **互動地圖**：地理佈點、群聚（clustering）、依健康度上色、點擊下鑽。
5. **機台詳情**：模組健康（dispenser/cardReader/...）、事件時間軸、現行 firmware/agent、現金摘要、近期交易摘要。
6. **生死判定**：心跳逾時→Offline；恢復→Online。
7. **健康度分數**：由模組狀態 + 近期故障彙算（0–100）。
8. **機群管理**：依條件或明列，供派送/白名單鎖定。

## 主要使用者流程

- **巡檢分流**：NOC 看板 → 紅點機台 → 詳情 → 看到 dispenser fault → 一鍵建立/查看事件（跳 M4）。
- **新機納管**：建主檔 → 納管（發憑證）→ 首次心跳 → 自動上線、地圖出現。
- **區域檢視**：依 region 過濾，店經理只見其轄區（RBAC 資源範圍）。

## 畫面

| 畫面 | 重點元件 |
|---|---|
| 機隊看板 | 狀態統計磚、即時更新、篩選（region/model/status）|
| 地圖視圖 | 地圖佈點、群聚、色彩、側欄詳情 |
| 機台清單 | 表格 + 篩選 + 排序 + 分頁 |
| 機台詳情 | 模組健康、事件時間軸、版本、現金/交易摘要、操作（派送/重啟/診斷）|
| 據點管理 | 區域樹 + 據點 CRUD |
| 機群管理 | 條件式/明列群組 |

## 即時性設計

- 狀態變化（StatusEvent/Heartbeat）→ 投影更新 → SignalR group（依 tenant/region）推前端，看板秒級更新。
- 大量機台時看板以聚合視圖為主，下鑽才載個別細節。

## 對標檢核（vs DMS）

| DMS | AFMP |
|---|---|
| 色彩狀態看板 | ✅ + 即時推送 |
| — | ✅ 互動地圖 |
| — | ✅ 健康度分數、事件時間軸 |
| 機台清單 | ✅ + 進階篩選/批次匯入 |

## 依賴

- 資料模型：`03-data-model/31`。狀態機：`35` §1。合約：Heartbeat/StatusEvent（`20` §3）。
- 發布整合事件：`DeviceStatusChanged`（供 M4/通知）。
