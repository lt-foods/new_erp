"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { money, num, type LedgerDay } from "@/lib/storeLedger";

// 門市記帳本「關帳」：輸入開帳現金 + 實點現金，存成當日快照。
// 關帳後那一天的帳就鎖住（新增 / 修改 / 作廢都會被 DB 擋下），要改得先「重新開帳」。

export function StoreLedgerCloseModal({
  open,
  day,
  onClose,
  onSaved,
}: {
  open: boolean;
  day: LedgerDay;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [openingCash, setOpeningCash] = useState(String(num(day.opening_cash)));
  const [countedCash, setCountedCash] = useState("");
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    setOpeningCash(String(num(day.opening_cash)));
    setCountedCash("");
    setNote(day.closing?.note ?? "");
    setError(null);
  }, [open, day]);

  const opening = num(openingCash);
  const counted = num(countedCash);
  // 應有現金跟著「開帳現金」輸入框即時重算 —— 店長常常要先把開帳金額改對
  const expected = opening + num(day.sales.cash) + num(day.totals.income_cash) - num(day.totals.expense_cash);
  const diff = counted - expected;
  const canSave = countedCash.trim() !== "" && Number.isFinite(counted) && counted >= 0;

  async function save() {
    if (!canSave) return;
    setError(null);
    try {
      const { error: e } = await getSupabase().rpc("rpc_store_ledger_close_day", {
        p_store_id: day.store.id,
        p_date: day.date,
        p_counted_cash: counted,
        p_opening_cash: opening,
        p_note: note.trim() || null,
      });
      if (e) throw new Error(translateRpcError(e));
      onSaved();
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`關帳　${day.store.name}　${day.date}`} maxWidth="max-w-lg">
      <div className="flex flex-col gap-3 text-sm">
        <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
          <Row label="開帳現金（昨日結餘）" value={money(opening)} />
          <Row label="＋ 取貨收現" value={money(day.sales.cash)} />
          <Row label="＋ 其他現金收入" value={money(day.totals.income_cash)} />
          <Row label="－ 現金支出" value={money(day.totals.expense_cash)} />
          <Row label="＝ 應有現金" value={money(expected)} strong />
        </div>

        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">開帳現金</span>
            <input
              type="number"
              inputMode="decimal"
              value={openingCash}
              onChange={(e) => setOpeningCash(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-right font-mono dark:border-zinc-700 dark:bg-zinc-800"
            />
            {day.prev_closing && (
              <span className="mt-1 block text-[11px] text-zinc-400">
                {day.prev_closing.closing_date} 關帳實點 {money(day.prev_closing.counted_cash)}
              </span>
            )}
          </label>
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">實際點鈔金額</span>
            <input
              type="number"
              inputMode="decimal"
              value={countedCash}
              onChange={(e) => setCountedCash(e.target.value)}
              autoFocus
              placeholder="抽屜裡實際有多少"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-right font-mono dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
        </div>

        {countedCash.trim() !== "" && (
          <div
            className={`rounded-md border p-3 text-sm ${
              Math.abs(diff) < 0.005
                ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300"
                : "border-amber-300 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300"
            }`}
          >
            差異 <span className="font-mono font-semibold">{money(diff)}</span>
            {Math.abs(diff) < 0.005
              ? "　對得起來 ✅"
              : diff > 0
                ? "　（抽屜比帳多，可能有漏記的收入）"
                : "　（抽屜比帳少，可能有漏記的支出）"}
          </div>
        )}

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder="例：晚班交接、差額明天補查"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <p className="text-xs text-zinc-400">
          關帳會把當下的數字存成快照，那一天的帳就不能再改（要改先按「重新開帳」）。
          明天的開帳現金會自動帶入今天的實點金額。
        </p>

        <div className="flex justify-end gap-2">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={!canSave}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            確認關帳
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

function Row({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div
      className={`flex items-center justify-between border-b border-zinc-100 px-3 py-2 last:border-0 dark:border-zinc-800 ${
        strong ? "bg-zinc-50 font-semibold dark:bg-zinc-900" : ""
      }`}
    >
      <span className="text-zinc-600 dark:text-zinc-300">{label}</span>
      <span className="font-mono">{value}</span>
    </div>
  );
}
