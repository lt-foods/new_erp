"use client";

// 試用租戶的前端控管（SaaS 化 Phase 2/3）
// - TrialBanner：status='trial' 時全站頂部顯示剩餘天數
// - TrialExpiredScreen：status='suspended'/'deleted' 時整頁擋住，
//   提供登出與「刪除我的試用資料」（owner 限定，輸入商家名稱確認後
//   呼叫 tenant-purge edge function）
// 後端另有防線：_current_tenant_id() 對 suspended/deleted 租戶 raise。

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { useAuth, type TenantInfo } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

export function trialDaysLeft(tenant: TenantInfo): number | null {
  if (!tenant.trial_expires_at) return null;
  const ms = new Date(tenant.trial_expires_at).getTime() - Date.now();
  return Math.max(0, Math.ceil(ms / 86400_000));
}

export function TrialBanner({ tenant }: { tenant: TenantInfo }) {
  const days = trialDaysLeft(tenant);
  if (days === null) return null;
  return (
    <div className="border-b border-amber-200 bg-amber-50 px-4 py-1.5 text-center text-xs text-amber-800 print:hidden dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
      試用期剩 <span className="font-semibold">{days}</span> 天
      {days <= 3 && "，到期後將暫停操作（資料保留）"}
    </div>
  );
}

export function TrialExpiredScreen({ tenant }: { tenant: TenantInfo }) {
  const router = useRouter();
  const { user, signOut } = useAuth();
  const isOwner = (user?.app_metadata?.role as string | undefined) === "owner";
  const [confirmName, setConfirmName] = useState("");
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showDelete, setShowDelete] = useState(false);

  async function onLogout() {
    await signOut();
    router.replace("/login");
  }

  async function onDelete(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setDeleting(true);
    const { data, error: err } = await getSupabase().functions.invoke<{
      ok?: boolean;
      error?: string;
    }>("tenant-purge", { body: { confirm_name: confirmName } });
    if (err) {
      const ctx = (err as { context?: Response }).context;
      let msg = err.message;
      if (ctx) {
        try {
          const body = (await ctx.json()) as { error?: string };
          if (body?.error) msg = body.error;
        } catch {
          /* noop */
        }
      }
      setDeleting(false);
      setError(msg);
      return;
    }
    if (!data?.ok) {
      setDeleting(false);
      setError(data?.error || "刪除失敗，請稍後再試");
      return;
    }
    // 帳號已刪，登出回登入頁
    await signOut();
    router.replace("/login");
  }

  return (
    <div className="flex flex-1 items-center justify-center bg-zinc-50 p-6 dark:bg-zinc-950">
      <div className="w-full max-w-md space-y-5 rounded-lg border border-zinc-200 bg-white p-8 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <div className="space-y-1">
          <h1 className="text-2xl font-semibold">試用已到期</h1>
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            「{tenant.name}」的免費試用已結束。你的資料都還在，
            想繼續使用請聯絡我們開通正式方案。
          </p>
        </div>

        <SpinButton
          type="button"
          onClick={onLogout}
          className="w-full rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          登出
        </SpinButton>

        {isOwner && (
          <div className="space-y-3 border-t border-zinc-200 pt-4 dark:border-zinc-800">
            {!showDelete ? (
              <SpinButton
                type="button"
                onClick={() => setShowDelete(true)}
                className="text-xs text-red-600 underline hover:text-red-700 dark:text-red-400"
              >
                不再使用了？刪除我的試用資料
              </SpinButton>
            ) : (
              <form onSubmit={onDelete} className="space-y-3">
                <p className="text-xs text-zinc-600 dark:text-zinc-400">
                  這會<span className="font-semibold text-red-600 dark:text-red-400">永久刪除</span>
                  「{tenant.name}」的全部資料與帳號，無法復原。
                  確定的話請輸入完整商家名稱：
                </p>
                <input
                  type="text"
                  required
                  value={confirmName}
                  onChange={(e) => setConfirmName(e.target.value)}
                  placeholder={tenant.name}
                  className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
                />
                {error && (
                  <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
                    {error}
                  </p>
                )}
                <SpinButton
                  type="submit"
                  disabled={deleting || confirmName !== tenant.name}
                  className="w-full rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white transition hover:bg-red-700 disabled:opacity-50"
                >
                  {deleting ? "刪除中…" : "永久刪除全部資料"}
                </SpinButton>
              </form>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
