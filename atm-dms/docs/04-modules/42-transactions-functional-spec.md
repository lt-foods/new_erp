---
title: 功能規格 — M3 交易監控與對帳
module: AFMP / Modules / Transactions
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Spec, Transactions, EJ, Reconciliation]
---

# 功能規格：M3 交易監控與對帳

對標 DMS「交易分析 + EJ 集中收存」，升級為**三方對帳 + 差錯工作台**。

## 功能清單

1. **即時交易流**：逐筆交易監看（型別/金額/回應碼/結果），可篩選/搜尋。
2. **EJ Viewer**：可搜尋的電子日誌檢視；**解密需記稽核**（`ej.view`）。
3. **日結（EOD）**：per 機台彙總，EJ/Switch/Core/出鈔交叉。
4. **三方對帳儀表板**：比對狀態統計 + **例外佇列**。
5. **差錯案件工作台**：並排檢視 EJ / Switch / Core 原始記錄，解決/退款/沖銷。
6. **報表與匯出**：交易分析、對帳結果、SLA 報表；CSV/Excel/PDF。

## 主要使用者流程

- **日結對帳**：EOD 排程 → 對帳引擎跑三方比對 → 例外佇列產生 → 分析員開例外 → 並排三來源 → 解決或開差錯。
- **爭議查核**：客訴某筆 → 以 RRN 查 EJ + Switch + Core → 判定（吐鈔未授權/未吐鈔/重複扣帳）→ 結案（退款/調整/沖銷）。
- **異常交易監看**（v2 強化）：即時偵測異常提領樣態，連動金管會異常通報（見 `61`）。

## 畫面

| 畫面 | 重點 |
|---|---|
| 交易監看 | 即時流、篩選、KPI |
| EJ Viewer | 搜尋、明細、原始 blob 下載（稽核）|
| 日結摘要 | per 機台三方彙總 + 差異 |
| 對帳例外佇列 | 分類統計 + 待處理清單 |
| 差錯工作台 | 三來源並排、解決動作 |
| 報表產生器 | 模板 + 排程 + 匯出 |

## 三方對帳（摘要）

- 來源：EJ（機端）/ Switch（ISO 8583）/ Core（入帳）。
- 比對鍵：RRN(+STAN+金額+時窗)。
- 分類：Matched / EJ-only / Switch-only / Core-only / Amount-mismatch / Timeout-reversal。
- 不符 → 差錯案件。詳見 `02-integration/23` 與資料模型 `33`。

## 對標檢核（vs DMS）

| DMS | AFMP |
|---|---|
| 交易分析報表 | ✅ |
| EJ 集中收存 | ✅ + 可搜尋 Viewer + 存取稽核 |
| — | ✅ 三方對帳 + 例外佇列 |
| — | ✅ 差錯案件工作台 |
| — | （v2）即時異常交易監控 |

## 依賴

- 資料模型：`33`。狀態機：`35` §5。合約：Transaction / EjBatchMeta（`20`）。
- 介接：`23`（ISO 8583 / Core）。整合事件：`ReconExceptionFound`。
- 與 M2 cash_ledger 交叉（出鈔實體面）。
- PCI：全程 card_token（`60`）。
