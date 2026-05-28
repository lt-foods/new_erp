---
title: ADR-002 模組化單體（非微服務）
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, ModularMonolith, Microservices]
---

# ADR-002：採模組化單體（v1）

## 狀態
Accepted（draft-v1）

## 背景
系統涉及攝取、即時、對帳、預測、工單等多領域；需考量銀行 on-prem 部署與營運成熟度。

## 決策
v1 採**模組化單體**：單一 ASP.NET Core 部署，模組（Devices/Cash/Transactions/Maintenance/...）以獨立 project 嚴格隔離，**不共用 entity**，以 MediatR 指令 + 內部整合事件通訊。
唯一例外：**Ingestion Gateway** 設計為獨立程序（同 solution、同合約），可於需要時拆出/獨立擴展。

## 理由
- on-prem 銀行營運/認證/稽核一個部署 + 一套 DB 遠比 service mesh 簡單。
- 模組邊界保留未來拆服務的選項（演進式架構）。
- Gateway 的擴展/可用性/攻擊面與管理 API 不同 → 預先可拆。

## 取捨
- 放棄微服務的獨立部署/擴展彈性（v1 不需）。
- 需以架構測試（NetArchTest/ArchUnitNET）強制模組邊界，否則單體易腐化。

## 影響
- 解決方案結構（`11`）、部署（`12`）、擴展（`62`）。
- 規模超標（攝取 >~100k msg/s）時，先拆 Gateway，再視需要拆其他模組。
