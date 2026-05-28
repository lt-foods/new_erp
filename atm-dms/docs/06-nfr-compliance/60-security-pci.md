---
title: 安全與 PCI
module: AFMP / NFR
status: draft-v1
owner: cktalex
created: 2026-05-28
updated: 2026-05-28
tags: [Security, PCI-DSS, Encryption, KeyManagement, Whitelisting]
---

# 安全與 PCI（Security & PCI-DSS）

## 1. PCI 範圍最小化（核心策略）

- **卡號（PAN）於機端即代碼化/遮罩**，平台**不接收、不儲存、不記錄**明文 PAN（合約硬性要求，見 `20` §3.4 / `23`）。
- 對帳/查詢全程使用 `card_token`。
- 結果：大幅縮小平台的 PCI-DSS 適用範圍。

## 2. 加密

| 面向 | 做法 |
|---|---|
| 傳輸 | TLS 1.2+；機端 wss/REST 採 **mTLS** |
| 靜態 | AES-256 at rest（DB TDE / 欄位級加密敏感欄）|
| EJ blob | 加密儲存（機端加密 + 平台側金鑰）|
| 租戶金鑰 | per-tenant 金鑰，隔離 |
| 金鑰管理 | **Vault / Key Vault**，定期輪替；機端對齊 TR-34 |
| 秘密 | 不落 git/log；統一 Vault |

## 3. 網路與邊界

- Ingestion Gateway 為唯一對機端開放面（DMZ）；管理面限內網/VPN。
- 網段分離（DMZ / app / data）；最小開放埠。
- WAF + L4 LB；per-device 限流（Redis token bucket）。

## 4. 程式白名單（端點安全）

- 政策推送 + 機端封鎖未授權執行 + 違規上報（見 `44` C）。
- 違規證據保留（合規舉證）。

## 5. 應用安全

- 最小權限 RBAC（見 `50`）；危險操作 MFA + maker-checker。
- 輸入驗證（schema）、輸出編碼、參數化查詢（防注入）。
- 相依套件掃描（SCA）、SAST/DAST 納 CI。
- 日誌不含 PAN/PIN/秘密；敏感欄遮罩。

## 6. 稽核與不可否認

- 全特權操作 + EJ 存取寫 `audit_log`（hash chain 防竄改，見 `30` §3）。
- 時間同步（NTP）；事件時間 + 落地時間雙記。

## 7. 機端身分與信任

- 每台唯一 client 憑證；納管簽發短期憑證 + 輪替（見 `20` §5）。
- `(憑證 ↔ deviceId ↔ tenantId)` 綁定驗證。

## 8. 對標 / 法遵銜接

- 對應金管會資安規範與 PCI-DSS；零信任路線（Phase 3）見 `61`。
- 滲透測試/弱掃證據追蹤納合規（見 `61`）。
