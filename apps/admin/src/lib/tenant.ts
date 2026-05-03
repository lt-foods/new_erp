// 集中管理 tenant 顯示名稱。
// 目前 single-tenant，靠 NEXT_PUBLIC_TENANT_NAME env 切換；
// 未來若要 multi-tenant，把 getTenantName() 改成 DB query 即可（呼叫端不用改）。

const DEFAULT_TENANT_NAME = "包子媽生鮮小舖";

export function getTenantName(): string {
  return process.env.NEXT_PUBLIC_TENANT_NAME || DEFAULT_TENANT_NAME;
}

export function getAdminTitle(): string {
  return `${getTenantName()}管理頁面`;
}
