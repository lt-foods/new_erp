---
title: 資料模型 — M3 交易監控與對帳
module: AFMP / DataModel / Transactions
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [DataModel, Transactions, EJ, Reconciliation, ISO8583]
---

# 資料模型：M3 交易監控與對帳（Transactions）

## 實體一覽

### `transaction`（交易, hypertable + 關聯索引）
| 欄位 | 說明 |
|---|---|
| time | 交易時間（occurredAt）|
| id, tenant_id, device_id, seq | |
| txn_type | `withdrawal/deposit/inquiry/transfer/reversal` |
| amount, currency | |
| denom_breakdown (jsonb) | 面額拆解 |
| response_code | ISO 回應碼 |
| rrn, stan | 對帳鍵 |
| card_token | **代碼化**（無明文 PAN）|
| channel | `onus/interbank` |
| result | `approved/declined/reversed` |
| source | `agent_ej/switch`（標記來源）|

### `ej_batch` / `ej_entry`（電子日誌）
- `ej_batch`: id, tenant_id, device_id, batch_id, time_range, line_count, sha256, blob_ref(MinIO), enc, integrity_status。
- `ej_entry`: id, batch_id, device_id, line_no, parsed(jsonb), rrn, stan, raw_ref。
- EJ 原始 blob 存物件儲存；解析後 entry 供 viewer/對帳。

### `switch_record`（轉接交易, ISO 8583 匯入）
- `id, tenant_id, device_id, rrn, stan, amount, response_code, occurred_at, raw(jsonb)`。

### `core_banking_record`（核心入帳）
- `id, tenant_id, rrn, stan, account_token, posted_amount, posted_at, status, raw(jsonb)`。

### `settlement_batch`（日結）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id, business_date | |
| ej_total, switch_total, core_total | 三方彙總 |
| cash_dispensed | 由 cash_ledger 取得 |
| variance | 差異 |
| status | `open/reconciled/exception` |

### `recon_match`（對帳結果）
| 欄位 | 說明 |
|---|---|
| id, tenant_id | |
| canonical_key | rrn+stan+amount+時窗 |
| ej_ref / switch_ref / core_ref | 三來源連結 |
| match_state | `Matched/EJ-only/Switch-only/Core-only/Amount-mismatch/Timeout-reversal` |
| variance | |
| resolved_state | 見狀態機（35）|

### `dispute`（差錯 / 爭議案件）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, recon_match_id, device_id | |
| txn_refs (jsonb) | 關聯交易 |
| status | `Open/UnderReview/Resolved` |
| resolution | `Adjusted/WrittenOff/CustomerCredited` |
| assignee, notes | |
| opened_at, resolved_at | |

## 關聯

```
device 1──* transaction（時序）
device 1──* ej_batch 1──* ej_entry
switch_record / core_banking_record  ──canonical_key──  recon_match
recon_match 1──0..1 dispute
device 1──* settlement_batch（每日）
```

## 對帳資料流（摘要，詳見 `02-integration/23`）

1. EJ、Switch、Core 三來源正規化為 canonical txn。
2. 以 `rrn(+stan+amount+時窗)` 比對 → 產生 `recon_match` 分類。
3. 不符 → `dispute` 進差錯佇列。
4. 日結 `settlement_batch` 交叉 `cash_ledger` 出鈔實體面。

## 安全與保留

- 全程使用 `card_token`，不存明文 PAN（PCI，見 `60`）。
- EJ/交易/對帳保留期依金管會/銀行政策（見 `61`），blob 不可變 + legal hold。
- **EJ 存取需寫稽核**（`audit_log` action=`ej.view`）。

## 索引建議

- `transaction(tenant_id, device_id, time desc)`、`transaction(tenant_id, rrn)`。
- `recon_match(tenant_id, match_state)`、`dispute(tenant_id, status)`。
