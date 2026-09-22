"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";
import { StoreLedgerEntryModal } from "@/components/StoreLedgerEntryModal";
import { StoreLedgerCloseModal } from "@/components/StoreLedgerCloseModal";
import { StoreLedgerCategoryModal } from "@/components/StoreLedgerCategoryModal";
import { LedgerCategoryChart, LedgerDailyChart } from "@/components/StoreLedgerCharts";
import {
  addDays,
  downloadCsv,
  localYmd,
  money,
  num,
  payMethodLabel,
  type LedgerDay,
  type LedgerEntry,
  type LedgerPeriod,
} from "@/lib/storeLedger";

// 門市記帳本（日結頁的第二個分頁）。
//
// 它回答的是日結報表回答不了的那件事：**抽屜裡的錢對不對**。
//   開帳現金 ＋ 取貨收現 ＋ 其他現金收入 − 現金支出 = 應有現金
//   實點現金 − 應有現金 = 差異
// 「取貨收現」直接取 rpc_daily_pickup_settlement（跟上面那個分頁同一支函式），
// 所以兩個分頁的營業額永遠是同一個數字。
//
// 權限：只有該店店長（＋總部）看得到，DB 端由 _store_ledger_can_view() 擋；
// 這裡只負責把門市下拉鎖在自己店，不要把它當成防線。

type Store = { id: number; code: string; name: string };

