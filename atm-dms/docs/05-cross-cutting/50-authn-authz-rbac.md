---
title: 認證、授權與 RBAC
module: AFMP / CrossCutting
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Auth, RBAC, MultiTenancy, OIDC, MFA]
---

# 認證、授權與 RBAC

## 1. 認證（AuthN）

- **OIDC/OAuth2**：自架 **Duende IdentityServer**（on-prem 可自主），或聯邦銀行既有 IdP（OIDC/SAML，連 AD）。
- **MFA**：特權角色強制（MDS Operator、Bank Admin、Compliance、可調整現金/白名單者）。
- **SSO**：支援與行內 AD 單一登入（聯邦）。
- Token：短期 access token + refresh；claims 內含 `tenantId`、roles、resource scopes。

## 2. 授權（AuthZ）模型

**RBAC + 租戶範圍 + 資源範圍**，以**權限（permission）為基礎的政策**，不在程式裡比對 role 字串。

- 權限鍵範例：`device.read`、`device.manage`、`cash.adjust`、`replenishment.approve`、`ej.view`、`incident.assign`、`workorder.execute`、`distribution.rollout`、`whitelist.manage`、`dispute.resolve`、`audit.read`、`tenant.manage`。
- Role = 一組 permission。User 經 `UserRole` 取得 roles，且可附**資源範圍**（region/site 清單）。
- ASP.NET Core：以 policy + requirement/handler 實作（檢查 permission + tenant + resource scope）。

## 3. 角色（預設）

| 角色 | 範圍 | 代表權限 |
|---|---|---|
| `MdsPlatformOperator` | 跨租戶（平台營運）| 納管、平台健康、租戶管理（受限）|
| `BankAdmin` | 單租戶 | RBAC、主檔、派送/白名單政策 |
| `Ops/NOC` | 租戶或區域 | 看板、事件指派/派工、對帳例外 |
| `CashTeam` | 租戶或區域 | 現金、補鈔、cash.adjust、replenishment.approve |
| `FieldEngineer` | 指派工單 | workorder.execute、行動 app |
| `Vendor` | **限指派** | 只見自己被指派的工單/RMA |
| `Auditor` | 租戶（唯讀）| audit.read、唯讀全模組 |
| `Compliance` | 租戶 | 異常通報、dispute.resolve、報表 |

## 4. 多租戶隔離（授權面）

- `tenantId` **只**從驗證 token 解析，**絕不**取自 request body/query。
- 注入 `ITenantContext` → EF global query filter 自動套用（見 `30` §5）。
- 跨租戶角色（MDS Operator）需明確切換租戶情境，且操作全寫稽核。
- `Vendor` 為**資料最小化**典範：查詢再疊 `assignee_id = 自己`。

## 5. 稽核

- 所有特權操作、登入、角色變更、EJ 存取、設定/白名單/派送、現金調整、差錯解決 → `audit_log`（hash chain，見 `30` §3）。

## 6. 安全強化

- 最小權限預設；危險操作（cash.adjust、whitelist.manage、distribution.rollback）需 MFA + 二次確認，必要時雙人覆核（maker-checker）。
- Session/Token 失效、裝置綁定、異常登入偵測。
- 對應金管會權限控管與職能分離要求（見 `61`）。
