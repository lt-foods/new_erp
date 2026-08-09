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

// 總倉層級：可進入總倉收件匣 / 採購請購單等總倉專屬頁面。
// 分店角色（store_manager / store_staff）不屬於此群，看到的 TR/PR 編號應為純文字、不可點。
export function isHqRole(role: Role | null): boolean {
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

// 復原會員合併（rpc_unmerge_member）。會搬訂單與餘額，所以不是人人可按。
// 對齊 20260809000070 的 role gate：總部層級 + 店長；store_staff 不給。
// ⚠ 店長還多一層「只能動自己店的會員」，那要比對 app_metadata.stores，
//   單看 role 判不出來 —— 呼叫端要另外用 useMyStores() 收斂（見 MemberDetail）。
const UNMERGE_ROLES: Role[] = ["owner", "admin", "hq_manager", "store_manager", ""];

export function canUnmergeMember(role: Role | null): boolean {
  if (role === null) return false;
  return UNMERGE_ROLES.includes(role);
}

/**
 * 這個帳號被指派到哪幾家店（app_metadata.stores，存的是**店名**）。
 * 非分店帳號通常沒有這個欄位 → 回空陣列。
 * 線上 33 個 staff 帳號沒有任何一個有 store_id，分店身分一律看這裡（見 20260808000020）。
 */
export function useMyStores(): string[] {
  const [stores, setStores] = useState<string[]>([]);

  useEffect(() => {
    const sb = getSupabase();
    let active = true;
    const read = (meta: Record<string, unknown> | undefined) => {
      const raw = meta?.stores;
      return Array.isArray(raw) ? raw.filter((s): s is string => typeof s === "string") : [];
    };
    sb.auth.getSession().then(({ data }) => {
      if (!active) return;
      setStores(read(data.session?.user?.app_metadata as Record<string, unknown> | undefined));
    });
    const sub = sb.auth.onAuthStateChange((_event, session) => {
      setStores(read(session?.user?.app_metadata as Record<string, unknown> | undefined));
    });
    return () => {
      active = false;
      sub.data.subscription.unsubscribe();
    };
  }, []);

  return stores;
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
