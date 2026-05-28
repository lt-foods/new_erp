---
title: 部署拓撲 — On-prem 與 SaaS
module: AFMP / Architecture
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Deployment, OnPrem, SaaS, HA, K8s]
---

# 部署拓撲（Deployment Topology）

決策依據見 [ADR-001 多租戶/代管](../decisions/ADR-001-multitenancy-hosting.md)。
同一套產物，兩種拓撲；皆以 `TenantId` 貫穿。

## 1. 拓撲 A — MDS 私雲多租戶（SaaS）

適用：接受代管/私雲的中小型銀行，或 MDS 統一營運。

```
              Internet / 銀行專線(VPN/MPLS)
                        │
                 ┌──────▼──────┐
                 │  L4 LB / WAF │
                 └──────┬──────┘
        ┌───────────────┼────────────────┐
   ┌────▼────┐    ┌─────▼─────┐     ┌─────▼─────┐
   │ Ingestion│×N  │  API/Web  │×N   │  Workers  │×N
   │ Gateway  │    │  (SignalR)│     │           │
   └────┬─────┘    └─────┬─────┘     └─────┬─────┘
        └───────── RabbitMQ 叢集 ──────────┘
                        │
   ┌──────────────┬─────┴───────┬──────────────┐
   │ PostgreSQL    │  Redis 叢集  │  MinIO 叢集   │
   │ +Timescale    │             │              │
   │ 主 + 同步副本   │             │              │
   │ (Patroni)     │             │              │
   └──────────────┘             └──────────────┘
```

- 部署：Kubernetes（多節點），各容器多副本。
- 多租戶隔離：共用 DB + row-level `TenantId` filter；大型銀行可升級為 **schema-per-tenant**；blob 以 tenant 前綴 + 各自加密金鑰。
- 跨租戶資料**永不**混查（global query filter + 架構/整合測試把關）。

## 2. 拓撲 B — 各銀行 On-prem / 私有雲單租戶

適用：金管會資料落地/委外資安要求嚴格的大型銀行；部署於行內網段。

```
                行內網段（DMZ + 內網）
   ┌────────────── DMZ ──────────────┐
   │   Ingestion Gateway (wss/mTLS)    │  ← 僅此對機端開放
   └───────────────┬──────────────────┘
   ┌───────────────▼────── 內網 ───────────────────┐
   │  API/Web · Workers · RabbitMQ · Redis          │
   │  PostgreSQL+Timescale(主+副本) · MinIO · Vault   │
   └────────────────────────────────────────────────┘
```

- 同一份容器映像/Helm chart，`TenantId` 釘死為單一銀行。
- 兩種規模：
  - **大型**：K8s（行內）或 VM 叢集。
  - **小型**：單機 Docker Compose（API+Workers+Gateway+PG+Redis+RabbitMQ+MinIO），降低營運門檻。
- 對外僅 Ingestion Gateway 置於 DMZ；管理介面限內網/VPN。

## 3. 共用設計原則

- **環境同構**：dev/stage/prod 與 on-prem/SaaS 用相同映像、以設定切換（12-factor）。
- **設定來源**：環境變數 + Vault；無敏感值落 git。
- **資料落地**：on-prem 全部資料留在行內；SaaS 依銀行所在地選區。
- **網路**：機端→Gateway 走 wss/mTLS（agent 主動外連，機台不開 inbound port）。

## 4. CI/CD 與 IaC

| 項目 | 工具 |
|---|---|
| CI | GitHub Actions / Azure DevOps |
| 容器登錄 | 私有 registry |
| 封裝 | Docker 多階段建置 + Helm chart |
| 發布策略 | blue-green / 滾動；DB migration 先行（向後相容）|
| 雲 IaC | Terraform |
| On-prem 機器佈建 | Ansible（VM provisioning + compose/k8s bootstrap）|

## 5. 升級與 migration 流程

1. DB migration 設計為**向後相容**（先加欄/表，雙寫過渡，再切換）。
2. 先部署 Workers/Gateway（消費端容忍新舊事件），再部署 API/Web。
3. on-prem 提供離線升級包（映像 + chart + migration 腳本 + runbook）。

## 6. 容量規劃起點（per 租戶）

- 2 萬台機台、50–80k msg/s 持續攝取、EJ 每日數十 GB（詳見 `06-nfr-compliance/62`）。
- Gateway 無狀態、依連線數水平擴展；DB 以 Timescale 分區 + continuous aggregate 控成本。
