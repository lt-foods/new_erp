---
title: 攝取管線與高可用
module: AFMP / Integration
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Ingestion, HA, Idempotency, BackPressure, Outbox]
---

# 攝取管線與高可用（Ingestion & HA）

## 1. 攝取管線（核心原則：先落地、後計算）

```
Agent ──wss/mTLS──► Ingestion Gateway
                         │ 1. mTLS + 封套/schema 驗證
                         │ 2. 限流(Redis token bucket)
                         │ 3. 寫 inbound log（附加式、持久）★
                         │ 4. 回 ACK 給 agent  ← 此刻才算「收到」
                         ▼
                    inbound log（分區表 / 串流）
                         │ 5. 發布到 RabbitMQ（依 type 分 exchange）
                         ▼
        ┌────────────── Workers（consumer）──────────────┐
        │  狀態投影 │ 現金投影 │ 交易/EJ │ 故障→事件 │ 安全  │
        └───────────────────┬───────────────────────────┘
                            ▼
        現況表（projection）+ 時序(hypertable) + ledger（append-only）
                            │
                       SignalR 推前端（即時看板）
```

**關鍵：** Gateway 收到 → 驗證 → **寫 inbound log → 立即 ACK**；後續計算全部非同步。
攝取與運算解耦，使下游壅塞/重啟不影響收件，且絕不丟資料。

## 2. inbound log 設計

- 附加式 `device_inbound`（Timescale hypertable，按時間分區），欄位：`tenantId, deviceId, msgId, seq, type, schemaVer, occurredAt, receivedAt, payload(jsonb), processedAt`。
- 兼具：**抗壓緩衝**、**重播來源**（投影重建）、**稽核**。
- 保留策略：原始 inbound 短期（如 7–30 天）+ 正規化後長期保存於各模組表/blob。

## 3. 冪等、排序、缺漏

| 機制 | 做法 |
|---|---|
| 去重 | 唯一索引 `(tenantId, deviceId, msgId)`；重複直接忽略 |
| 排序 | per-device `seq` 單調；consumer 以 `seq` 處理 |
| ledger append | 以 `(deviceId, seq)` 防重，確保現金/交易帳不重覆 |
| 缺漏偵測 | 發現 seq 跳號 → 記 `telemetry_gap` 事件 + 觸發補拉（狀態快照 / `RequestEjUpload`）|
| 投影冪等 | upsert-by-key；同一事件重放結果一致 |

## 4. 背壓（Back-pressure）

- **wss 層**：WebSocket credit 流控，agent 依信用發送。
- **Gateway 層**：bounded channel（有界佇列）；滿載時仍以寫 inbound log 為優先（不丟），下游慢慢追。
- **限流**：per-device Redis token bucket，含「異常爆量」熔斷（單台超閾值暫時拒收並告警）。

## 5. 可靠事件發布：Transactional Outbox

- Workers 在同一 DB 交易內：寫業務狀態 + 寫 outbox 列。
- 由 outbox dispatcher（MassTransit 支援）發布整合事件到 RabbitMQ，確保「狀態變更」與「事件發布」原子一致，無丟失/重複（消費端冪等）。

## 6. 高可用（HA）

| 元件 | HA 策略 |
|---|---|
| Ingestion Gateway | 無狀態、多副本、L4 LB；單一 wss 連線 sticky 到一實例；實例掛 → agent 重連到其他實例 |
| API/Web | 無狀態多副本；SignalR 以 Redis backplane 跨實例 |
| Workers | 多副本 + 競爭消費（competing consumers）；冪等保證可安全重啟 |
| RabbitMQ | 叢集 + quorum queue |
| PostgreSQL/Timescale | 主 + 同步副本（Patroni 自動切換）+ 非同步 DR 副本 |
| Redis | 叢集/哨兵 |
| MinIO | 分散式叢集（EC 編碼）|

- **故障切換不丟遙測**：inbound log 持久 + agent at-least-once 重送 + 去重。
- 目標：平台 **99.9%**、**RTO ≤ 1h、RPO ≤ 5min**（細節見 `06-nfr-compliance/62`）。

## 7. 吞吐設計點

- 規模：2 萬台/租戶；心跳+狀態 ~1–3 msg/s/台尖峰 → 設計 **50–80k msg/s 持續、150k 突發**。
- EJ：每日數十 GB（走 REST + 物件儲存，不佔 wss）。
- 看板查詢 < 2s：由 projection + Timescale continuous aggregate + Redis 快取供應。

## 8. 安全邊界

- Gateway 為唯一對機端開放面，置於 DMZ；僅 wss(443)/REST(443) + mTLS。
- 內部元件不對外；管理面限內網/VPN。
- 所有 inbound 經 schema 驗證 + 大小上限 + 速率限制，抵禦畸形/灌包。
