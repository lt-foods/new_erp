---
title: 資料模型 — M4 故障告警與維修工單
module: AFMP / DataModel / Maintenance
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [DataModel, Maintenance, Incident, WorkOrder, SLA]
---

# 資料模型：M4 故障告警與維修工單（Maintenance）

## 實體一覽

### `fault`（故障 / 告警）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| fault_code | 標準化故障碼 |
| component | dispenser/cardReader/… |
| severity | `critical/major/minor` |
| source | `agent/rule/ml` |
| dedup_key | 去重鍵（device+code+window）|
| detected_at | |
| vendor_code, detail | |
| incident_id | 關聯事件（可為 null 待關聯）|

### `incident`（事件，關聯一或多筆 fault）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, device_id | |
| title, classification | 自動/人工分類 |
| severity | |
| status | 見狀態機（35）|
| sla_policy_id | 適用 SLA |
| sla_response_due / sla_resolve_due | 計時目標 |
| opened_at, resolved_at, closed_at | |
| is_recurring | 重複故障標記 |

### `work_order`（維修工單）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, incident_id, device_id | |
| assignee_type | `engineer/vendor` |
| assignee_id | |
| type | `onsite/remote/preventive` |
| status | 見狀態機（35）|
| scheduled_at | |
| checklist (jsonb) | 作業項目 |
| parts_used (jsonb) | 零件 |
| resolution, signature_ref | 結案 + 簽核 |
| traveled_at/checked_in_at/checked_out_at | 外勤時點 |

### `engineer` / `vendor`
- `engineer`: id, tenant_id, name, skills(jsonb), region_id, contact, on_call。
- `vendor`: id, tenant_id, name, sla_terms(jsonb), coverage(region/model), contact。

### `part` / `rma_item`（零件 / 退修）
- `part`: id, tenant_id, sku, name, on_hand, location。
- `rma_item`: id, tenant_id, part_id, serial, work_order_id, status, warranty_until。

### `sla_policy`（SLA 政策）
| 欄位 | 說明 |
|---|---|
| id, tenant_id, name | |
| match (jsonb) | 適用條件（severity/region/vendor）|
| response_target_min | 回應時限 |
| resolve_target_min | 解決時限 |
| escalation_policy_id | 升級策略（見 `51`）|

### `incident_event`（事件歷程, append-only）
- `id, incident_id, time, actor, from_state, to_state, note`：完整生命週期稽核（驅動 MTTR/SLA 計算）。

## 關聯

```
device 1──* fault *──1 incident 1──* work_order
incident 1──* incident_event（append-only）
work_order *──1 (engineer|vendor)
work_order 1──* rma_item *──1 part
incident *──1 sla_policy 1──1 escalation_policy
```

## 衍生

- **MTTR**：`incident_event` 之 `New→Resolved` 時長（per 故障類）。
- **SLA 達成**：`sla_resolve_due` vs `resolved_at`。
- **重複故障分析**：滾動視窗對 `(device_id, fault_code)` 群聚 → `is_recurring`，找慢性機台/系統性零件失效。
- **自動派工**：依 `engineer.skills/region` + `vendor.coverage` + SLA 配對（規則 v1，ML 優化 v2）。

## 故障 → 事件 去重/關聯規則

1. `fault` 以 `dedup_key`（device+code+時窗）抑制重複。
2. 同機台短時間多 fault → 關聯到同一 `incident`（避免工單爆量）。
3. 嚴重度由最高 fault 決定；新增更嚴重 fault 可升級事件嚴重度。

## 索引建議

- `fault(tenant_id, device_id, detected_at desc)`、`fault(tenant_id, dedup_key)`。
- `incident(tenant_id, status)`、`incident(tenant_id, sla_resolve_due)`。
- `work_order(tenant_id, assignee_id, status)`。
