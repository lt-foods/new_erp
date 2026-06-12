// 集中管理 tenant 顯示名稱。
// multi-tenant（SaaS 化 Phase 0）後，登入後的名稱以 DB 為主：
// useAuth().tenant?.name（來自 rpc_get_my_tenant）→ fallback 本檔 env 名稱。
// 這裡保留 env 版本給「登入前」的場景（login 頁、root layout metadata）。

const DEFAULT_TENANT_NAME = "包子媽生鮮小舖";

export function getTenantName(): string {
  return process.env.NEXT_PUBLIC_TENANT_NAME || DEFAULT_TENANT_NAME;
}

export function getAdminTitle(): string {
  return `${getTenantName()}管理頁面`;
}
