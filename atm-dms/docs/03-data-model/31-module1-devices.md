---
title: 資料模型 — M1 機台主檔與狀態監控
module: AFMP / DataModel / Devices
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [DataModel, Devices, Status]
---

# 資料模型：M1 機台主檔與狀態監控（Devices）

## 實體一覽

### `device`（機台主檔）
| 欄位 | 型別 | 說明 |
|---|---|---|
| id | uuid | PK |
| tenant_id | text | 租戶 |
| device_code | text | 對外機台編號（=合約 deviceId）|
| serial_no | text | 序號 |
| vendor | text | Hitachi/NCR/Diebold… |
| model | text | 型號 |
| device_type | enum | `withdrawal/cash_recycling/deposit/avm` |
| site_id | uuid | 所在據點 |
| owner_region_id | uuid | 負責區域 |
| firmware_ver / agent_ver | text | 版本 |
| status | enum | 見狀態機（35）|
| health_score | int | 0–100，由模組狀態彙算 |
| install_date / decommission_date | date | |
| last_heartbeat_at | timestamptz | 生死判定 |

### `site`（據點 / Location）
| 欄位 | 說明 |
|---|---|
| id, tenant_id | |
| name, branch_code | 分行/據點 |
| address, lat, lng | 地理（地圖佈點）|
| region_id | 區域 |
| op_hours | 營運時段（jsonb）|
| placement | `indoor/outdoor/lobby/drive-thru` |

### `region`（區域階層）
- `id, tenant_id, parent_id, name`；支援多層（總行→區域中心→分行）。

### `device_module`（週邊模組現況）
| 欄位 | 說明 |
|---|---|
| id, device_id | |
| module | `dispenser/depositor/cardReader/epp/receipt/network/supervisorDoor` |
| state | `ok/warn/fault/offline` |
| vendor_code | 原廠碼 |
| updated_at | |

### `device_status_event`（狀態事件，append-only, hypertable）
| 欄位 | 說明 |
|---|---|
| time | 事件時間（occurredAt）|
| tenant_id, device_id, seq | |
| module | 變化的模組（或 device 整體）|
| state, prev_state | |
| source | `agent/rule/derived` |
| raw_code, detail | |

> 妥善率、上下線時長皆由此事件流計算（見 `00-overview/01` KPI）。

### `device_group`（機群 / 派送鎖定）
- `id, tenant_id, name, criteria(jsonb: region/model/owner)` 或明列成員 `device_group_member(group_id, device_id)`。
- 供軟體派送、內容推播、白名單政策鎖定（見 `44`）。

### `device_health_snapshot`（健康度時序, hypertable, 選配）
- 定期彙算的 health_score 快照，供趨勢圖。

## 關聯

```
region 1──* site 1──* device 1──* device_module
device 1──* device_status_event（append-only）
device_group *──* device（via member 或 criteria）
device.site_id → site ; device.owner_region_id → region
```

## 投影與重建

- `device.status` / `device_module.state` / `health_score` 皆為 `device_status_event` + heartbeat 的**投影**，可重放重建。
- `last_heartbeat_at` 由 Heartbeat 更新；逾 N 次缺心跳 → 投影為 `Offline`（狀態機見 `35`）。

## 索引建議

- `device(tenant_id, status)`、`device(tenant_id, site_id)`、`device(tenant_id, device_code)` 唯一。
- `device_status_event(tenant_id, device_id, time desc)`；hypertable 依 time 分區。
