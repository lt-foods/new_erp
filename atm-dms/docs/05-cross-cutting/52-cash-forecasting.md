---
title: 現金需求預測
module: AFMP / CrossCutting
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Forecasting, ML, SARIMA, XGBoost, Cash]
---

# 現金需求預測（Cash Demand Forecasting）

分階段：**v1 統計基線 → v2 ML**。目標 MAPE：基線 ≤ 15%、ML ≤ 10%。

## 1. 問題定義

- 對每台機台預測未來 N 日（補鈔週期）之**提領需求**，並拆解到**各面額**。
- 輸出餵給補鈔建議/最佳化（見 `41`）：在不缺鈔前提下最小化補鈔次數與閒置現金。

## 2. v1 — 統計基線（ML.NET / 自實作）

- **SARIMA / 季節性指數平滑**：捕捉週、月、年週期。
- **台灣行事曆特徵**（關鍵）：
  - 國定假日、**連假長度**（「未來連假天數」是最強預測因子之一）。
  - **發薪日**（月底/5 日/15 日等樣態）。
  - 農曆春節等特殊期間。
- 低歷史機台：以同型/同區域群體均值回退。

## 3. v2 — ML

- **XGBoost / 梯度提升**，per 機台叢集建模。
- **先對機台依需求樣態分群（clustering）再分群建模**（處理低歷史、提升泛化）。
- 特徵：day-of-week/month/year、月內第幾日、月份、假日旗標 + 連假天數、發薪日、lag 提領、滾動均值、據點型別、（選配）天氣/在地活動。
- 輸出：per 面額需求分布。

## 4. 重訓與監控

- **排程重訓**（每週/每月）批次。
- **漂移監控**：追蹤 MAPE；惡化觸發重訓/告警。
- **champion/challenger**：新模型先影子評估，勝出才升級（`model_ver` 紀錄）。
- 預測結果寫 `cash_forecast`（含信賴區間）。

## 5. 與補鈔的銜接

```
cash_forecast（需求）+ 現有水位 + 安全緩衝 + 鈔匣容量
   → 補鈔建議裝載量（v1 單機規則）
   → v2：最佳化（最小化造訪 + 閒置現金，約束缺鈔風險）
   → replenishment_order(Draft)
```

## 6. 技術落點

- v1：`Forecasting` 模組（ML.NET in-process），由 Hangfire 排程跑。
- v2：可選 Python/MLflow sidecar；平台以介面呼叫，模型產物版本化。
- 評估資料集：`transaction`/`cash_ledger` 歷史（時序）。

## 7. 對標

- 對標 INETCO/Diebold/NCR 之 ML 現金最佳化；v1 先以可解釋的統計基線快速上線並建立 KPI 基準，v2 再導入 ML 拉高準確度。
