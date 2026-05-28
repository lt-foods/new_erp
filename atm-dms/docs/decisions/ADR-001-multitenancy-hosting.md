---
title: ADR-001 多租戶與代管模式
module: AFMP / ADR
status: accepted
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [ADR, MultiTenancy, Hosting]
---

# ADR-001：多租戶與代管模式

## 狀態
Accepted（draft-v1）

## 背景
兩股需求衝突：(a) MDS 想跨多家銀行取得營運槓桿；(b) 台灣銀行受金管會委外/資安規範，常要求資料落地與 on-prem/私有雲。

## 決策
**單一程式碼庫、設計即租戶感知（tenant-aware by design）**，每張業務表帶 `TenantId`，支援兩種部署拓撲：
1. **MDS 私雲多租戶 SaaS**（共用控制平面）。
2. **各銀行單租戶 on-prem/私有雲**（同一產物、`TenantId` 釘死）。

EF Core global query filter 強制租戶隔離；大型租戶可升級 schema-per-tenant。

## 理由
- 一套產品服務兩種模式，避免分叉。
- 滿足金管會落地需求同時保留 MDS SaaS 槓桿。

## 取捨
- 「處處帶租戶」需紀律：任何查詢不得省略租戶過濾 → 以架構測試 + 整合測試把關。
- 共用 DB 多租戶需嚴格隔離；超大租戶以 schema 隔離平衡。

## 影響
- 資料模型（`30`）、部署（`12`）、授權（`50`）皆據此。