export function StoreLedgerPanel({
  stores,
  lockedStoreId,
  defaultStoreId,
}: {
  stores: Store[];
  /** 分店帳號鎖定的門市；總部為 null */
  lockedStoreId: number | null;
  /** 日結報表分頁目前選的門市（""＝全部分店） */
  defaultStoreId: string;
}) {
  const today = localYmd();
  const [storeId, setStoreId] = useState<string>(lockedStoreId ? String(lockedStoreId) : defaultStoreId);
  const [date, setDate] = useState(today);
  const [day, setDay] = useState<LedgerDay | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  // 彈窗
  const [entryOpen, setEntryOpen] = useState(false);
  const [entryDirection, setEntryDirection] = useState<"income" | "expense">("expense");
  const [editing, setEditing] = useState<LedgerEntry | null>(null);
  const [closeOpen, setCloseOpen] = useState(false);
  const [catOpen, setCatOpen] = useState(false);

  // 期間報表
  // 預設展開：圖表是這一段的重點，藏在按鈕後面等於沒做
  const [periodOpen, setPeriodOpen] = useState(true);
  const [pFrom, setPFrom] = useState(`${today.slice(0, 8)}01`);
  const [pTo, setPTo] = useState(today);
  const [period, setPeriod] = useState<LedgerPeriod | null>(null);
  const [pLoading, setPLoading] = useState(false);
  const [pError, setPError] = useState<string | null>(null);

  // 分店帳號：鎖回自己店（比照 /pickup 的 branchLocked 慣例）
  useEffect(() => {
    if (lockedStoreId != null && storeId !== String(lockedStoreId)) setStoreId(String(lockedStoreId));
  }, [lockedStoreId, storeId]);

  const sid = storeId ? Number(storeId) : null;
  const storeName = stores.find((s) => String(s.id) === storeId)?.name ?? day?.store.name ?? "";
  const reload = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (sid == null) {
      setDay(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    (async () => {
      try {
        const { data, error: e } = await getSupabase().rpc("rpc_store_ledger_day", {
          p_store_id: sid,
          p_date: date,
        });
        if (cancelled) return;
        if (e) throw new Error(translateRpcError(e));
        setDay(data as LedgerDay);
        setError(null);
      } catch (err) {
        if (!cancelled) {
          setDay(null);
          setError(err instanceof Error ? err.message : String(err));
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, [sid, date, tick]);

  const loadPeriod = useCallback(async () => {
    if (sid == null) return;
    setPLoading(true);
    try {
      const { data, error: e } = await getSupabase().rpc("rpc_store_ledger_period", {
        p_store_id: sid,
        p_date_from: pFrom,
        p_date_to: pTo,
      });
      if (e) throw new Error(translateRpcError(e));
      setPeriod(data as LedgerPeriod);
      setPError(null);
    } catch (err) {
      setPeriod(null);
      setPError(err instanceof Error ? err.message : String(err));
    } finally {
      setPLoading(false);
    }
  }, [sid, pFrom, pTo]);

  useEffect(() => {
    if (periodOpen) void loadPeriod();
  }, [periodOpen, loadPeriod, tick]);

  const closed = day?.closing?.status === "closed";
  const liveExpected = day ? num(day.expected_cash) : 0;
  const cashIn = day ? num(day.sales.cash) + num(day.totals.income_cash) : 0;
  const cashOut = day ? num(day.totals.expense_cash) : 0;

  const activeEntries = useMemo(
    () => (day?.entries ?? []).filter((e) => !e.voided_at),
    [day],
  );

  async function voidEntry(e: LedgerEntry) {
    const reason = window.prompt(
      `作廢這筆帳？\n\n${e.category_name}　${money(e.amount)}\n\n作廢原因（選填）：`,
      "",
    );
    if (reason === null) return; // 按取消
    try {
      const { error: err } = await getSupabase().rpc("rpc_store_ledger_void_entry", {
        p_id: e.id,
        p_reason: reason.trim() || null,
      });
      if (err) throw new Error(translateRpcError(err));
      reload();
    } catch (err) {
      alert(err instanceof Error ? err.message : String(err));
    }
  }

  async function reopenDay() {
    if (!day) return;
    const reason = window.prompt(`重新開帳 ${day.date}？\n\n原因（會留在紀錄上）：`, "");
    if (reason === null) return;
    try {
      const { error: err } = await getSupabase().rpc("rpc_store_ledger_reopen_day", {
        p_store_id: day.store.id,
        p_date: day.date,
        p_reason: reason.trim() || null,
      });
      if (err) throw new Error(translateRpcError(err));
      reload();
    } catch (err) {
      alert(err instanceof Error ? err.message : String(err));
    }
  }

  function exportPeriodCsv() {
    if (!period) return;
    const head = [
      "日期", "取貨營業額", "取貨收現", "其他收入", "現金收入", "支出", "現金支出",
      "當日損益", "已關帳", "實點現金", "應有現金", "差異",
    ];
    const body = period.days.map((d) => [
      d.ymd, num(d.sales_total), num(d.sales_cash), num(d.income_all), num(d.income_cash),
      num(d.expense_all), num(d.expense_cash),
      num(d.sales_total) + num(d.income_profit) - num(d.expense_profit),
      d.closed ? "是" : "否",
      d.counted_cash == null ? "" : num(d.counted_cash),
      d.expected_cash == null ? "" : num(d.expected_cash),
      d.diff_cash == null ? "" : num(d.diff_cash),
    ]);
    downloadCsv(`記帳本-${period.store.name}-${period.date_from}_${period.date_to}.csv`, [head, ...body]);
  }

  async function exportEntriesCsv() {
    if (sid == null) return;
    try {
      const { data, error: e } = await getSupabase().rpc("rpc_store_ledger_entry_list", {
        p_store_id: sid,
        p_date_from: pFrom,
        p_date_to: pTo,
        p_include_voided: true,
        p_limit: 500,
        p_offset: 0,
      });
      if (e) throw new Error(translateRpcError(e));
      const rows = ((data ?? {}) as { rows?: LedgerEntry[] }).rows ?? [];
      const head = ["日期", "收支", "科目", "金額", "付款方式", "對象", "發票/收據", "備註", "記錄者", "作廢"];
      const body = rows.map((r) => [
        r.entry_date,
        r.direction === "income" ? "收入" : "支出",
        r.category_name,
        num(r.amount),
        payMethodLabel(r.payment_method),
        r.counterparty ?? "",
        r.receipt_no ?? "",
        r.note ?? "",
        r.created_by ?? "",
        r.voided_at ? `已作廢${r.void_reason ? `（${r.void_reason}）` : ""}` : "",
      ]);
      downloadCsv(`記帳明細-${storeName}-${pFrom}_${pTo}.csv`, [head, ...body]);
    } catch (err) {
      alert(err instanceof Error ? err.message : String(err));
    }
  }

  return (
    <div className="flex flex-col gap-4">
      {/* ── 工具列：門市 + 日期 ───────────────────────────── */}
      <div className="flex flex-wrap items-center gap-2">
        {lockedStoreId != null ? (
          <span className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-1.5 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300">
            {storeName || "本店"}
          </span>
        ) : (
          <select
            value={storeId}
            onChange={(e) => setStoreId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">請選擇門市…</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>{s.code} {s.name}</option>
            ))}
          </select>
        )}

        <div className="flex items-center gap-1">
          <SpinButton
            onClick={() => setDate((d) => addDays(d, -1))}
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            title="前一天"
          >
            ◀
          </SpinButton>
          <DatePicker
            value={date}
            onChange={setDate}
            max={today}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-left text-sm dark:border-zinc-700 dark:bg-zinc-800"
          />
          <SpinButton
            onClick={() => setDate((d) => (d >= today ? d : addDays(d, 1)))}
            disabled={date >= today}
            className="rounded-md border border-zinc-300 px-2 py-1.5 text-sm hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
            title="後一天"
          >
            ▶
          </SpinButton>
          {date !== today && (
            <SpinButton
              onClick={() => setDate(today)}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              今天
            </SpinButton>
          )}
        </div>

        {loading && <span className="text-sm text-zinc-500">載入中…</span>}

        <div className="ml-auto flex items-center gap-2">
          <SpinButton
            onClick={() => setCatOpen(true)}
            disabled={sid == null}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            ⚙ 科目管理
          </SpinButton>
        </div>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {sid == null ? (
        <div className="rounded-md border border-dashed border-zinc-300 p-8 text-center text-sm text-zinc-500 dark:border-zinc-700">
          記帳本是一家店一本帳，請先在上面選一家門市。
        </div>
      ) : day == null ? (
        !error && <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
      ) : (
        <>
          {/* ── 現金結算 ─────────────────────────────────── */}
          <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
            <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 bg-zinc-50 px-4 py-2 dark:border-zinc-800 dark:bg-zinc-900">
              <span className="text-sm font-medium">
                現金結算
                {closed ? (
                  <span className="ml-2 rounded bg-emerald-100 px-2 py-0.5 text-xs font-normal text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                    已關帳
                  </span>
                ) : (
                  <span className="ml-2 rounded bg-amber-100 px-2 py-0.5 text-xs font-normal text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                    未關帳
                  </span>
                )}
                {day.closing?.reopened_at && (
                  <span className="ml-2 text-xs font-normal text-zinc-400">
                    （曾重新開帳{day.closing.reopen_reason ? `：${day.closing.reopen_reason}` : ""}）
                  </span>
                )}
              </span>
              {closed ? (
                <SpinButton
                  onClick={reopenDay}
                  className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  🔓 重新開帳
                </SpinButton>
              ) : (
                <SpinButton
                  onClick={() => setCloseOpen(true)}
                  className="rounded-md bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-700"
                >
                  🔒 關帳（點鈔）
                </SpinButton>
              )}
            </div>

            <div className="grid grid-cols-2 divide-x divide-y divide-zinc-200 sm:grid-cols-3 lg:grid-cols-6 dark:divide-zinc-800">
              <Tile label="開帳現金" value={money(day.opening_cash)} hint={day.prev_closing ? `${day.prev_closing.closing_date} 結餘` : "沒有前一日紀錄"} />
              <Tile
                label="取貨收現"
                value={money(day.sales.cash)}
                hint={`${num(day.sales.orders)} 單${num(day.sales.noncash) > 0 ? `・非現金 ${money(day.sales.noncash)}` : ""}`}
                tone="emerald"
              />
              <Tile label="其他現金收入" value={money(day.totals.income_cash)} tone="emerald" />
              <Tile label="現金支出" value={money(day.totals.expense_cash)} tone="rose" />
              <Tile
                label="應有現金"
                value={money(closed ? day.closing!.expected_cash : liveExpected)}
                hint="開帳＋收現－支出"
                strong
              />
              {closed ? (
                <Tile
                  label="實點現金"
                  value={money(day.closing!.counted_cash)}
                  hint={`差異 ${money(day.closing!.diff_cash)}`}
                  tone={Math.abs(num(day.closing!.diff_cash)) < 0.005 ? "emerald" : "amber"}
                  strong
                />
              ) : (
                <Tile label="實點現金" value="—" hint="關帳時輸入" />
              )}
            </div>

            <div className="flex flex-wrap items-center gap-x-6 gap-y-1 border-t border-zinc-200 px-4 py-2 text-xs text-zinc-500 dark:border-zinc-800">
              <span>今日取貨營業額 <span className="font-mono text-zinc-700 dark:text-zinc-200">{money(day.sales.total)}</span></span>
              <span>＋其他收入 <span className="font-mono text-zinc-700 dark:text-zinc-200">{money(day.totals.income_profit)}</span></span>
              <span>－支出 <span className="font-mono text-zinc-700 dark:text-zinc-200">{money(day.totals.expense_profit)}</span></span>
              <span>
                ＝當日損益{" "}
                <span className={`font-mono font-semibold ${num(day.profit) < 0 ? "text-rose-600 dark:text-rose-400" : "text-zinc-800 dark:text-zinc-100"}`}>
                  {money(day.profit)}
                </span>
              </span>
              <span className="text-zinc-400">（不計損益的科目不算在內）</span>
            </div>
          </div>

          {/* ── 帳目明細 ─────────────────────────────────── */}
          <div>
            <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
              <span className="text-sm font-medium">
                {date} 的帳
                <span className="ml-2 text-xs font-normal text-zinc-500">
                  {activeEntries.length} 筆・收入 {money(num(day.totals.income_cash) + num(day.totals.income_noncash))}
                  ・支出 {money(num(day.totals.expense_cash) + num(day.totals.expense_noncash))}
                </span>
              </span>
              <div className="flex gap-2">
                <SpinButton
                  onClick={() => { setEditing(null); setEntryDirection("expense"); setEntryOpen(true); }}
                  disabled={closed}
                  title={closed ? "已關帳，要記帳請先「重新開帳」" : undefined}
                  className="rounded-md border border-rose-300 px-3 py-1 text-xs text-rose-700 hover:bg-rose-50 disabled:opacity-40 dark:border-rose-800 dark:text-rose-300 dark:hover:bg-rose-950"
                >
                  － 記支出
                </SpinButton>
                <SpinButton
                  onClick={() => { setEditing(null); setEntryDirection("income"); setEntryOpen(true); }}
                  disabled={closed}
                  title={closed ? "已關帳，要記帳請先「重新開帳」" : undefined}
                  className="rounded-md border border-emerald-300 px-3 py-1 text-xs text-emerald-700 hover:bg-emerald-50 disabled:opacity-40 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                >
                  ＋ 記收入
                </SpinButton>
              </div>
            </div>

            <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                <thead className="bg-zinc-50 dark:bg-zinc-900">
                  <tr>
                    <Th>時間</Th>
                    <Th>收支</Th>
                    <Th>科目</Th>
                    <Th className="text-right">金額</Th>
                    <Th>付款</Th>
                    <Th>對象</Th>
                    <Th>備註</Th>
                    <Th>記錄者</Th>
                    <Th className="text-right">操作</Th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {day.entries.length === 0 ? (
                    <tr>
                      <td colSpan={9} className="p-6 text-center text-zinc-500">
                        這天還沒有帳。店裡付出去的錢（叫貨、水電、包材…）跟取貨以外的收入都記在這裡。
                      </td>
                    </tr>
                  ) : (
                    day.entries.map((e) => (
                      <tr
                        key={e.id}
                        className={`odd:bg-white even:bg-zinc-50 hover:bg-zinc-100 dark:odd:bg-zinc-950 dark:even:bg-zinc-900 dark:hover:bg-zinc-800 ${
                          e.voided_at ? "text-zinc-400 line-through" : ""
                        }`}
                      >
                        <Td className="whitespace-nowrap text-xs text-zinc-500">
                          {new Date(e.created_at).toLocaleTimeString("zh-TW", { hour: "2-digit", minute: "2-digit", hour12: false })}
                        </Td>
                        <Td>
                          <span className={`inline-block rounded px-2 py-0.5 text-xs ${
                            e.direction === "income"
                              ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                              : "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300"
                          }`}>
                            {e.direction === "income" ? "收入" : "支出"}
                          </span>
                        </Td>
                        <Td className="text-xs">
                          {e.category_name}
                          {!e.affects_profit && (
                            <span className="ml-1 text-[10px] text-zinc-400">不計損益</span>
                          )}
                        </Td>
                        <Td className={`text-right font-mono ${e.direction === "expense" ? "text-rose-600 dark:text-rose-400" : "text-emerald-700 dark:text-emerald-400"}`}>
                          {e.direction === "expense" ? "-" : "+"}{money(e.amount)}
                        </Td>
                        <Td className="text-xs">{payMethodLabel(e.payment_method)}</Td>
                        <Td className="text-xs">{e.counterparty ?? "—"}</Td>
                        <Td className="text-xs">
                          {e.note ?? "—"}
                          {e.receipt_no && <span className="ml-1 font-mono text-[10px] text-zinc-400">#{e.receipt_no}</span>}
                          {e.voided_at && (
                            <span className="ml-1 text-[10px] text-rose-500">
                              已作廢{e.void_reason ? `：${e.void_reason}` : ""}
                            </span>
                          )}
                        </Td>
                        <Td className="text-xs text-zinc-500">{(e.created_by ?? "").split("@")[0] || "—"}</Td>
                        <Td className="text-right">
                          {!e.voided_at && !closed && (
                            <span className="flex justify-end gap-2 text-xs">
                              <SpinButton
                                onClick={() => { setEditing(e); setEntryOpen(true); }}
                                className="text-blue-600 hover:underline dark:text-blue-400"
                              >
                                編輯
                              </SpinButton>
                              <SpinButton onClick={() => voidEntry(e)} className="text-rose-600 hover:underline">
                                作廢
                              </SpinButton>
                            </span>
                          )}
                        </Td>
                      </tr>
                    ))
                  )}
                </tbody>
                {day.entries.length > 0 && (
                  <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Td className="text-xs font-medium" colSpan={3}>現金進出小計</Td>
                      <Td className="text-right font-mono font-medium">{money(cashIn - cashOut)}</Td>
                      <Td className="text-xs text-zinc-500" colSpan={5}>
                        現金收入 {money(cashIn)}・現金支出 {money(cashOut)}
                      </Td>
                    </tr>
                  </tfoot>
                )}
              </table>
            </div>
          </div>

          {/* ── 期間報表 ─────────────────────────────────── */}
          <div>
            <div className="mb-2 flex items-center justify-between">
              <span className="text-sm font-medium">
                期間報表
                {periodOpen && period ? `（${period.date_from} ～ ${period.date_to}）` : ""}
                {pLoading ? " 載入中…" : ""}
              </span>
              <SpinButton
                onClick={() => setPeriodOpen((v) => !v)}
                className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                {periodOpen ? "收合" : "📈 看區間收支"}
              </SpinButton>
            </div>

            {periodOpen && (
              <div className="flex flex-col gap-3">
                <div className="flex flex-wrap items-center gap-2 text-sm">
                  {[
                    { label: "本月", from: `${today.slice(0, 8)}01`, to: today },
                    { label: "上月", from: lastMonthFirst(today), to: lastMonthLast(today) },
                    { label: "近 7 天", from: addDays(today, -6), to: today },
                  ].map((r) => (
                    <SpinButton
                      key={r.label}
                      onClick={() => { setPFrom(r.from); setPTo(r.to); }}
                      className={`rounded-md border px-3 py-1 text-xs ${
                        pFrom === r.from && pTo === r.to
                          ? "border-blue-500 bg-blue-50 font-medium text-blue-700 dark:border-blue-600 dark:bg-blue-950 dark:text-blue-300"
                          : "border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                      }`}
                    >
                      {r.label}
                    </SpinButton>
                  ))}
                  <DatePicker
                    value={pFrom}
                    onChange={(v) => { setPFrom(v); if (v > pTo) setPTo(v); }}
                    className="rounded-md border border-zinc-300 bg-white px-3 py-1 text-left text-xs dark:border-zinc-700 dark:bg-zinc-800"
                  />
                  <span className="text-zinc-400">～</span>
                  <DatePicker
                    value={pTo}
                    onChange={(v) => { setPTo(v); if (v < pFrom) setPFrom(v); }}
                    className="rounded-md border border-zinc-300 bg-white px-3 py-1 text-left text-xs dark:border-zinc-700 dark:bg-zinc-800"
                  />
                  <div className="ml-auto flex gap-2">
                    <SpinButton
                      onClick={exportPeriodCsv}
                      disabled={!period}
                      className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      ⬇ 每日彙總 CSV
                    </SpinButton>
                    <SpinButton
                      onClick={exportEntriesCsv}
                      className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    >
                      ⬇ 逐筆明細 CSV
                    </SpinButton>
                  </div>
                </div>

                {pError && (
                  <div className="rounded-md border border-red-200 bg-red-50 p-3 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                    {pError}
                  </div>
                )}

                {period && (
                  <>
                    <div className="grid grid-cols-2 divide-x divide-y divide-zinc-200 rounded-md border border-zinc-200 sm:grid-cols-3 lg:grid-cols-5 dark:divide-zinc-800 dark:border-zinc-800">
                      <Tile label="取貨營業額" value={money(period.totals.sales_total)} tone="emerald" />
                      <Tile label="其他收入" value={money(period.totals.income_all)} hint={`計損益 ${money(period.totals.income_profit)}`} tone="emerald" />
                      <Tile label="支出" value={money(period.totals.expense_all)} hint={`計損益 ${money(period.totals.expense_profit)}`} tone="rose" />
                      <Tile label="期間損益" value={money(period.totals.profit)} strong tone={num(period.totals.profit) < 0 ? "rose" : undefined} />
                      <Tile label="關帳差異合計" value={money(period.totals.diff_cash)} hint={`已關帳 ${num(period.totals.closed_days)} 天`} tone={Math.abs(num(period.totals.diff_cash)) < 0.005 ? undefined : "amber"} />
                    </div>

                    <LedgerDailyChart days={period.days} onPickDay={setDate} />

                    <LedgerCategoryChart rows={period.by_category} />

                    <div className="grid gap-3 lg:grid-cols-2">
                      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                          <thead className="bg-zinc-50 dark:bg-zinc-900">
                            <tr>
                              <Th>日期</Th>
                              <Th className="text-right">營業額</Th>
                              <Th className="text-right">收入</Th>
                              <Th className="text-right">支出</Th>
                              <Th className="text-right">損益</Th>
                              <Th className="text-right">差異</Th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                            {period.days.map((d) => {
                              const profit = num(d.sales_total) + num(d.income_profit) - num(d.expense_profit);
                              return (
                                <tr
                                  key={d.ymd}
                                  className="cursor-pointer odd:bg-white even:bg-zinc-50 hover:bg-blue-50 dark:odd:bg-zinc-950 dark:even:bg-zinc-900 dark:hover:bg-zinc-800"
                                  onClick={() => setDate(d.ymd)}
                                  title="點一下看那天的帳"
                                >
                                  <Td className="text-xs">
                                    {d.ymd}
                                    {d.closed && <span className="ml-1 text-[10px] text-emerald-600">已關帳</span>}
                                  </Td>
                                  <Td className="text-right font-mono text-xs">{money(d.sales_total)}</Td>
                                  <Td className="text-right font-mono text-xs">{num(d.income_all) > 0 ? money(d.income_all) : "—"}</Td>
                                  <Td className="text-right font-mono text-xs text-rose-600 dark:text-rose-400">
                                    {num(d.expense_all) > 0 ? money(d.expense_all) : "—"}
                                  </Td>
                                  <Td className={`text-right font-mono text-xs ${profit < 0 ? "text-rose-600 dark:text-rose-400" : ""}`}>
                                    {money(profit)}
                                  </Td>
                                  <Td className="text-right font-mono text-xs">
                                    {d.diff_cash == null ? "—" : (
                                      <span className={Math.abs(num(d.diff_cash)) < 0.005 ? "text-emerald-600" : "text-amber-600"}>
                                        {money(d.diff_cash)}
                                      </span>
                                    )}
                                  </Td>
                                </tr>
                              );
                            })}
                          </tbody>
                        </table>
                      </div>

                      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                          <thead className="bg-zinc-50 dark:bg-zinc-900">
                            <tr>
                              <Th>科目</Th>
                              <Th className="text-right">筆數</Th>
                              <Th className="text-right">金額</Th>
                              <Th className="text-right">其中現金</Th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                            {period.by_category.length === 0 ? (
                              <tr><td colSpan={4} className="p-6 text-center text-zinc-500">這段期間沒有記帳。</td></tr>
                            ) : (
                              period.by_category.map((c) => (
                                <tr key={`${c.kind}-${c.category_id}`} className="odd:bg-white even:bg-zinc-50 dark:odd:bg-zinc-950 dark:even:bg-zinc-900">
                                  <Td className="text-xs">
                                    <span className={`mr-1 inline-block rounded px-1.5 py-0.5 text-[10px] ${
                                      c.kind === "income"
                                        ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
                                        : "bg-rose-100 text-rose-800 dark:bg-rose-950 dark:text-rose-300"
                                    }`}>
                                      {c.kind === "income" ? "收" : "支"}
                                    </span>
                                    {c.name}
                                    {!c.affects_profit && <span className="ml-1 text-[10px] text-zinc-400">不計損益</span>}
                                  </Td>
                                  <Td className="text-right font-mono text-xs">{num(c.cnt)}</Td>
                                  <Td className="text-right font-mono text-xs">{money(c.amount)}</Td>
                                  <Td className="text-right font-mono text-xs text-zinc-500">{money(c.cash)}</Td>
                                </tr>
                              ))
                            )}
                          </tbody>
                        </table>
                      </div>
                    </div>
                  </>
                )}
              </div>
            )}
          </div>

          <p className="text-xs text-zinc-400">
            「取貨收現」與上面的日結報表同一支計算（撤銷取貨會自動扣掉）。
            關帳後那一天的帳就鎖住，要改請先「重新開帳」，紀錄會留著。
            這本帳只有本店店長與總部看得到。
          </p>

          {/* 彈窗 */}
          <StoreLedgerEntryModal
            open={entryOpen}
            storeId={day.store.id}
            storeName={day.store.name}
            date={day.date}
            categories={day.categories}
            entry={editing}
            direction={entryDirection}
            onClose={() => { setEntryOpen(false); setEditing(null); }}
            onSaved={reload}
          />
          <StoreLedgerCloseModal
            open={closeOpen}
            day={day}
            onClose={() => setCloseOpen(false)}
            onSaved={reload}
          />
          <StoreLedgerCategoryModal
            open={catOpen}
            storeId={day.store.id}
            storeName={day.store.name}
            onClose={() => setCatOpen(false)}
            onChanged={reload}
          />
        </>
      )}
    </div>
  );
}

function lastMonthFirst(today: string): string {
  const d = new Date(`${today.slice(0, 8)}01T12:00:00`);
  d.setMonth(d.getMonth() - 1);
  return localYmd(d);
}
function lastMonthLast(today: string): string {
  const d = new Date(`${today.slice(0, 8)}01T12:00:00`);
  d.setDate(0); // 上個月最後一天
  return localYmd(d);
}

function Tile({
  label,
  value,
  hint,
  strong,
  tone,
}: {
  label: string;
  value: string;
  hint?: string;
  strong?: boolean;
  tone?: "emerald" | "rose" | "amber";
}) {
  const toneClass =
    tone === "emerald"
      ? "text-emerald-700 dark:text-emerald-400"
      : tone === "rose"
        ? "text-rose-600 dark:text-rose-400"
        : tone === "amber"
          ? "text-amber-600 dark:text-amber-400"
          : "text-zinc-800 dark:text-zinc-100";
  return (
    <div className="px-4 py-3">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`font-mono ${strong ? "text-lg font-semibold" : "text-base"} ${toneClass}`}>{value}</div>
      {hint && <div className="text-[11px] text-zinc-400">{hint}</div>}
    </div>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}
function Td({ children, className = "", colSpan }: { children: React.ReactNode; className?: string; colSpan?: number }) {
  return <td colSpan={colSpan} className={`px-4 py-2 ${className}`}>{children}</td>;
}
