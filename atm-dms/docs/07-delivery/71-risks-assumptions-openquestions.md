---
title: 風險、假設與開放問題
module: AFMP / Delivery
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Risks, Assumptions, OpenQuestions]
---

# 風險、假設與開放問題

## 1. 假設（Assumptions）

1. 銀行能提供 switch（ISO 8583）與 core banking 之資料供對帳（即時或批次）。
2. Hitachi/多廠牌 ATM 能運行遵循本合約（`20`）的機端 agent。
3. 卡號（PAN）於機端代碼化/遮罩。
4. MDS 為受委託營運者，受銀行監督（委外）。
5. 本環境僅交付**規格與架構藍圖**；機端 agent、真實 XFS/硬體、金管會認證不在範圍。

## 2. 風險與緩解（Risks）

| 風險 | 影響 | 緩解 |
|---|---|---|
| agent 不在本範圍卻最關鍵 → 合約漂移 | 高 | 版本化合約 + 模擬器**一致性測試** + 最早凍結 |
| 多廠牌異質（KAL 達 40 廠/250+ 型）| 中高 | 正規化層 + per-vendor adapter（SNMP/原廠碼）|
| 金管會認證依賴銀行 | 中 | 平台僅提供控制項/證據，明確界定責任 |
| on-prem 營運成熟度差異 | 中 | 模組化單體 + Compose 單機選項 + runbook |
| EJ 格式各廠/各行不一 | 中 | 可插拔 EJ parser |
| Switch/Core 即時介接未必可得 | 中 | 對帳先支援批次檔，即時後補 |
| 攝取尖峰（連假潮）| 中 | inbound log 緩衝 + 背壓 + 水平擴展 |
| 資料量/保留成本 | 中 | Timescale 分區 + retention + 彙總 |

## 3. 開放問題（待客戶確認）

1. **部署模式**：各目標銀行採 MDS 私雲多租戶 vs 嚴格 on-prem？（影響拓撲/隔離）
2. **對帳資料**：銀行能提供**即時** switch + core 介接，或僅**批次**？（影響對帳即時性設計）
3. **多廠牌範圍**：v1 除 Hitachi 外納入哪些 ATM 廠牌/型號？（影響 adapter 廣度）
4. **SSO**：既有 IdP/AD 是否需聯邦？
5. **資料庫**：是否強制特定 DB（部分銀行要求 SQL Server/Oracle）？
6. **金管會報表**：確切格式與保留年限要求？
7. **外勤筋斗雲**：整合或取代？（影響 M4 行動 app）
8. **機端標準**：ATM 軟體走 XFS4IoT 或經典 XFS？（影響合約框定）

> 建議：在進入 Phase 1 前，至少先鎖定 Q1、Q2、Q8（影響架構與合約最深）。
