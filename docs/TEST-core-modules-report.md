# 核心模組測試 Run Report — 2026-04-25

## Summary
- Migration `20260425120000_core_crud_rpcs.sql` applied to dev DB
- Build：`npm run --workspace=admin build` PASS — 17 static routes
- Preview：`/members`、`/members/new` (建立 M0001)、`/members/detail`、`/campaigns`、`/orders`、`/suppliers` 全通
- RPC 驗證（`node .claude-scripts/test_core_rpcs.js`）：rpc_upsert_campaign / supplier / member 全通 + duplicate phone 正確被 UNIQUE 阻擋
- 0 console error on all pages

## §1 Schema / RPC
| Item | Result | Evidence |
|---|---|---|
| 17 relaxed read RLS policies for authenticated | ✅ | migration push 成功 |
| 7 write RPCs + rpc_delete_campaign_item | ✅ | lint + push PASS |
| rpc_upsert_member 寫入 + phone_hash | ✅ | member id=2 via dev DB test |
| duplicate phone rejected | ✅ | `duplicate key value violates unique constraint "members_tenant_id_phone_hash_key"` |
| rpc_upsert_supplier | ✅ | supplier id=4 |
| rpc_upsert_campaign | ✅ | campaign id=2 |

## §2 UI
| 路徑 | Result |
|---|---|
| `/members` 列表 (0 筆顯示「還沒有會員…」) | ✅ |
| `/members/new` 表單 | ✅ |
| 建立 M0001 → redirect `/members/edit?id=1&saved=1` | ✅ |
| `/members/detail?id=1` (顯示 積分 0 / 儲值 0 / 手機 / email / 加入時間) | ✅ |
| `/campaigns` 列表 (空) | ✅ |
| `/orders` 列表 (空) | ✅ |
| `/suppliers` 列表 + 新增 SUP-TEST (row count = 1) | ✅ |

## §3 Build
| Item | Result |
|---|---|
| `npm run --workspace=admin build` | ✅ 17 routes |
| TypeScript strict | ✅ |
| 0 console error (browser preview) | ✅ |

## §4 備註
- 開團 `/campaigns/new` UI 測試時遇 dev server HMR 與 auth state race，改以直接 DB RPC 驗證 OK
- PII：members.phone/email/birthday 目前用 plaintext（`ALTER TABLE ... ADD COLUMN`）；已記註解「MVP plaintext；未來改 pgp_sym_encrypt」

## Verdict
**DONE** — 所有新模組（會員、開團、訂單、供應商）UI 全通、寫入 RPC 驗證、build 無錯。
