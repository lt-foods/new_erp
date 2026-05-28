---
title: 報表與分析
module: AFMP / CrossCutting
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Reporting, Analytics, Dashboard, FSC]
---

# 報表與分析（Reporting & Analytics）

## 1. 營運儀表板

- **妥善率**：per 機台/區域/全行，趨勢。
- **MTTR / SLA 達成率**：per 故障類/廠商/區域。
- **現金 KPI**：閒置現金成本、缺鈔事件、補鈔次數、預測準確度。
- **交易/對帳**：交易量、對帳例外率、差錯結案時效。

## 2. 技術

- **Timescale continuous aggregate**：預先彙總時序，看板查詢 < 2s。
- 熱查詢走 Dapper + Redis 快取；明細走分頁查詢。
- 重報表以 Hangfire 排程離線產生 → 物件儲存 → 下載。

## 3. 報表類型

| 類型 | 例 |
|---|---|
| 排程報表 | 日結對帳、每日妥善率、每週現金、每月 SLA |
| 隨選 / ad-hoc | 自訂期間/範圍查詢匯出 |
| 合規報表 | 金管會異常通報、稽核軌跡彙整（見 `61`）|
| 匯出格式 | CSV / Excel / PDF |

## 4. 自助報表（v2）

- 報表產生器：選維度/指標/篩選/期間 → 預覽 → 排程/匯出。
- 跨銀行標竿（MDS 加值，匿名彙總）列 Phase 3。

## 5. 資料治理

- 報表一律受租戶 + 資源範圍授權限制（同 RBAC）。
- 含敏感資料（EJ/交易）之報表，存取與下載寫稽核。
- 保留期依政策（見 `61`）。

## 6. 對標

- 對標 DMS「交易分析/故障紀錄/現金流報表」並擴充營運 KPI 儀表板與合規報表模板。
