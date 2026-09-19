"use client";

import { useMemo } from "react";
import { useAuth } from "@/components/AuthProvider";

/**
 * 員工「功能權限」— role 之外再掛一層、可個別授予特定人的細粒度開關。
 *
 * 存在 JWT 的 app_metadata.perms（字串陣列），由 owner/admin 經
 * rpc_update_staff_perms 設定（見 supabase/migrations/20260803000000_staff_feature_perms.sql）。
 * 使用者自己改不到，但**改完要重新登入 / token refresh 才會進 JWT**。
 *
 * 新增權限時：這裡加一筆 + migration 的 _is_valid_staff_perm 白名單加同一個 key。
 */
export const ALL_STAFF_PERMS = [
  {
    key: "orders_pivot_all_stores",
    label: "訂單樞紐：檢視所有門市",
    desc: "分店帳號在「訂單 — 樞紐表」不再被鎖在自己那間店，可切換／同時檢視每一間店。",
  },
  {
    key: "orders_edit_amount",
    label: "訂單金額：可改單價與折扣",
    desc: "分店帳號可修改自己店訂單的單價、整單折扣、單品折扣。所有改動都會記進稽核紀錄。",
  },
  {
    key: "line_notes_view",
    label: "LINE 記事本：可檢視、處理留言、指定團",
    desc: "非總部帳號可打開「LINE 記事本」頁面看貼文與留言加單狀況，處理留言（重試／指定會員／已解決／忽略），並把未認出團的貼文指定到某一團。發文、讀留言、刪貼文、帳號登入仍只有總部能操作；分店帳號只看得到總部社群與自己店的團。",
  },
] as const;

export type StaffPerm = (typeof ALL_STAFF_PERMS)[number]["key"];

const PERM_LABEL: Record<string, string> = Object.fromEntries(
  ALL_STAFF_PERMS.map((p) => [p.key, p.label]),
);

export function permLabel(key: string): string {
  return PERM_LABEL[key] ?? key;
}

/** 把 app_metadata.perms（unknown）正規化成字串 Set；非陣列一律視為沒有權限 */
export function parsePerms(raw: unknown): Set<string> {
  if (!Array.isArray(raw)) return new Set();
  return new Set(raw.filter((x): x is string => typeof x === "string"));
}

/** 目前登入者被授予的功能權限 */
export function useStaffPerms(): Set<string> {
  const { user } = useAuth();
  return useMemo(() => parsePerms(user?.app_metadata?.perms), [user]);
}

/** 目前登入者是否有某項功能權限 */
export function useHasStaffPerm(perm: StaffPerm): boolean {
  return useStaffPerms().has(perm);
}
