"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import {
  PAY_METHODS,
  payMethodLabel,
  type LedgerCategory,
  type LedgerEntry,
} from "@/lib/storeLedger";

// 門市記帳本「記一筆」：新增 / 修改一筆收支。
// 寫入一律走 rpc_store_ledger_save_entry（SECURITY DEFINER，裡面自己擋權限與關帳）。

export function StoreLedgerEntryModal({
  open,
  storeId,
  storeName,
  date,
  categories,
  entry,
  direction,
  onClose,
  onSaved,
}: {
  open: boolean;
  storeId: number;
  storeName: string;
  /** 預設記在哪一天（YYYY-MM-DD）。修改時以該筆的日期為準 */
  date: string;
  categories: LedgerCategory[];
  /** 有值 = 修改既有那筆；null = 新增 */
  entry: LedgerEntry | null;
  /** 新增時預設的收支別 */
  direction: "income" | "expense";
  onClose: () => void;
  onSaved: () => void;
}) {
  const [dir, setDir] = useState<"income" | "expense">(entry?.direction ?? direction);
  const [categoryId, setCategoryId] = useState<string>(entry?.category_id ? String(entry.category_id) : "");
  const [amount, setAmount] = useState<string>(entry ? String(Number(entry.amount)) : "");
  const [payment, setPayment] = useState<string>(entry?.payment_method ?? "cash");
  const [counterparty, setCounterparty] = useState(entry?.counterparty ?? "");
  const [note, setNote] = useState(entry?.note ?? "");
  const [receiptNo, setReceiptNo] = useState(entry?.receipt_no ?? "");
  const [error, setError] = useState<string | null>(null);

  // 換一筆（或從「記支出」切成「記收入」）時把表單重置 —— 彈窗是常駐掛載的，
  // 不重置會把上一筆的金額帶到下一筆去。
  useEffect(() => {
    if (!open) return;
    setDir(entry?.direction ?? direction);
    setCategoryId(entry?.category_id ? String(entry.category_id) : "");
    setAmount(entry ? String(Number(entry.amount)) : "");
    setPayment(entry?.payment_method ?? "cash");
    setCounterparty(entry?.counterparty ?? "");
    setNote(entry?.note ?? "");
    setReceiptNo(entry?.receipt_no ?? "");
    setError(null);
  }, [open, entry, direction]);

  const options = useMemo(
    () => categories.filter((c) => c.kind === dir),
    [categories, dir],
  );

  // 收支別切換後，原本選的科目可能是另一邊的 → 清掉，免得送出被 DB 打回來
  useEffect(() => {
    if (categoryId && !options.some((c) => String(c.id) === categoryId)) setCategoryId("");
  }, [options, categoryId]);

  const amountNum = Number(amount);
  const valid = Number.isFinite(amountNum) && amountNum > 0 && !!categoryId;

  async function save() {
    if (!valid) return;
    setError(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_store_ledger_save_entry", {
        p_store_id: storeId,
        p_entry_date: entry?.entry_date ?? date,
        p_direction: dir,
        p_category_id: Number(categoryId),
        p_amount: amountNum,
        p_payment_method: payment,
        p_counterparty: counterparty.trim() || null,
        p_note: note.trim() || null,
        p_receipt_no: receiptNo.trim() || null,
        p_id: entry?.id ?? null,
      });
      if (e) throw new Error(translateRpcError(e));
      onSaved();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={`${entry ? "修改" : "新增"}${dir === "income" ? "收入" : "支出"}　${storeName}　${entry?.entry_date ?? date}`}
      maxWidth="max-w-lg"
    >
      <div className="flex flex-col gap-3 text-sm">
        {!entry && (
          <div className="flex gap-2">
            {(["expense", "income"] as const).map((d) => (
              <SpinButton
                key={d}
                onClick={() => setDir(d)}
                className={`flex-1 rounded-md border px-3 py-2 text-sm ${
                  dir === d
                    ? d === "expense"
                      ? "border-rose-500 bg-rose-50 font-medium text-rose-700 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-300"
                      : "border-emerald-500 bg-emerald-50 font-medium text-emerald-700 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
                    : "border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                }`}
              >
                {d === "expense" ? "－ 支出" : "＋ 收入"}
              </SpinButton>
            ))}
          </div>
        )}

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">科目</span>
          <select
            value={categoryId}
            onChange={(e) => setCategoryId(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">請選擇…</option>
            {options.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
                {c.affects_profit ? "" : "（不計損益）"}
                {c.store_id ? "（本店）" : ""}
              </option>
            ))}
          </select>
        </label>

        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">金額</span>
            <input
              type="number"
              inputMode="decimal"
              min={0}
              step="1"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-right font-mono dark:border-zinc-700 dark:bg-zinc-800"
              placeholder="0"
            />
          </label>
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">付款方式</span>
            <select
              value={payment}
              onChange={(e) => setPayment(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
            >
              {PAY_METHODS.map((m) => (
                <option key={m} value={m}>{payMethodLabel(m)}</option>
              ))}
            </select>
          </label>
        </div>
        {payment !== "cash" && (
          <p className="-mt-1 text-xs text-amber-600">
            非現金的帳不會動到「應有現金」，只會進損益。
          </p>
        )}

        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">對象 / 廠商（選填）</span>
            <input
              value={counterparty}
              onChange={(e) => setCounterparty(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
              placeholder="例：台電、房東、王小明"
            />
          </label>
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">發票 / 收據號（選填）</span>
            <input
              value={receiptNo}
              onChange={(e) => setReceiptNo(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 font-mono dark:border-zinc-700 dark:bg-zinc-800"
              placeholder="AB-12345678"
            />
          </label>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
            placeholder="例：9 月份租金"
          />
        </label>

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="flex justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={!valid}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {entry ? "儲存" : "記一筆"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
