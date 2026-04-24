"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { getSupabase } from "@/lib/supabase";

type LookupRow = {
  member_id: number;
  member_no: string;
  name_masked: string | null;
  home_store_name: string | null;
};

export default function RegisterPage() {
  const [ready, setReady] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const [phone, setPhone] = useState("");
  const [lastName, setLastName] = useState("");
  const [birthday, setBirthday] = useState("");

  // 已是會員的確認狀態
  const [lookup, setLookup] = useState<LookupRow | null>(null);
  const [confirming, setConfirming] = useState(false);

  useEffect(() => {
    // 從 fragment 取 token（由 Edge Function redirect 帶回）
    consumeFragmentToSession();
    const s = getSession();
    if (!s) {
      setError("尚未登入，請回首頁重新開始。");
      return;
    }
    if (s.bound) {
      // 已綁定，應不在此頁；導回 /me
      window.location.href = "/me";
      return;
    }
    setReady(true);
  }, []);

  async function onCheckPhone() {
    setError(null);
    const s = getSession();
    if (!s) return setError("session 失效");
    if (!phone.trim()) return setError("請輸入手機");

    const sb = getSupabase(s.token);
    const { data, error: e } = await sb.rpc("rpc_liff_lookup_by_phone", { p_phone: phone.trim() });
    if (e) return setError(e.message);

    const row = (data as LookupRow[])?.[0] ?? null;
    if (row) {
      setLookup(row);
      setConfirming(true);
    } else {
      // 不是既有會員，走新建流程（直接顯示姓名/生日欄位，維持現狀）
      setLookup(null);
      setConfirming(false);
    }
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const s = getSession();
    if (!s) return setError("session 失效");

    // 新建會員必填姓 + 生日；確認既有會員只要手機
    if (!lookup) {
      if (!lastName.trim()) return setError("請輸入姓氏");
      if (!birthday) return setError("請輸入生日");
    }

    setSubmitting(true);
    try {
      const sb = getSupabase(s.token);
      const { data, error: e } = await sb.rpc("rpc_liff_register_and_bind", {
        p_phone: phone.trim(),
        p_last_name: lookup ? "" : lastName.trim(),
        p_birthday: lookup ? null : birthday,
      });
      if (e) throw e;
      const row = (data as Array<{ member_id: number; is_new_member: boolean; was_bound: boolean }>)?.[0];
      if (!row) throw new Error("unexpected empty response");

      // 綁定成功 → /me（重新跑 oauth 拿完整 member JWT；或直接用現有 pending jwt 到 me 頁再換）
      window.location.href = `/me?member_id=${row.member_id}`;
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  if (!ready) {
    return (
      <main className="mx-auto max-w-md p-6">
        {error ? <p className="text-sm text-red-700">{error}</p> : <p className="text-sm text-zinc-500">載入中…</p>}
      </main>
    );
  }

  return (
    <main className="mx-auto flex w-full max-w-md flex-col gap-5 p-6 pt-10">
      <h1 className="text-xl font-semibold">完成會員註冊</h1>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</div>
      )}

      <form onSubmit={onSubmit} className="flex flex-col gap-4">
        <label className="flex flex-col gap-1">
          <span className="text-sm font-medium">手機號碼</span>
          <input
            type="tel"
            inputMode="numeric"
            value={phone}
            onChange={(e) => { setPhone(e.target.value); setConfirming(false); setLookup(null); }}
            onBlur={onCheckPhone}
            placeholder="0912345678"
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none"
            required
          />
        </label>

        {confirming && lookup && (
          <div className="rounded-md border border-green-300 bg-green-50 p-3 text-sm text-green-900">
            <p className="font-medium">偵測到您已是會員</p>
            <p className="mt-1">姓名：{lookup.name_masked ?? "—"}</p>
            <p>主要門市：{lookup.home_store_name ?? "—"}</p>
            <p className="mt-2 text-xs">按「確認綁定」將本 LINE 與此會員連結。</p>
          </div>
        )}

        {!lookup && (
          <>
            <label className="flex flex-col gap-1">
              <span className="text-sm font-medium">姓氏</span>
              <input
                type="text"
                value={lastName}
                onChange={(e) => setLastName(e.target.value)}
                placeholder="王"
                className="rounded-md border border-zinc-300 px-3 py-2 text-sm"
                required
              />
            </label>
            <label className="flex flex-col gap-1">
              <span className="text-sm font-medium">生日</span>
              <input
                type="date"
                value={birthday}
                onChange={(e) => setBirthday(e.target.value)}
                className="rounded-md border border-zinc-300 px-3 py-2 text-sm"
                required
              />
            </label>
          </>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="mt-2 rounded-md bg-[#06C755] px-4 py-3 text-sm font-medium text-white shadow hover:bg-[#05b04c] disabled:opacity-50"
        >
          {submitting ? "處理中…" : lookup ? "確認綁定" : "建立會員"}
        </button>
      </form>
    </main>
  );
}
