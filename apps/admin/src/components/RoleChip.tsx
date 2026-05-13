"use client";

const ROLE_META: Record<string, { label: string; cls: string }> = {
  owner:         { label: "擁有者",       cls: "bg-violet-100 text-violet-700 dark:bg-violet-950 dark:text-violet-300" },
  admin:         { label: "系統管理員",   cls: "bg-sky-100 text-sky-700 dark:bg-sky-950 dark:text-sky-300" },
  hq_manager:    { label: "總部經理",     cls: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300" },
  hq_accountant: { label: "總部會計",     cls: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300" },
  purchaser:     { label: "採購",         cls: "bg-teal-100 text-teal-700 dark:bg-teal-950 dark:text-teal-300" },
  assistant:     { label: "總部助理",     cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300" },
  store_manager: { label: "店長",         cls: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300" },
  store_staff:   { label: "店員",         cls: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300" },
  disabled:      { label: "已停用",       cls: "bg-zinc-200 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-500 line-through" },
  "":            { label: "（未設定）",    cls: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400" },
};

export function roleLabel(role: string | null | undefined): string {
  return (ROLE_META[role ?? ""] ?? ROLE_META[""]).label;
}

export const ALL_ROLES = [
  "owner","admin","hq_manager","hq_accountant",
  "purchaser","assistant",
  "store_manager","store_staff",
  "disabled",
] as const;

export type StaffRole = typeof ALL_ROLES[number] | "";

export function RoleChip({ role }: { role: string | null | undefined }) {
  const m = ROLE_META[role ?? ""] ?? ROLE_META[""];
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${m.cls}`}>{m.label}</span>;
}
