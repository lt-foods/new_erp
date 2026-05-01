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

export function canSeeCost(role: Role | null): boolean {
  if (role === null) return false;
  return HQ_ROLES.includes(role);
}

export function canSeeBranch(role: Role | null): boolean {
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
