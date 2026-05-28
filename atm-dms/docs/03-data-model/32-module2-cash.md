---
title: 資料模型 — M2 現金庫存與補鈔
module: AFMP / DataModel / Cash
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [DataModel, Cash, Replenishment, CIT, Forecast]
---

# 資料模型：M2 現金庫存與補鈔（Cash）

## 實體一覽

### `cassette`（鈔匣 / 循環匣）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| cassette_code | C1/C2… |
| kind | `dispense/deposit/recycle/reject` |
| denomination | 面額（如 1000）|
| currency | TWD |
| capacity | 容量（張）|

### `cash_level_snapshot`（現金水位, append-only, hypertable）
| 欄位 | 說明 |
|---|---|
| time | 量測時間 |
| tenant_id, device_id, cassette_id | |
| count | 張數 |
| value | 金額 |
| status | `ok/low/empty/full/jam` |
| source | agent CashState |

### `cash_ledger`（現金分類帳, append-only）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id, cassette_id, seq | |
| movement_type | `dispense/deposit/replenish/collect/reject/adjust` |
| denomination, delta_count, delta_value | 變動 |
| balance_after_count/value | 變動後餘額 |
| source_ref | 來源（txn_id / replenishment_id）|
| occurred_at | |

> 出鈔交易（Transaction）聯動 `dispense`；補鈔聯動 `replenish`。餘額為帳上推算，與實體清點對帳。

### `replenishment_order`（補鈔單）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| status | 見狀態機（35）|
| planned_items | jsonb：各鈔匣/面額目標裝載量 |
| cit_vendor_id | 運鈔商 |
| scheduled_window | 時窗 |
| forecast_id | 依據之預測 |
| created_by, approved_by | |

### `cit_route` / `cit_visit`（運鈔路線 / 到訪）
- `cit_route`: id, tenant_id, cit_vendor_id, name, stops(jsonb), service_date。
- `cit_visit`: id, route_id, device_id, replenishment_order_id, eta, arrived_at, confirmed_at, status。

### `cash_count` / `cash_reconciliation`（清點 / 盤點對帳）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| counted_at, counted_by | |
| expected (jsonb) | 帳上應有（cash_ledger 推算）|
| counted (jsonb) | 實點 |
| variance (jsonb) | 差異 |
| status | `balanced/variance/resolved` |

### `cash_forecast`（現金預測）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| horizon_date | 預測日 |
| predicted_demand | 預測提領需求（金額）|
| by_denomination (jsonb) | 各面額需求 |
| model_ver | 模型版本 |
| confidence / interval | 信賴區間 |
| generated_at | |

（預測方法見 `05-cross-cutting/52-cash-forecasting.md`。）

## 關聯

```
device 1──* cassette 1──* cash_level_snapshot（時序）
device 1──* cash_ledger（append-only）
device 1──* replenishment_order *──1 cit_vendor
replenishment_order 1──1 cit_visit ; cit_visit *──1 cit_route
device 1──* cash_count ; device 1──* cash_forecast
replenishment_order.forecast_id → cash_forecast
```

## 衍生指標

- **閒置現金**：在機現金 × 資金成本率（由 `cash_level_snapshot` 時序積分）。
- **缺鈔風險**：水位趨勢 vs 預測需求 → 觸發補鈔建議（事件 `CashBelowThreshold`）。
- **補鈔最佳化（v2）**：在不缺鈔前提下最小化補鈔次數與閒置現金。

## 索引建議

- `cash_level_snapshot(tenant_id, device_id, time desc)`（hypertable 分區）。
- `cash_ledger(tenant_id, device_id, seq)` 唯一（防重）。
- `replenishment_order(tenant_id, status, scheduled_window)`。
