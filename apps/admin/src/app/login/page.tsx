"use client";

// 後台登入頁。配色固定淺暖色（與推廣頁／註冊頁一致，不隨系統深色模式變化）。
// 標題用 getTenantName()（各租戶自己的商家名），這裡是該租戶後台的登入入口。

import { Suspense, useState, useEffect, type FormEvent } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useAuth } from "@/components/AuthProvider";
import { getTenantName } from "@/lib/tenant";
import SpinButton from "@/components/SpinButton";

const PAGE_BG = "#fdf1e6";
const inputCls =
  "w-full rounded-md border border-stone-300 bg-white px-3 py-2 text-sm text-stone-900 focus:border-orange-500 focus:outline-none";

export default function LoginPage() {
  return (
    <Suspense fallback={<LoginSkeleton />}>
      <LoginForm />
    </Suspense>
  );
}

function LoginSkeleton() {
  return (
    <div className="flex flex-1 items-center justify-center text-sm text-stone-500" style={{ backgroundColor: PAGE_BG }}>
      載入中…
    </div>
  );
}

function LoginForm() {
  const router = useRouter();
  const params = useSearchParams();
  const { session, loading, signIn } = useAuth();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const next = params.get("next") || "/";

  useEffect(() => {
    if (!loading && session) router.replace(next);
  }, [loading, session, router, next]);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setSubmitting(true);
    const { error: err } = await signIn(email, password);
    setSubmitting(false);
    if (err) {
      setError(err);
      return;
    }
    router.replace(next);
  }

  return (
    <div className="flex flex-1 items-center justify-center p-6 text-stone-900" style={{ backgroundColor: PAGE_BG }}>
      <div className="w-full max-w-sm space-y-6 rounded-lg border border-stone-200 bg-white p-8 shadow-sm">
        <div className="space-y-1">
          <h1 className="text-2xl font-semibold">登入 {getTenantName()}管理頁面</h1>
          <p className="text-sm text-stone-500">使用管理員帳號</p>
        </div>

        <form onSubmit={onSubmit} className="space-y-4">
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
          <Field label="密碼">
            <input
              type="password"
              required
              autoComplete="current-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className={inputCls}
            />
          </Field>

          {error && (
            <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700">
              {error}
            </p>
          )}

          <SpinButton
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-orange-600 px-3 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-orange-700 disabled:opacity-50"
          >
            {submitting ? "登入中…" : "登入"}
          </SpinButton>
        </form>

        <p className="text-xs text-stone-500">
          沒有帳號？請聯絡管理員建立員工帳號，或{" "}
          <Link href="/signup" className="underline hover:text-stone-700">
            免費試用 14 天
          </Link>
          。
        </p>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block space-y-1">
      <span className="text-sm font-medium text-stone-700">{label}</span>
      {children}
    </label>
  );
}
