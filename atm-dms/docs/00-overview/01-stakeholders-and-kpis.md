---
title: 利害關係人與 KPI
module: AFMP / Overview
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Stakeholders, KPI, RACI]
---

# 利害關係人與 KPI（Stakeholders & KPIs）

## 1. 利害關係人（Actors）

| Actor | 中文 | 主要需求 | 關鍵畫面 |
|---|---|---|---|
| Bank Ops / NOC | 銀行維運中心 | 即時機隊狀態、停機分流、金管會異常通報 | 機隊看板、事件台 |
| Cash Management Team | 現金調度組 | 現金水位、預測、補鈔排程、降閒置現金 | 現金總覽、補鈔排程、預測 |
| Field Engineer | 外勤工程師 | 工單、派工、零件、行動簽到/簽退 | 行動工單 app |
| CIT / Cash-in-Transit | 運鈔公司 | 補鈔單、路線時窗、鈔匣交換確認 | CIT 派工板 |
| Vendor | 設備供應商（Hitachi/多廠牌）| 指派故障、SLA、RMA/零件 | 廠商工單（限指派）|
| Compliance / Audit | 法遵 / 稽核 | 稽核軌跡、保留、金管會報表 | 稽核查詢、報表 |
| Bank Admin | 銀行管理者 | RBAC、機台主檔、軟體/內容派送政策 | 設定、派送 |
| MDS Operator | MDS 平台營運 | 多銀行營運、納管、平台健康、計費 | 平台營運台 |

## 2. RACI（關鍵活動，摘要）

| 活動 | Bank Ops | Cash Team | Field Eng | Vendor | Compliance | MDS Op |
|---|---|---|---|---|---|---|
| 機台納管 | C | I | I | C | I | **R/A** |
| 故障派工 | **A** | I | **R** | R | I | C |
| 補鈔排程 | C | **R/A** | I | I | I | I |
| 三方對帳 | **R/A** | C | I | I | C | I |
| 異常通報（金管會）| **R** | I | I | I | **A** | C |
| 軟體派送 | **A** | I | I | C | I | R |

R=執行 A=當責 C=諮詢 I=告知

## 3. KPI（量化目標與量測）

| KPI | 定義 | 目標 | 量測來源 |
|---|---|---|---|
| 機台妥善率（Availability）| 1 − 停機時間/應營運時間（per 機台、滾動 30 天）| ≥ 95%（循環機 98%+）| 狀態事件流（Online/Offline/Maintenance 區間）|
| 缺鈔事件數（Out-of-cash）| 因鈔匣空導致無法提領之事件 | ↓ 50% vs 基線 | 現金分類帳 + 狀態事件 |
| 閒置現金成本 | 平均在機現金 × 資金成本率 | ↓ 15–25% | 現金水位時序 |
| MTTR | 事件 New→Resolved 平均時長（per 故障類）| ↓ vs DMS 基線 | 事件生命週期 |
| SLA 達成率 | 於合約時窗內解決之事件比 | ≥ 95%（依嚴重度）| SLA 計時器 |
| 異常通報及時率 | 金管會應通報事件之及時完成比 | 100% | 通報工作流 |
| 預測準確度（MAPE）| per 機台日提領預測誤差 | 基線 ≤ 15%、ML ≤ 10% | 預測 vs 實際 |
| 平台可用性 | 控制平面 uptime | 99.9% | 觀測性平台 |

## 4. KPI ↔ 模組對映

- 妥善率 / MTTR / SLA → 機台模組 + 維修模組
- 缺鈔 / 閒置現金 / 預測 → 現金模組 + 預測引擎
- 異常通報 → 交易/對帳 + 合規 + 告警引擎
- 平台可用性 → NFR/HA（見 `06-nfr-compliance/62`）

> 所有 KPI 皆以**附加式事件流/分類帳**為唯一真實來源（可回溯重算），避免可變狀態被覆寫造成失真。
