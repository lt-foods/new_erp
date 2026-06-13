"use client";

// 試用租戶自助註冊（SaaS 化 Phase 1）
// 呼叫公開 edge function trial-signup：建 tenant + owner 帳號 + seed 基礎資料，
// Supabase Auth 寄驗證信，驗完才能登入。樣式對齊 /login。

import { useState, type FormEvent } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

const inputCls =
  "w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

export default function SignupPage() {
  const [companyName, setCompanyName] = useState("");
  const [ownerName, setOwnerName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [done, setDone] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    const { data, error: err } = await getSupabase().functions.invoke<{
      ok?: boolean;
      error?: string;
    }>("trial-signup", {
      body: {
        company_name: companyName,
        owner_name: ownerName,
        email,
        password,
      },
    });
    setSubmitting(false);
    if (err) {
      // FunctionsHttpError：實際錯誤訊息在 response body 裡
      const ctx = (err as { context?: Response }).context;
      let msg = err.message;
      if (ctx) {
        try {
          const body = (await ctx.json()) as { error?: string };
          if (body?.error) msg = body.error;
        } catch {
          /* noop：保留原 message */
        }
      }
      setError(msg);
      return;
    }
    if (!data?.ok) {
      setError(data?.error || "註冊失敗，請稍後再試");
      return;
    }
    setDone(true);
  }

  if (done) {
    return (
      <div className="flex flex-1 items-center justify-center bg-zinc-50 p-6 dark:bg-zinc-950">
        <div className="w-full max-w-sm space-y-4 rounded-lg border border-zinc-200 bg-white p-8 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
          <h1 className="text-2xl font-semibold">驗證信已寄出 ✉️</h1>
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            我們已寄一封驗證信到 <span className="font-medium">{email}</span>。
            點擊信中連結完成驗證後，即可登入開始 14 天免費試用。
          </p>
          <Link
            href="/login"
            className="block w-full rounded-md bg-zinc-900 px-3 py-2 text-center text-sm font-medium text-white transition hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            前往登入
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-1 items-center justify-center bg-zinc-50 p-6 dark:bg-zinc-950">
      <div className="w-full max-w-sm space-y-6 rounded-lg border border-zinc-200 bg-white p-8 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
        <div className="space-y-1">
          <Link href="/welcome" className="mb-2 flex items-baseline gap-1.5 tracking-tight">
            <span className="flex items-center gap-1.5 text-sm font-bold text-zinc-900 dark:text-zinc-100">
              <span className="inline-block h-3.5 w-3.5 translate-y-0.5 rounded-[4px] bg-orange-600" />
              Gruppo
            </span>
            <span className="text-xs font-medium text-zinc-400">購寶</span>
          </Link>
          <h1 className="text-2xl font-semibold">免費試用 14 天</h1>
          <p className="text-sm text-zinc-500">
            建立你的商家後台，試用期內功能不設限
          </p>
        </div>

        <form onSubmit={onSubmit} className="space-y-4">
          <Field label="商家名稱">
            <input
              type="text"
              required
              maxLength={50}
              value={companyName}
              onChange={(e) => setCompanyName(e.target.value)}
              placeholder="例：小美生鮮舖"
              className={inputCls}
            />
          </Field>
          <Field label="姓名">
            <input
              type="text"
              required
              autoComplete="name"
              value={ownerName}
              onChange={(e) => setOwnerName(e.target.value)}
              className={inputCls}
            />
          </Field>
          <Field label="Email">
            <input
              type="email"
              required
              autoComplete="username"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className={inputCls}
            />
          </Field>
          <Field label="密碼（至少 8 碼）">
            <input
              type="password"
              required
              minLength={8}
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={inputCls}
            />
          </Field>

          {error && (
            <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
              {error}
            </p>
          )}

          <SpinButton
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            {submitting ? "建立中…" : "開始免費試用"}
          </SpinButton>
        </form>

        <p className="text-xs text-zinc-500">
          已經有帳號？{" "}
          <Link href="/login" className="underline hover:text-zinc-700 dark:hover:text-zinc-300">
            前往登入
          </Link>
          ・想先了解功能？{" "}
          <Link href="/welcome" className="underline hover:text-zinc-700 dark:hover:text-zinc-300">
            看介紹
          </Link>
        </p>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block space-y-1">
      <span className="text-sm font-medium">{label}</span>
      {children}
    </label>
  );
}
