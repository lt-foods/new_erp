---
title: 術語中英對照（Glossary）
module: AFMP / Overview
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Glossary, 術語, 中英對照]
---

# 術語中英對照（Glossary）

## 領域 / 設備

| 中文 | English | 說明 |
|---|---|---|
| 自動櫃員機 | ATM (Automated Teller Machine) | 提款/查詢機 |
| 存提款機 / 循環式 | Cash Recycling Machine | 同時收/付鈔、鈔票循環 |
| 自動化設備 | AVM (Automated Vending/Service Machine) | 廣義自助設備 |
| 機隊 / 機群 | Fleet / Device Group | 一批機台 / 派送鎖定群組 |
| 機台主檔 | Device Master | 機台登錄主資料 |
| 據點 | Site / Location | 機台所在地點 |
| 鈔匣 / 循環匣 | Cassette / Recycling Cassette | 裝鈔單元 |
| 鈔票回收匣 | Reject/Retract Bin | 退鈔/吞卡單元 |
| 加密鍵盤 | EPP (Encrypting PIN Pad) | PIN 輸入加密 |
| 妥善率 | Availability / Uptime | 機台可用率 |
| 運鈔 | CIT (Cash-in-Transit) | 押運/補鈔 |

## 交易 / 對帳

| 中文 | English | 說明 |
|---|---|---|
| 電子日誌 | EJ (Electronic Journal) | 機台逐筆交易日誌 |
| 金融轉接 | Switch | ATM 交易授權轉接 |
| 核心系統 | Core Banking | 入帳/結算系統 |
| 三方對帳 | 3-way Reconciliation | EJ↔Switch↔Core 比對 |
| 日結 | EOD Settlement | 日終結算 |
| 差錯案件 | Dispute / Exception Case | 對帳不符之處理案件 |
| 沖正/逆向 | Reversal | 交易撤銷 |
| 參考號 | RRN / STAN | 交易參考/序號 |
| 卡號遮罩/代碼化 | PAN Masking / Tokenization | 縮小 PCI 範圍 |

## 維修 / 告警

| 中文 | English | 說明 |
|---|---|---|
| 故障 / 告警 | Fault / Alert | 異常事件 |
| 事件 | Incident | 關聯一或多筆故障 |
| 維修工單 | Work Order | 派工執行單 |
| 派工 | Dispatch | 指派工程師/廠商 |
| 服務水準 | SLA (Service Level Agreement) | 回應/解決時限 |
| 升級 | Escalation | 逾時/未回應升級 |
| 重複故障 | Recurring Fault | 慢性問題機台 |
| 退修件 | RMA (Return Merchandise Authorization) | 零件返修 |

## 架構 / 技術

| 中文 | English | 說明 |
|---|---|---|
| 租戶 | Tenant | 一家銀行 |
| 模組化單體 | Modular Monolith | 單一部署、模組邊界嚴格 |
| 攝取閘道 | Ingestion Gateway | 接收機端資料的入口 |
| 附加式分類帳 | Append-only Ledger | 不可變事件流 |
| 交易發件箱 | Transactional Outbox | 可靠事件發布 |
| 時序資料庫 | Time-series DB (TimescaleDB) | 遙測/水位/指標 |
| 設備模擬器 | Device Simulator | 開發/展示用合成機台 |
| 介面合約 | Interface Contract | agent↔平台訊息規格 |
| 架構決策紀錄 | ADR (Architecture Decision Record) | 關鍵決策文件 |
| 多廠牌 | Multivendor | 跨 ATM 製造商 |

## 標準 / 法規

| 名稱 | 說明 |
|---|---|
| CEN-XFS | ATM 軟硬體介面標準（經典版）|
| XFS4IoT (CWA 17852) | 次世代 XFS，JSON over wss、OS 無關 |
| ISO 8583 | 金融交易訊息標準（switch）|
| ISO 20022 | 新世代金融訊息標準 |
| TR-34 | 對稱金鑰遠端配送標準 |
| PCI-DSS | 支付卡產業資安標準 |
| 金管會 / FSC | 金融監督管理委員會 |
| 銀行局 | 金管會轄下，異常事件通報對象 |
