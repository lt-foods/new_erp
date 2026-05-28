---
title: 對帳介接 — Switch(ISO 8583) 與 Core Banking
module: AFMP / Integration
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Reconciliation, ISO8583, CoreBanking, EJ, 3-way]
---

# 對帳介接：Switch(ISO 8583) 與 Core Banking

支援**三方對帳**（3-way Reconciliation）：以機端 **EJ**、金融轉接 **Switch**、核心入帳 **Core** 三個來源比對。

## 1. 三個資料來源

| 來源 | 取得方式 | 內容 |
|---|---|---|
| **EJ**（機端）| agent 上傳（見 `20` §3.5）解析正規化 | 機台實際吐鈔/收鈔逐筆 |
| **Switch**（轉接）| **ISO 8583** 即時授權訊息 或 批次對帳檔 | 授權結果、RRN/STAN、金額 |
| **Core**（核心）| 入帳/結算 feed（檔案/ API / DB view）| 實際入/扣帳分錄 |

> v1 假設銀行能提供 Switch 與 Core 之資料（即時或批次）。即時 vs 批次能力是開放問題（見 `07-delivery/71` Q2），影響對帳即時性設計。

## 2. ISO 8583 介接

- 採 adapter 模式，將 ISO 8583（0200/0210/0420/0430 等）正規化為平台**標準交易形狀**。
- 關鍵欄位對映：

| ISO 8583 欄位 | 平台欄位 |
|---|---|
| DE2（PAN）| cardToken（**入站即代碼化**，不存明文）|
| DE3（處理碼）| txnType |
| DE4（金額）| amount |
| DE11（STAN）| stan |
| DE37（RRN）| rrn |
| DE39（回應碼）| responseCode |
| DE41（終端機 ID）| deviceId 對映 |
| DE7/DE12/DE13（時間）| occurredAt |

- 即時模式：訂閱 switch 訊息流（MQ/socket adapter）；批次模式：定時匯入對帳檔。

## 3. Core Banking feed

- 支援檔案（定長/CSV）、API、或唯讀 DB view 三種 adapter。
- 正規化為標準入帳記錄：`rrn/stan, account, postedAmount, postedAt, status`。

## 4. 正規化與比對鍵

- 三來源統一為 **canonical txn**：`{deviceId, rrn, stan, amount, currency, occurredAt(±時窗), txnType, result}`。
- 比對鍵：`RRN`（首選）+ `STAN` + 金額 + 時窗（容忍時鐘偏移）。

## 5. 三方比對分類

| 分類 | 意義 | 後續 |
|---|---|---|
| `Matched` | 三方一致 | 結案 |
| `EJ-only` | 機台有、Switch/Core 無 | 疑似吐鈔未授權 → 差錯 |
| `Switch-only` | 授權有、機台未吐 | 疑似未吐鈔 → 應沖正/退款 |
| `Core-only` | 入帳有、無對應交易 | 異常入帳 → 查核 |
| `Amount-mismatch` | 金額不符 | 差錯案件 |
| `Timeout-reversal` | 逾時沖正 | 驗證沖正完成 |

## 6. 日結（EOD Settlement）

- 每日對每台機台彙總：EJ 出鈔總額 vs Switch 核准 vs Core 扣帳 vs **現金分類帳**（見 `32`）實際鈔匣變動。
- 差異進入**差錯佇列**（exception queue）→ 差錯案件工作台處理（見 `42`）。
- 現金實體面：日結同時與補鈔/清點對帳（cash reconciliation）交叉驗證。

## 7. 差錯案件（Dispute / Case）

- 不符項生成 case，連結三來源原始記錄 + EJ 影像/明細，供分析員並排檢視。
- 解決態：`Adjusted（調整）/ WrittenOff（沖銷）/ CustomerCredited（退客戶）`。
- 全程進稽核軌跡（見 `30`）。

## 8. 安全與合規

- PAN 一律於入站 adapter 即代碼化（與機端一致），對帳全程使用 token。
- 對帳結果與差錯處理為金管會稽核重點，需完整保留（見 `61`）。
