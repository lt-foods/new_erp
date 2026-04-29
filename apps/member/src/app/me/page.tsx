"use client";

import { useEffect, useState } from "react";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import MemberTabBar from "@/components/MemberTabBar";

type MemberData = {
  member_id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  email: string | null;
  birthday: string | null;
  gender: string | null;
  home_store_id: number | null;
  avatar_url: string | null;
  status: string;
};

export default function MePage() {
  const [loading, setLoading] = useState(true);
  const [me, setMe] = useState<MemberData | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lineName, setLineName] = useState<string | null>(null);
  const [linePicture, setLinePicture] = useState<string | null>(null);
  const [lineUserId, setLineUserId] = useState<string | null>(null);
  const [storeId, setStoreId] = useState<string | null>(null);

  // edit mode
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({ name: "", phone: "", birthday: "", email: "" });

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s) {
      setError("尚未登入");
      setLoading(false);
      return;
    }
    setLineName(s.lineName);
    setLinePicture(s.linePicture);
    setLineUserId(s.lineUserId);
    setStoreId(s.storeId);

    (async () => {
      try {
        const data = await callLiffApi<MemberData>(s.token, { action: "get_me" });
        setMe(data);
        setForm({
          name:     data.name     ?? "",
          phone:    data.phone    ?? "",
          birthday: data.birthday ?? "",
          email:    data.email    ?? "",
        });
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  async function onSave() {
    const s = getSession();
    if (!s) return setError("session 失效");
    setSaving(true);
    setError(null);
    try {
      await callLiffApi(s.token, {
        action: "update_me",
        name:     form.name,
        phone:    form.phone,
        birthday: form.birthday,
        email:    form.email,
      });
      // reload
      const data = await callLiffApi<MemberData>(s.token, { action: "get_me" });
      setMe(data);
      setEditing(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return (
      <main className="mx-auto w-full max-w-md">
        <MemberTabBar />
        <div className="p-6 pt-16 text-center">
          <p className="text-base text-zinc-500">載入中…</p>
        </div>
      </main>
    );
  }

  if (!me) {
    return (
      <main className="mx-auto w-full max-w-md">
        <MemberTabBar />
        <div className="p-6 pt-16 text-center">
          <p className="text-base text-zinc-500">{error ?? "尚未登入，請回首頁。"}</p>
          <a href="/" className="mt-4 inline-block text-base text-blue-600 hover:underline">回首頁</a>
        </div>
      </main>
    );
  }

  const avatarSrc = me.avatar_url ?? linePicture;
  const displayName = me.name ?? lineName ?? "(未提供)";

  return (
    <main className="mx-auto w-full max-w-md">
      <MemberTabBar />
      <div className="flex flex-col gap-5 p-6 pt-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">會員中心</h1>
        {!editing && (
          <button
            onClick={() => setEditing(true)}
            className="text-base text-blue-600 hover:underline"
          >
            編輯
          </button>
        )}
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-base text-red-800">
          {error}
        </div>
      )}

      <div className="rounded-md border border-[#06C755]/30 bg-[#06C755]/5 p-4">
        <div className="flex items-center gap-3">
          {avatarSrc ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={avatarSrc} alt="" className="h-14 w-14 rounded-full object-cover" />
          ) : (
            <div className="flex h-14 w-14 items-center justify-center rounded-full bg-zinc-200 text-2xl text-zinc-500">
              {displayName[0]}
            </div>
          )}
          <div className="flex-1">
            <div className="text-sm text-zinc-500">✓ 已綁定 LINE</div>
            <div className="text-xl font-semibold">{displayName}</div>
            <div className="font-mono text-sm text-zinc-400">{me.member_no}</div>
          </div>
        </div>
      </div>

      {!editing ? (
        // 檢視模式
        <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-2 text-base">
          <dt className="text-zinc-500">手機</dt>
          <dd className="font-mono">{me.phone ?? <span className="text-zinc-400">未填</span>}</dd>

          <dt className="text-zinc-500">生日</dt>
          <dd>{me.birthday ?? <span className="text-zinc-400">未填</span>}</dd>

          <dt className="text-zinc-500">Email</dt>
          <dd className="break-all">{me.email ?? <span className="text-zinc-400">未填</span>}</dd>

          <dt className="text-zinc-500">門市</dt>
          <dd>{storeId ?? "—"}</dd>

          {lineUserId && (
            <>
              <dt className="text-zinc-500">LINE ID</dt>
              <dd className="break-all font-mono text-sm">{lineUserId}</dd>
            </>
          )}
        </dl>
      ) : (
        // 編輯模式
        <form
          onSubmit={(e) => { e.preventDefault(); onSave(); }}
          className="flex flex-col gap-4"
        >
          <label className="flex flex-col gap-1">
            <span className="text-base font-medium">姓名</span>
            <input
              type="text"
              value={form.name}
              onChange={(e) => setForm({ ...form, name: e.target.value })}
              className="rounded-md border border-zinc-300 px-3 py-2 text-base"
              required
            />
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-base font-medium">
              手機號碼 <span className="text-sm text-zinc-400">（台灣手機 09xxxxxxxx）</span>
            </span>
            <input
              type="tel"
              inputMode="numeric"
              value={form.phone}
              onChange={(e) => setForm({ ...form, phone: e.target.value })}
              placeholder="0912345678"
              className="rounded-md border border-zinc-300 px-3 py-2 text-base"
            />
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-base font-medium">生日</span>
            <input
              type="date"
              value={form.birthday}
              onChange={(e) => setForm({ ...form, birthday: e.target.value })}
              className="rounded-md border border-zinc-300 px-3 py-2 text-base"
            />
          </label>

          <label className="flex flex-col gap-1">
            <span className="text-base font-medium">Email</span>
            <input
              type="email"
              value={form.email}
              onChange={(e) => setForm({ ...form, email: e.target.value })}
              placeholder="you@example.com"
              className="rounded-md border border-zinc-300 px-3 py-2 text-base"
            />
          </label>

          <div className="flex gap-2 pt-2">
            <button
              type="button"
              onClick={() => {
                setEditing(false);
                setError(null);
                setForm({
                  name:     me.name     ?? "",
                  phone:    me.phone    ?? "",
                  birthday: me.birthday ?? "",
                  email:    me.email    ?? "",
                });
              }}
              disabled={saving}
              className="flex-1 rounded-md border border-zinc-300 px-4 py-2.5 text-base disabled:opacity-50"
            >
              取消
            </button>
            <button
              type="submit"
              disabled={saving}
              className="flex-1 rounded-md bg-[#06C755] px-4 py-2.5 text-base font-medium text-white shadow disabled:opacity-50"
            >
              {saving ? "儲存中…" : "儲存"}
            </button>
          </div>
        </form>
      )}

      <p className="text-sm text-zinc-400">
        會員卡 QR、點數、訂單等功能尚未上線（MVP-1 開發中）。
      </p>
      </div>
    </main>
  );
}
