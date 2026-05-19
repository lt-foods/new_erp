"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

// JWT app_metadata.role values used across the project.
// Empty string ("") = legacy / dev admin without explicit role; treated as admin tier.
export type Role =
  | "owner"
  | "admin"
  | "hq_manager"
  | "hq_accountant"
  | "assistant"
  | "store_manager"
  | "store_staff"
  | "";

const HQ_ROLES: Role[] = ["owner", "admin", "hq_manager", "hq_accountant", ""];
const BRANCH_ROLES: Role[] = ["owner", "admin", "hq_manager", "hq_accountant", "store_manager", ""];
// 管理員層級：負責人(owner) + 管理員(admin) + 無顯式 role 的 legacy/dev admin("")
// 對齊 rpc_resync_campaign_from_product 的 server-side gate
const ADMIN_ROLES: Role[] = ["owner", "admin", ""];

export function isAdmin(role: Role | null): boolean {
  if (role === null) return false;
  return ADMIN_ROLES.includes(role);
}

export function canSeeCost(role: Role | null): boolean {
  if (role === null) return false;
  return HQ_ROLES.includes(role);
}

export function canSeeBranch(role: Role | null): boolean {
  if (role === null) return false;
  return BRANCH_ROLES.includes(role);
}

// 對齊 supabase/migrations/20260606000000_wallet_write_rpcs.sql 內 rpc_wallet_adjust 的 role gate
export function canAdjustWallet(role: Role | null): boolean {
  if (role === null) return false;
  return BRANCH_ROLES.includes(role);
}

export function useRole(): Role | null {
  const [role, setRole] = useState<Role | null>(null);

  useEffect(() => {
    const sb = getSupabase();
    let active = true;
    sb.auth.getSession().then(({ data }) => {
      if (!active) return;
      const meta = data.session?.user?.app_metadata as Record<string, unknown> | undefined;
      const raw = (meta?.role as string | undefined) ?? "";
      setRole(raw as Role);
    });
    const sub = sb.auth.onAuthStateChange((_event, session) => {
      const meta = session?.user?.app_metadata as Record<string, unknown> | undefined;
      const raw = (meta?.role as string | undefined) ?? "";
      setRole(raw as Role);
    });
    return () => {
      active = false;
      sub.data.subscription.unsubscribe();
    };
  }, []);

  return role;
}
