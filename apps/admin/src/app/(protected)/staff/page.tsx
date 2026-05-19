"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { useRole } from "@/lib/role";
import { useAuth } from "@/components/AuthProvider";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow } from "@/components/DataTable";
import { RoleChip, ALL_ROLES, roleLabel, type StaffRole } from "@/components/RoleChip";

type StaffRow = {
  user_id: string;
  email: string | null;
  display_name: string | null;
  role: string;
  stores: string[];
  disabled: boolean;
  created_at: string;
  last_sign_in_at: string | null;
};

type Store = { id: number; code: string; name: string };

type Modal =
  | { mode: "create" }
  | { mode: "role"; row: StaffRow }
  | { mode: "stores"; row: StaffRow }
  | { mode: "disable"; row: StaffRow }
  | null;

export default function StaffPage() {
  const router = useRouter();
  const role = useRole();
  const { user } = useAuth();
  const [rows, setRows] = useState<StaffRow[] | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [modal, setModal] = useState<Modal>(null);
  const [reloadTick, setReloadTick] = useState(0);

  const canManage = role === "owner" || role === "admin";
  const isOwner = role === "owner";

  useEffect(() => {
    if (role !== null && !canManage) {
      router.replace("/");
    }
  }, [role, canManage, router]);

  useEffect(() => {
    if (!canManage) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [s, l] = await Promise.all([
        sb.from("stores").select("id, code, name").eq("is_active", true).order("name"),
        sb.rpc("rpc_list_staff"),
      ]);
      if (cancelled) return;
      if (s.error) { setError(s.error.message); return; }
      if (l.error) { setError(l.error.message); return; }
      setStores((s.data ?? []) as Store[]);
      setRows((l.data ?? []) as StaffRow[]);
    })();
    return () => { cancelled = true; };
  }, [canManage, reloadTick]);

  const reload = useCallback(() => setReloadTick((t) => t + 1), []);

  if (role === null) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }
  if (!canManage) {
    return <div className="p-6 text-sm text-rose-600">無權限存取。</div>;
  }

  return (
    <div className="space-y-4 p-6">
      <header className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold">員工管理</h1>
          <p className="mt-1 text-xs text-zinc-500">
            管理員工角色與綁定店家。可直接「新增員工」建立帳號，系統會產生一次性臨時密碼交付給對方。
          </p>
        </div>
        <div className="flex items-center gap-3">
          <span className="text-xs text-zinc-500">
            目前身份：<RoleChip role={role} />
          </span>
          <SpinButton
            onClick={() => setModal({ mode: "create" })}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
          >
            新增員工
          </SpinButton>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-rose-200 bg-rose-50 p-3 text-sm text-rose-800 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
          {error}
        </div>
      )}

      <Table>
        <THead>
          <Th>Email</Th>
          <Th>顯示名</Th>
          <Th>角色</Th>
          <Th>綁定店</Th>
          <Th align="right">建立</Th>
          <Th align="right">最後登入</Th>
          <Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <EmptyRow colSpan={7}>載入中…</EmptyRow>
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={7}>沒有員工</EmptyRow>
          ) : (
            rows.map((r) => {
              const isSelf = r.user_id === user?.id;
              const disabled = r.role === "disabled";
              return (
                <Tr key={r.user_id} className={disabled ? "opacity-60" : ""}>
                  <Td className="font-mono text-xs">
                    {r.email ?? "—"}
                    {isSelf && <span className="ml-2 text-[10px] text-zinc-400">（你）</span>}
                  </Td>
                  <Td className="text-xs">{r.display_name ?? "—"}</Td>
                  <Td><RoleChip role={r.role} /></Td>
                  <Td>
                    {r.stores.length === 0 ? (
                      <span className="text-xs text-zinc-400">—</span>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {r.stores.map((s) => (
                          <span key={s} className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300">{s}</span>
                        ))}
                      </div>
                    )}
                  </Td>
                  <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">
                    {new Date(r.created_at).toLocaleDateString("zh-TW")}
                  </Td>
                  <Td align="right" className="whitespace-nowrap text-xs text-zinc-500">
                    {r.last_sign_in_at
                      ? new Date(r.last_sign_in_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })
                      : "—"}
                  </Td>
                  <Td>
                    <div className="flex items-center justify-end gap-2">
                      <button
                        type="button"
                        onClick={() => setModal({ mode: "role", row: r })}
                        disabled={isSelf}
                        title={isSelf ? "不能改自己角色" : ""}
                        className="text-xs text-blue-600 hover:underline disabled:cursor-not-allowed disabled:text-zinc-400 disabled:no-underline dark:text-blue-400"
                      >
                        改角色
                      </button>
                      <button
                        type="button"
                        onClick={() => setModal({ mode: "stores", row: r })}
                        className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                      >
                        綁店
                      </button>
                      {disabled ? (
                        <button
                          type="button"
                          onClick={() => setModal({ mode: "role", row: r })}
                          className="text-xs text-emerald-600 hover:underline dark:text-emerald-400"
                        >
                          啟用
                        </button>
                      ) : (
                        <button
                          type="button"
                          onClick={() => setModal({ mode: "disable", row: r })}
                          disabled={isSelf}
                          title={isSelf ? "不能停用自己" : ""}
                          className="text-xs text-rose-600 hover:underline disabled:cursor-not-allowed disabled:text-zinc-400 disabled:no-underline dark:text-rose-400"
                        >
                          停用
                        </button>
                      )}
                    </div>
                  </Td>
                </Tr>
              );
            })
          )}
        </TBody>
      </Table>

      {modal?.mode === "create" && (
        <CreateStaffModal
          stores={stores}
          isOwnerCaller={isOwner}
          onClose={() => setModal(null)}
          onSaved={() => { setModal(null); reload(); }}
        />
      )}
      {modal?.mode === "role" && (
        <RoleModal
          row={modal.row}
          isOwnerCaller={isOwner}
          onClose={() => setModal(null)}
          onSaved={() => { setModal(null); reload(); }}
        />
      )}
      {modal?.mode === "stores" && (
        <StoresModal
          row={modal.row}
          stores={stores}
          onClose={() => setModal(null)}
          onSaved={() => { setModal(null); reload(); }}
        />
      )}
      {modal?.mode === "disable" && (
        <DisableModal
          row={modal.row}
          onClose={() => setModal(null)}
          onSaved={() => { setModal(null); reload(); }}
        />
      )}
    </div>
  );
}

