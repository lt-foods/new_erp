"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";

export type MemberStatus = "active" | "inactive" | "blocked" | "merged" | "deleted";
export type MemberGender = "M" | "F" | "O" | null;

export type MemberFormValues = {
  id: number | null;
  member_no: string;
  phone: string;
  name: string;
  gender: MemberGender;
  birthday: string | null; // yyyy-mm-dd
  email: string | null;
  tier_id: number | null;
  home_store_id: number | null;
  status: MemberStatus;
  notes: string | null;
};

type Tier = { id: number; code: string; name: string };
type Store = { id: number; code: string; name: string };

export const emptyMemberValues: MemberFormValues = {
  id: null,
  member_no: "",
  phone: "",
  name: "",
  gender: null,
  birthday: null,
  email: null,
  tier_id: null,
  home_store_id: null,
  status: "active",
  notes: null,
};

export function MemberForm({
  initial,
  onSaved,
  onCancel,
}: {
  initial?: MemberFormValues;
  onSaved?: (id: number) => void;
  onCancel?: () => void;
}) {
  const router = useRouter();
  const [v, setV] = useState<MemberFormValues>(initial ?? emptyMemberValues);
  const [tiers, setTiers] = useState<Tier[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [t, s] = await Promise.all([
        sb.from("member_tiers").select("id, code, name").order("sort_order"),
        sb.from("stores").select("id, code, name").eq("is_active", true).order("name"),
      ]);
      if (t.data) setTiers(t.data as Tier[]);
      if (s.data) setStores(s.data as Store[]);
    })();
  }, []);

  function update<K extends keyof MemberFormValues>(k: K, val: MemberFormValues[K]) {
    setV((prev) => ({ ...prev, [k]: val }));
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!v.member_no || !v.phone || !v.name) {
      setError("會員編號、手機、姓名 必填");
      return;
    }
    if (!/^[0-9+\-\s]{6,}$/.test(v.phone)) {
      setError("手機格式錯誤");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_upsert_member", {
        p_id: v.id,
        p_member_no: v.member_no.trim(),
        p_phone: v.phone.trim(),
        p_name: v.name.trim(),
        p_gender: v.gender,
        p_birthday: v.birthday,
        p_email: v.email,
        p_tier_id: v.tier_id,
        p_home_store_id: v.home_store_id,
        p_status: v.status,
        p_notes: v.notes,
      });
      if (err) throw err;
      const newId = Number(data);
      if (onSaved) onSaved(newId);
      else router.replace(`/members/detail?id=${newId}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="會員編號 *">
          <input
            value={v.member_no}
            onChange={(e) => update("member_no", e.target.value)}
            className={inputCls}
            required
          />
        </Field>
        <Field label="狀態">
          <select value={v.status} onChange={(e) => update("status", e.target.value as MemberStatus)} className={inputCls}>
            <option value="active">活躍</option>
            <option value="inactive">停用</option>
            <option value="blocked">封鎖</option>
          </select>
        </Field>

        <Field label="姓名 *">
          <input value={v.name} onChange={(e) => update("name", e.target.value)} className={inputCls} required />
        </Field>
        <Field label="手機 *">
          <input
            value={v.phone}
            onChange={(e) => update("phone", e.target.value)}
            className={inputCls}
            required
            inputMode="tel"
          />
        </Field>

        <Field label="性別">
          <select
            value={v.gender ?? ""}
            onChange={(e) => update("gender", (e.target.value || null) as MemberGender)}
            className={inputCls}
          >
            <option value="">—</option>
            <option value="M">男</option>
            <option value="F">女</option>
            <option value="O">其他</option>
          </select>
        </Field>
        <Field label="生日">
          <DatePicker
            value={v.birthday ?? ""}
            onChange={(s) => update("birthday", s || null)}
            className={inputCls}
          />
        </Field>

        <Field label="Email">
          <input
            type="email"
            value={v.email ?? ""}
            onChange={(e) => update("email", e.target.value || null)}
            className={inputCls}
          />
        </Field>
        <Field label="等級">
          <select
            value={v.tier_id ?? ""}
            onChange={(e) => update("tier_id", e.target.value ? Number(e.target.value) : null)}
            className={inputCls}
          >
            <option value="">—</option>
            {tiers.map((t) => (
              <option key={t.id} value={t.id}>
                {t.name} ({t.code})
              </option>
            ))}
          </select>
        </Field>

        <Field label="主要店家">
          <select
            value={v.home_store_id ?? ""}
            onChange={(e) => update("home_store_id", e.target.value ? Number(e.target.value) : null)}
            className={inputCls}
          >
            <option value="">—</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
        </Field>
      </div>

      <Field label="備註">
        <textarea
          value={v.notes ?? ""}
          onChange={(e) => update("notes", e.target.value || null)}
          className={`${inputCls} min-h-20`}
        />
      </Field>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={saving}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          {saving ? "儲存中…" : v.id ? "儲存" : "建立會員"}
        </button>
        <button
          type="button"
          onClick={() => onCancel ? onCancel() : router.push("/members")}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          取消
        </button>
      </div>
    </form>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="text-zinc-600 dark:text-zinc-400">{label}</span>
      {children}
    </label>
  );
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";
