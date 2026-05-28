---
title: ADR-003 PostgreSQL + TimescaleDB
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, Database, PostgreSQL, TimescaleDB]
---

# ADR-003：主資料庫採 PostgreSQL + TimescaleDB

## 狀態
Accepted（draft-v1）

## 背景
系統同時有：關聯式主檔/生命週期/案件，以及高頻時序（狀態事件、現金水位、交易指標）。需控 on-prem 營運與授權成本。

## 決策
以 **PostgreSQL + TimescaleDB 擴充**為主：關聯式資料用標準表，時序資料用 hypertable + continuous aggregate + retention。
**SQL Server 為 fallback**（銀行強制時），以 EF Core provider 抽象切換。

## 理由
- **單一引擎**兼顧關聯式 + 時序 → 少一套 DB 要營運/備援/認證。
- 複雜查詢（join/window/地理）優於純時序庫（如 InfluxDB）。
- 避免大規模 on-prem 的 SQL Server 每核授權成本。

## 取捨
- 極端時序寫入規模下，專用時序庫/ClickHouse 可能更省；但本場景查詢複雜度與營運簡化更重要。
- 綁定 Timescale 擴充；以 SQL migration 管理 hypertable（EF 之外）。

## 影響
- 資料模型時序切分（`30` §6）、效能（`62`）、攝取投影（`21`）。
