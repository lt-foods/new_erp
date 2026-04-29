"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";

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
  const [name, setName] = useState("");
  const [birthday, setBirthday] = useState("");

  const [lineName, setLineName] = useState<string | null>(null);
  const [linePicture, setLinePicture] = useState<string | null>(null);
  const [lineUserId, setLineUserId] = useState<string | null>(null);
  const [storeId, setStoreId] = useState<string | null>(null);

  // 已是會員的確認狀態
  const [lookup, setLookup] = useState<LookupRow | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s) {
      setError("尚未登入，請回首頁重新開始。");
      return;
    }
    if (s.bound) {
      window.location.href = "/me";
      return;
    }
    if (s.lineName) setName(s.lineName);
    setLineName(s.lineName);
    setLinePicture(s.linePicture);
    setLineUserId(s.lineUserId);
    setStoreId(s.storeId);
    setReady(true);
  }, []);

  async function onCheckPhone() {
    if (!phone.trim()) return;
    setError(null);
    const s = getSession();
    if (!s) return setError("session 失效");

    try {
      const resp = await callLiffApi<{ match: LookupRow | null }>(s.token, {
        action: "lookup_by_phone",
        phone: phone.trim(),
      });
      setLookup(resp.match);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    const s = getSession();
    if (!s) return setError("session 失效");

    if (!phone.trim()) return setError("請輸入手機號碼");
    if (!lookup) {
      if (!name.trim()) return setError("請輸入姓名");
      if (!birthday) return setError("請選擇生日");
    }

    setSubmitting(true);
    try {
      const resp = await callLiffApi<{
        member_id: number;
        is_new_member: boolean;
        was_bound: boolean;
      }>(s.token, {
        action: "register_and_bind",
        phone: phone.trim(),
        name: lookup ? "" : name.trim(),
        birthday: lookup ? "" : birthday,
      });
      window.location.href = `/me?member_id=${resp.member_id}`;
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSubmitting(false);
    }
  }

  if (!ready) {
    return (
      <main className="mx-auto max-w-md p-6">
        {error ? <p className="text-base text-red-700">{error}</p> : <p className="text-base text-zinc-500">載入中…</p>}
      </main>
    );
  }

  const hasLineInfo = lineName || linePicture || lineUserId;

  return (
    <main className="mx-auto flex w-full max-w-md flex-col gap-5 p-6 pt-10">
      <h1 className="text-2xl font-semibold">完成會員註冊</h1>

      {/* LINE 資訊預覽卡 */}
      {hasLineInfo && (
        <div className="rounded-md border border-[#06C755]/30 bg-[#06C755]/5 p-4 text-base">
          <div className="mb-3 flex items-center gap-3">
            {linePicture && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={linePicture} alt="" className="h-12 w-12 rounded-full" />
            )}
            <div>
              <div className="text-sm text-zinc-500">已透過 LINE 驗證</div>
              <div className="text-lg font-semibold">{lineName ?? "(未提供)"}</div>
            </div>
          </div>
          <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm text-zinc-600">
            {lineUserId && (
              <>
                <dt className="text-zinc-400">LINE ID</dt>
                <dd className="font-mono break-all">{lineUserId}</dd>
              </>
            )}
            {storeId && (
              <>
                <dt className="text-zinc-400">門市代號</dt>
                <dd>{storeId}</dd>
              </>
            )}
          </dl>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-base text-red-800">{error}</div>
      )}

      <form onSubmit={onSubmit} className="flex flex-col gap-4">
        <label className="flex flex-col gap-1">
          <span className="text-base font-medium">
            手機號碼 <span className="text-sm text-zinc-400">（LINE 無法提供，請手動輸入）</span>
          </span>
          <input
            type="tel"
            inputMode="numeric"
            value={phone}
            onChange={(e) => { setPhone(e.target.value); setLookup(null); }}
            onBlur={onCheckPhone}
            placeholder="0912345678"
            className="rounded-md border border-zinc-300 px-3 py-2 text-base focus:border-zinc-500 focus:outline-none"
            required
          />
        </label>

        {lookup && (
          <div className="rounded-md border border-green-300 bg-green-50 p-3 text-base text-green-900">
            <p className="font-medium">偵測到您已是會員</p>
            <p className="mt-1">姓名：{lookup.name_masked ?? "—"}</p>
            <p>主要門市：{lookup.home_store_name ?? "—"}</p>
            <p className="mt-2 text-sm">按「確認綁定」將本 LINE 與此會員連結。</p>
          </div>
        )}

        {!lookup && (
          <>
            <label className="flex flex-col gap-1">
              <span className="text-base font-medium">
                姓名
                {lineName && <span className="ml-2 text-sm text-[#06C755]">✓ 已由 LINE 帶入，可修改</span>}
              </span>
              <input
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="王小明"
                className="rounded-md border border-zinc-300 px-3 py-2 text-base"
                required
              />
            </label>
            <label className="flex flex-col gap-1">
              <span className="text-base font-medium">生日</span>
              <input
                type="date"
                value={birthday}
                onChange={(e) => setBirthday(e.target.value)}
                className="rounded-md border border-zinc-300 px-3 py-2 text-base"
                required
              />
            </label>
          </>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="mt-2 rounded-md bg-[#06C755] px-4 py-3 text-base font-medium text-white shadow hover:bg-[#05b04c] disabled:opacity-50"
        >
          {submitting ? "處理中…" : lookup ? "確認綁定此 LINE" : "建立會員並綁定 LINE"}
        </button>

        <p className="text-center text-sm text-zinc-400">
          送出後將在 ERP 系統建立會員資料、並與您的 LINE 帳號永久綁定。
        </p>
      </form>
    </main>
  );
}
