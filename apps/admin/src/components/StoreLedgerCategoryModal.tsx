"use client";

import { useCallback, useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import type { LedgerCategory, LedgerKind } from "@/lib/storeLedger";

// 門市記帳本「科目管理」。
// 共用科目（store_id = null，總部種的系統預設）分店只能看、不能改 —— DB 端
// rpc_store_ledger_save_category 也是這樣擋的，這裡只是把按鈕一起收掉。
// 分店要自己的科目就按「＋ 新增科目」，那筆會掛在自己店底下。

type Draft = {
  id: number | null;
  kind: LedgerKind;
  name: string;
  affects_profit: boolean;
  sort_order: number;
  is_active: boolean;
  /** 系統預設科目：名稱／收支別鎖住（DB 端 rpc_store_ledger_save_category 也會擋） */
  is_system: boolean;
};

const EMPTY: Draft = {
  id: null, kind: "expense", name: "", affects_profit: true, sort_order: 500, is_active: true, is_system: false,
};

export function StoreLedgerCategoryModal({
  open,
  storeId,
  storeName,
  onClose,
  onChanged,
}: {
  open: boolean;
  storeId: number;
  storeName: string;
  onClose: () => void;
  onChanged: () => void;
}) {
  const [rows, setRows] = useState<LedgerCategory[]>([]);
  const [isHq, setIsHq] = useState(false);
  const [loading, setLoading] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const { data, error: e } = await getSupabase().rpc("rpc_store_ledger_categories", {
        p_store_id: storeId,
        p_include_inactive: true,
      });
      if (e) throw new Error(translateRpcError(e));
      const d = (data ?? {}) as { rows?: LedgerCategory[]; is_hq?: boolean };
      setRows(d.rows ?? []);
      setIsHq(!!d.is_hq);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [storeId]);

  useEffect(() => {
    if (open) void load();
  }, [open, load]);

  // 共用科目只有總部能動；本店自訂科目店長自己就能改
  const canEdit = (c: LedgerCategory) => (c.store_id === null ? isHq : true);

  async function save() {
    if (!draft || !draft.name.trim()) return;
    setError(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_store_ledger_save_category", {
        p_store_id: draft.id === null ? storeId : null, // 修改時 DB 自己從既有那列判斷歸屬
        p_kind: draft.kind,
        p_name: draft.name.trim(),
        p_affects_profit: draft.affects_profit,
        p_sort_order: draft.sort_order,
        p_is_active: draft.is_active,
        p_id: draft.id,
      });
      if (e) throw new Error(translateRpcError(e));
      setDraft(null);
      await load();
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function toggleActive(c: LedgerCategory) {
    setError(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_store_ledger_save_category", {
        p_store_id: null,
        p_kind: c.kind,
        p_name: c.name,
        p_affects_profit: c.affects_profit,
        p_sort_order: c.sort_order,
        p_is_active: !c.is_active,
        p_id: c.id,
      });
      if (e) throw new Error(translateRpcError(e));
      await load();
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function remove(c: LedgerCategory) {
    if (!confirm(`刪除科目「${c.name}」？\n\n（已經記過帳的科目不能刪，只能停用。）`)) return;
    setError(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_store_ledger_delete_category", { p_id: c.id });
      if (e) throw new Error(translateRpcError(e));
      await load();
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`科目管理　${storeName}`} maxWidth="max-w-3xl">
      <div className="flex flex-col gap-3 text-sm">
        <div className="flex items-center justify-between">
          <span className="text-xs text-zinc-500">
            共用科目由總部維護，本店自訂的科目只有自己看得到。{loading ? " 載入中…" : ""}
          </span>
          <SpinButton
            onClick={() => setDraft({ ...EMPTY })}
            className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ＋ 新增科目
          </SpinButton>
        </div>

        {draft && (
          <div className="rounded-md border border-blue-300 bg-blue-50 p-3 dark:border-blue-800 dark:bg-blue-950">
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
              <label className="block">
                <span className="mb-1 block text-xs text-zinc-500">收支別</span>
                <select
                  value={draft.kind}
                  onChange={(e) => setDraft({ ...draft, kind: e.target.value as LedgerKind })}
                  disabled={draft.id !== null}
                  className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800"
                >
                  <option value="expense">支出</option>
                  <option value="income">收入</option>
                </select>
              </label>
              <label className="block">
                <span className="mb-1 block text-xs text-zinc-500">名稱</span>
                <input
                  value={draft.name}
                  onChange={(e) => setDraft({ ...draft, name: e.target.value })}
                  disabled={draft.is_system}
                  title={draft.is_system ? "系統預設科目不能改名稱，只能調整排序／停用" : undefined}
                  className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800"
                  placeholder="例：停車費"
                />
              </label>
              <label className="block">
                <span className="mb-1 block text-xs text-zinc-500">排序</span>
                <input
                  type="number"
                  value={draft.sort_order}
                  onChange={(e) => setDraft({ ...draft, sort_order: Number(e.target.value) || 500 })}
                  className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-right font-mono dark:border-zinc-700 dark:bg-zinc-800"
                />
              </label>
              <label className="flex items-end gap-2 pb-1.5">
                <input
                  type="checkbox"
                  checked={!draft.affects_profit}
                  onChange={(e) => setDraft({ ...draft, affects_profit: !e.target.checked })}
                />
                <span className="text-xs">不計損益</span>
              </label>
            </div>
            <p className="mt-2 text-[11px] text-zinc-500">
              「不計損益」＝只是把現金搬來搬去（存銀行、總部撥款），會動現金但不算賺賠。
            </p>
            <div className="mt-2 flex justify-end gap-2">
              <SpinButton
                onClick={() => setDraft(null)}
                className="rounded-md border border-zinc-300 px-3 py-1 text-xs dark:border-zinc-700"
              >
                取消
              </SpinButton>
              <SpinButton
                onClick={save}
                disabled={!draft.name.trim()}
                className="rounded-md bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-700 disabled:opacity-50"
              >
                儲存
              </SpinButton>
            </div>
          </div>
        )}

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {(["expense", "income"] as const).map((kind) => (
          <div key={kind}>
            <div className="mb-1 text-xs font-medium text-zinc-500">
              {kind === "expense" ? "支出科目" : "收入科目"}
            </div>
            <div className="overflow-hidden rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {rows.filter((c) => c.kind === kind).length === 0 ? (
                    <tr><td className="p-3 text-center text-xs text-zinc-500">沒有科目</td></tr>
                  ) : (
                    rows
                      .filter((c) => c.kind === kind)
                      .map((c) => (
                        <tr
                          key={c.id}
                          className={`odd:bg-white even:bg-zinc-50 dark:odd:bg-zinc-950 dark:even:bg-zinc-900 ${
                            c.is_active === false ? "opacity-50" : ""
                          }`}
                        >
                          <td className="px-3 py-1.5">
                            {c.name}
                            {!c.affects_profit && (
                              <span className="ml-2 rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                                不計損益
                              </span>
                            )}
                            {c.store_id === null ? (
                              <span className="ml-2 text-[10px] text-zinc-400">共用</span>
                            ) : (
                              <span className="ml-2 text-[10px] text-violet-500">本店</span>
                            )}
                            {c.is_active === false && <span className="ml-2 text-[10px] text-zinc-400">已停用</span>}
                          </td>
                          <td className="px-3 py-1.5 text-right font-mono text-xs text-zinc-400">
                            {c.used_count ? `${c.used_count} 筆` : ""}
                          </td>
                          <td className="w-44 px-3 py-1.5 text-right">
                            {canEdit(c) ? (
                              <span className="flex justify-end gap-2 text-xs">
                                <SpinButton
                                  onClick={() =>
                                    setDraft({
                                      id: c.id,
                                      kind: c.kind,
                                      name: c.name,
                                      affects_profit: c.affects_profit,
                                      sort_order: c.sort_order,
                                      is_active: c.is_active !== false,
                                      is_system: c.is_system,
                                    })
                                  }
                                  className="text-blue-600 hover:underline dark:text-blue-400"
                                >
                                  編輯
                                </SpinButton>
                                <SpinButton onClick={() => toggleActive(c)} className="text-zinc-500 hover:underline">
                                  {c.is_active === false ? "啟用" : "停用"}
                                </SpinButton>
                                {!c.is_system && !c.used_count && (
                                  <SpinButton onClick={() => remove(c)} className="text-rose-600 hover:underline">
                                    刪除
                                  </SpinButton>
                                )}
                              </span>
                            ) : (
                              <span className="text-xs text-zinc-400">總部維護</span>
                            )}
                          </td>
                        </tr>
                      ))
                  )}
                </tbody>
              </table>
            </div>
          </div>
        ))}
      </div>
    </Modal>
  );
}