function RoleModal({
  row, isOwnerCaller, onClose, onSaved,
}: {
  row: StaffRow; isOwnerCaller: boolean;
  onClose: () => void; onSaved: () => void;
}) {
  const [newRole, setNewRole] = useState<StaffRole>(row.role as StaffRole || "");
  const [err, setErr] = useState<string | null>(null);

  // admin 不能 grant owner、也不能改 owner
  const grantable = ALL_ROLES.filter((r) => {
    if (r === "disabled") return false;
    if (!isOwnerCaller && r === "owner") return false;
    return true;
  });
  const targetIsOwner = row.role === "owner";

  async function save() {
    if (targetIsOwner && !isOwnerCaller) {
      setErr("admin 不能改 owner");
      return;
    }
    const { error } = await getSupabase().rpc("rpc_update_staff_role", {
      p_user_id: row.user_id, p_role: newRole,
    });
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  return (
    <Modal open onClose={onClose} title={`改角色 — ${row.email}`} maxWidth="max-w-md">
      <div className="space-y-3 p-5">
        <div className="text-xs text-zinc-500">目前角色：<RoleChip role={row.role} /></div>
        <label className="block text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">新角色</span>
          <select
            value={newRole}
            onChange={(e) => setNewRole(e.target.value as StaffRole)}
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            {grantable.map((r) => <option key={r} value={r}>{roleLabel(r)}</option>)}
          </select>
        </label>
        <p className="text-[11px] text-zinc-500">改完員工需重新登入才會生效。</p>
        {err && <p className="text-xs text-rose-600">{err}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
          <SpinButton onClick={save} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">儲存</SpinButton>
        </div>
      </div>
    </Modal>
  );
}

function StoresModal({
  row, stores, onClose, onSaved,
}: {
  row: StaffRow; stores: Store[];
  onClose: () => void; onSaved: () => void;
}) {
  const [sel, setSel] = useState<Set<string>>(new Set(row.stores));
  const [err, setErr] = useState<string | null>(null);

  function toggle(name: string) {
    setSel((s) => {
      const n = new Set(s);
      if (n.has(name)) n.delete(name); else n.add(name);
      return n;
    });
  }

  async function save() {
    const arr = Array.from(sel);
    const { error } = await getSupabase().rpc("rpc_update_staff_stores", {
      p_user_id: row.user_id, p_store_names: arr,
    });
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  return (
    <Modal open onClose={onClose} title={`綁店 — ${row.email}`} maxWidth="max-w-md">
      <div className="space-y-3 p-5">
        <label className="flex items-center gap-2 rounded-md border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-700">
          <input
            type="checkbox"
            checked={sel.has("總倉")}
            onChange={() => toggle("總倉")}
            className="h-4 w-4"
          />
          <span className="font-medium">總倉</span>
          <span className="text-[11px] text-zinc-500">（HQ 帳號 — 可看全部）</span>
        </label>
        <div className="grid grid-cols-2 gap-2 max-h-72 overflow-y-auto">
          {stores.map((s) => (
            <label key={s.id} className="flex items-center gap-2 rounded-md border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-700">
              <input
                type="checkbox"
                checked={sel.has(s.name)}
                onChange={() => toggle(s.name)}
                className="h-4 w-4"
              />
              <span>{s.name}</span>
              <span className="ml-auto text-[10px] text-zinc-400">{s.code}</span>
            </label>
          ))}
        </div>
        <p className="text-[11px] text-zinc-500">改完員工需重新登入才會生效。</p>
        {err && <p className="text-xs text-rose-600">{err}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
          <SpinButton onClick={save} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">儲存</SpinButton>
        </div>
      </div>
    </Modal>
  );
}

function DisableModal({
  row, onClose, onSaved,
}: { row: StaffRow; onClose: () => void; onSaved: () => void }) {
  const [err, setErr] = useState<string | null>(null);

  async function confirm() {
    const { error } = await getSupabase().rpc("rpc_update_staff_role", {
      p_user_id: row.user_id, p_role: "disabled",
    });
    if (error) { setErr(error.message); return; }
    onSaved();
  }

  return (
    <Modal open onClose={onClose} title={`停用員工 — ${row.email}`} maxWidth="max-w-md">
      <div className="space-y-3 p-5">
        <p className="text-sm text-zinc-700 dark:text-zinc-300">
          確定要停用 <b>{row.email}</b>？停用後該員工登入後無法看到任何資料（RLS 自動擋）。原角色 <RoleChip role={row.role} /> 將被改成 <RoleChip role="disabled" />。
        </p>
        <p className="text-[11px] text-zinc-500">之後可以從「啟用」按鈕還原角色。</p>
        {err && <p className="text-xs text-rose-600">{err}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
          <SpinButton onClick={confirm} className="rounded-md bg-rose-600 px-3 py-2 text-sm font-medium text-white hover:bg-rose-700">確認停用</SpinButton>
        </div>
      </div>
    </Modal>
  );
}

function CreateStaffModal({
  stores, isOwnerCaller, onClose, onSaved,
}: {
  stores: Store[]; isOwnerCaller: boolean;
  onClose: () => void; onSaved: () => void;
}) {
  const grantable = ALL_ROLES.filter((r) => {
    if (r === "disabled") return false;
    if (!isOwnerCaller && r === "owner") return false;
    return true;
  });
  const [email, setEmail] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [newRole, setNewRole] = useState<StaffRole>(
    (grantable.find((r) => r === "store_staff") ?? grantable[0]) as StaffRole,
  );
  const [password, setPassword] = useState("");
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<{ email: string; tempPassword: string | null } | null>(null);
  const [copied, setCopied] = useState(false);

  function toggle(name: string) {
    setSel((s) => {
      const n = new Set(s);
      if (n.has(name)) n.delete(name); else n.add(name);
      return n;
    });
  }

  async function save() {
    setErr(null);
    const e = email.trim().toLowerCase();
    if (!e || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e)) { setErr("請輸入有效 Email"); return; }
    if (!displayName.trim()) { setErr("請輸入顯示名"); return; }
    if (password.length > 0 && password.length < 6) { setErr("密碼至少 6 碼（留空則系統自動產生）"); return; }
    const { data, error } = await getSupabase().functions.invoke<{
      ok?: boolean; error?: string; email?: string; temp_password?: string;
      password_source?: "admin" | "generated";
    }>("staff-create", {
      body: {
        email: e,
        display_name: displayName.trim(),
        role: newRole,
        stores: Array.from(sel),
        password,
      },
    });
    if (error) {
      let msg = error.message ?? "建立失敗";
      try {
        const ctx = (error as { context?: Response }).context;
        if (ctx && typeof ctx.json === "function") {
          const j = await ctx.json();
          if (j?.error) msg = j.error as string;
        }
      } catch { /* 保留原訊息 */ }
      setErr(msg);
      return;
    }
    if (!data?.ok) { setErr(data?.error ?? "建立失敗"); return; }
    const adminSet = data.password_source === "admin";
    if (!adminSet && !data.temp_password) { setErr("建立成功但未取得臨時密碼，請改用重設密碼或重試"); return; }
    setResult({ email: data.email ?? e, tempPassword: adminSet ? null : (data.temp_password ?? null) });
  }

  async function copyPw() {
    if (!result?.tempPassword) return;
    try {
      await navigator.clipboard.writeText(result.tempPassword);
      setCopied(true);
    } catch { /* 使用者可手動選取複製 */ }
  }

  if (result) {
    return (
      <Modal open onClose={onSaved} title="員工已建立" maxWidth="max-w-md">
        <div className="space-y-3 p-5">
          {result.tempPassword ? (
            <>
              <p className="text-sm text-zinc-700 dark:text-zinc-300">
                <b>{result.email}</b> 帳號已建立。請把以下一次性臨時密碼交付給對方，
                <b className="text-rose-600">只顯示這一次</b>，關閉後無法再查看。
              </p>
              <div className="flex items-center gap-2 rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800">
                <code className="flex-1 select-all break-all font-mono text-sm">{result.tempPassword}</code>
                <button
                  type="button"
                  onClick={copyPw}
                  className="shrink-0 rounded border border-zinc-300 px-2 py-1 text-xs hover:bg-white dark:border-zinc-600 dark:hover:bg-zinc-700"
                >
                  {copied ? "已複製" : "複製"}
                </button>
              </div>
            </>
          ) : (
            <p className="text-sm text-zinc-700 dark:text-zinc-300">
              <b>{result.email}</b> 帳號已建立。請用<b>你剛剛設定的密碼</b>通知對方登入。
            </p>
          )}
          <p className="text-[11px] text-zinc-500">
            員工用此 Email + 密碼登入後台；建議首次登入後盡快重設密碼。改完角色/綁店員工需重新登入才會生效。
          </p>
          <div className="flex justify-end pt-2">
            <SpinButton onClick={onSaved} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">完成</SpinButton>
          </div>
        </div>
      </Modal>
    );
  }

  return (
    <Modal open onClose={onClose} title="新增員工" maxWidth="max-w-md">
      <div className="space-y-3 p-5">
        <label className="block text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">Email</span>
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            placeholder="staff@example.com"
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="block text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">顯示名</span>
          <input
            type="text"
            value={displayName}
            onChange={(e) => setDisplayName(e.target.value)}
            placeholder="王小明"
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>
        <label className="block text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">密碼</span>
          <input
            type="text"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            placeholder="留空＝系統自動產生一次性密碼"
            autoComplete="new-password"
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
          <span className="mt-1 block text-[11px] text-zinc-500">自訂則至少 6 碼；留空則建立後顯示一次性臨時密碼</span>
        </label>
        <label className="block text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">角色</span>
          <select
            value={newRole}
            onChange={(e) => setNewRole(e.target.value as StaffRole)}
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            {grantable.map((r) => <option key={r} value={r}>{roleLabel(r)}</option>)}
          </select>
        </label>
        <div className="text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">綁定店</span>
          <label className="mt-1 flex items-center gap-2 rounded-md border border-zinc-200 px-3 py-2 dark:border-zinc-700">
            <input type="checkbox" checked={sel.has("總倉")} onChange={() => toggle("總倉")} className="h-4 w-4" />
            <span className="font-medium">總倉</span>
            <span className="text-[11px] text-zinc-500">（HQ 帳號 — 可看全部）</span>
          </label>
          <div className="mt-2 grid max-h-56 grid-cols-2 gap-2 overflow-y-auto">
            {stores.map((s) => (
              <label key={s.id} className="flex items-center gap-2 rounded-md border border-zinc-200 px-3 py-2 dark:border-zinc-700">
                <input type="checkbox" checked={sel.has(s.name)} onChange={() => toggle(s.name)} className="h-4 w-4" />
                <span>{s.name}</span>
                <span className="ml-auto text-[10px] text-zinc-400">{s.code}</span>
              </label>
            ))}
          </div>
        </div>
        <p className="text-[11px] text-zinc-500">未填密碼則建立後顯示一次性臨時密碼；有填則用你設定的密碼。</p>
        {err && <p className="text-xs text-rose-600">{err}</p>}
        <div className="flex justify-end gap-2 pt-2">
          <SpinButton onClick={onClose} className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">取消</SpinButton>
          <SpinButton onClick={save} className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900">建立</SpinButton>
        </div>
      </div>
    </Modal>
  );
}
