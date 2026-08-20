"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import type { Session, User } from "@supabase/supabase-js";
import { getSupabase } from "@/lib/supabase";

export type TenantInfo = {
  id: string;
  name: string;
  status: "trial" | "active" | "suspended" | "deleted";
  trial_expires_at: string | null;
};

type AuthState = {
  session: Session | null;
  user: User | null;
  loading: boolean;
  // 登入後從 rpc_get_my_tenant 取得；查無（舊 DB 未套 tenants migration）時為 null，
  // 呼叫端用 getTenantName() env fallback
  tenant: TenantInfo | null;
  signIn: (email: string, password: string) => Promise<{ error: string | null }>;
  signOut: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

function isPiaopiaoPublisher(session: Session | null): boolean {
  return session?.user.app_metadata?.role === "piaopiao_publisher";
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  // 記住「這份 tenant 是替哪個 user 抓的」，登出/換帳號時自然失效，不必同步清空
  const [tenantState, setTenantState] = useState<{ forUser: string; info: TenantInfo | null } | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let mounted = true;
    const supabase = getSupabase();

    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return;
      if (isPiaopiaoPublisher(data.session)) {
        void supabase.auth.signOut();
        setSession(null);
      } else {
        setSession(data.session);
      }
      setLoading(false);
    });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      if (isPiaopiaoPublisher(s)) {
        void supabase.auth.signOut();
        setSession(null);
      } else {
        setSession(s);
      }
    });

    return () => {
      mounted = false;
      sub.subscription.unsubscribe();
    };
  }, []);

  const userId = session?.user?.id ?? null;
  useEffect(() => {
    if (!userId) return;
    let cancelled = false;
    getSupabase()
      .rpc("rpc_get_my_tenant")
      .then(({ data }) => {
        if (cancelled) return;
        const row = (Array.isArray(data) ? data[0] : data) as TenantInfo | undefined;
        setTenantState({ forUser: userId, info: row ?? null });
      });
    return () => {
      cancelled = true;
    };
  }, [userId]);

  const tenant = userId && tenantState?.forUser === userId ? tenantState.info : null;

  const signIn = useCallback(async (email: string, password: string) => {
    const sb = getSupabase();
    const { data, error } = await sb.auth.signInWithPassword({ email, password });
    if (!error && isPiaopiaoPublisher(data.session)) {
      await sb.auth.signOut();
      return { error: "此帳號只能登入漂漂館上架後台" };
    }
    return { error: error?.message ?? null };
  }, []);

  const signOut = useCallback(async () => {
    await getSupabase().auth.signOut();
  }, []);

  const value = useMemo<AuthState>(
    () => ({ session, user: session?.user ?? null, loading, tenant, signIn, signOut }),
    [session, loading, tenant, signIn, signOut]
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth must be used inside <AuthProvider>");
  return ctx;
}
