"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";

export type MemberStatus = "active" | "inactive" | "blocked" | "merged" | "deleted";
export type MemberGender = "M" | "F" | "O" | null;

export type MemberFormValues = {
  id: number | null;
  member_no: string;
  phone: string;
  /** 後台名稱：後台自己編、用來搜尋辨識這個人。會員 App 上顯示的是 line_display_name，不是這個 */
  name: string;
  /** LINE 顯示名稱：由 LINE 登入時同步，唯讀（這裡只拿來對照，不送進 rpc_upsert_member） */
  line_display_name?: string | null;
  gender: MemberGender;
  birthday: string | null; // yyyy-mm-dd
  email: string | null;
  tier_id: number | null;
  home_store_id: number | null;
  status: MemberStatus;
  notes: string | null;
};

type Store = { id: number; code: string; name: string };

export const emptyMemberValues: MemberFormValues = {
  id: null,
  member_no: "",
  phone: "",
  name: "",
  line_display_name: null,
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
  const [stores, setStores] = useState<Store[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const { data } = await getSupabase()
        .from("stores").select("id, code, name").eq("is_active", true).order("name");
      if (data) setStores(data as Store[]);
    })();
  }, []);

  function update<K extends keyof MemberFormValues>(k: K, val: MemberFormValues[K]) {
    setV((prev) => ({ ...prev, [k]: val }));
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!v.name) {
      setError("姓名 必填");
      return;
    }
    if (v.phone && !/^[0-9+\-\s]{6,}$/.test(v.phone)) {
      setError("手機格式錯誤");
      return;
    }
    if (!v.id && !v.home_store_id) {
      setError("主要店家 必填");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_upsert_member", {
        p_id: v.id,
        p_member_no: v.member_no ? v.member_no.trim() : null,
        p_phone: v.phone ? v.phone.trim() : null,
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
      else router.replace(`/members?id=${newId}`);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="會員編號">
          {v.id ? (
            <input value={v.member_no} className={inputCls} readOnly disabled />
          ) : (
            <div className={`${inputCls} text-zinc-400 dark:text-zinc-500`}>
              系統自動產生
            </div>
          )}
        </Field>
        <Field label="狀態">
          <select value={v.status} onChange={(e) => update("status", e.target.value as MemberStatus)} className={inputCls}>
            <option value="active">活躍</option>
            <option value="inactive">停用</option>
            <option value="blocked">封鎖</option>
          </select>
        </Field>

        {/* 後台名稱與 LINE 顯示名稱是兩個獨立欄位：
            改這裡不會動到客人在 App 上看到的名字（那個固定跟 LINE 走、無法從後台改）。 */}
        <Field label="姓名 *" hint="後台用：列表、搜尋、單據都看這個">
          <input value={v.name} onChange={(e) => update("name", e.target.value)} className={inputCls} required />
        </Field>
        {v.line_display_name ? (
          <Field label="LINE 顯示名稱" hint="會員 App 上顯示的名字，同步自 LINE、無法修改">
            <div className={`${inputCls} text-zinc-500 dark:text-zinc-400`}>{v.line_display_name}</div>
          </Field>
        ) : null}
        <Field label="手機">
          <input
            value={v.phone}
            onChange={(e) => update("phone", e.target.value)}
            className={inputCls}
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

        <Field label={`主要店家${v.id ? "" : " *"}`}>
          <select
            value={v.home_store_id ?? ""}
            onChange={(e) => update("home_store_id", e.target.value ? Number(e.target.value) : null)}
            className={inputCls}
            required={!v.id}
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
        <SpinButton
          type="submit"
          disabled={saving}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          {saving ? "儲存中…" : v.id ? "儲存" : "建立會員"}
        </SpinButton>
        <SpinButton
          type="button"
          onClick={() => onCancel ? onCancel() : router.push("/members")}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
      </div>
    </form>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="text-zinc-600 dark:text-zinc-400">
        {label}
        {hint && <span className="ml-1.5 text-xs text-zinc-400 dark:text-zinc-500">{hint}</span>}
      </span>
      {children}
    </label>
  );
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";
