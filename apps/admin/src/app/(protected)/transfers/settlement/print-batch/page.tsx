"use client";

// 月結對帳單一次列印（2026-11-03 老闆裁示）：列表頁勾好後開新分頁，看過再手動按列印。
// 每家的紙上內容跟單張列印頁同一支元件；讀法與擋法見 lib/settlementPrintLoad.ts。
// ⛔ 網址參數不能開內部版：每次打開都是分店版，要內部版得自己按（免得連結轉傳就把成本印給店家）。

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SettlementStatementSheet, { SettlementPrintStyles, SettlementStatementAlerts } from "@/components/SettlementStatementSheet";
import { useRole, canSeeCost, isHqRole } from "@/lib/role";
import {
  batchPrintState,
  loadBatchStatements,
  parsePrintBatchIds,
  statementPaper,
  type BatchSheet,
} from "@/lib/settlementPrintLoad";

type ParsedIds = ReturnType<typeof parsePrintBatchIds>;

export default function PrintSettlementBatchPage() {
  const role = useRole();
  const allowed = role !== null && isHqRole(role);
  const costAllowed = canSeeCost(role);
  const [parsed, setParsed] = useState<ParsedIds | null>(null);
  const [sheets, setSheets] = useState<BatchSheet[] | null>(null);
  const [removedIds, setRemovedIds] = useState<Set<number>>(new Set());
  const [internalChosen, setInternalChosen] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // 參數用 window.location 讀（同單張頁，靜態匯出）
  useEffect(() => {
    if (typeof window === "undefined") return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setParsed(parsePrintBatchIds(new URLSearchParams(window.location.search).get("ids")));
  }, []);

  const ids = parsed?.kind === "ok" ? parsed.ids : null;

  // role 還是 null 時先不讀；非總部帳號不讀資料
  useEffect(() => {
    if (!allowed || !ids) return;
    let cancelled = false;
    (async () => {
      try {
        await loadBatchStatements(getSupabase(), ids, (next) => { if (!cancelled) setSheets(next); }, () => cancelled);
      } catch (e) {
        if (!cancelled) setError(e && typeof e === "object" && "message" in e ? String(e.message) : String(e));
      }
    })();
    return () => { cancelled = true; };
  }, [allowed, ids]);

  const state = useMemo(() => batchPrintState(sheets ?? [], removedIds), [sheets, removedIds]);

  if (role !== null && !isHqRole(role)) {
    return <div className="p-6 text-sm text-zinc-500">此頁僅限總部帳號使用。</div>;
  }
  if (role === null || parsed === null) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }
  if (parsed.kind === "invalid") {
    return (
      <div className="m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
        網址裡的月結單號不正確，請回月結列表重新勾選。
      </div>
    );
  }
  if (parsed.kind === "empty") {
    return <div className="p-6 text-sm text-zinc-500">沒有勾選要印的對帳單，請回月結列表勾選。</div>;
  }
  if (error) {
    return (
      <div className="m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
        月結資料載入失敗，請重新整理後再印：{error}
      </div>
    );
  }

  const total = ids?.length ?? 0;
  const internal = internalChosen && costAllowed;
  const blockReason = sheets === null ? "還在載入中…" : state.blockReason;

  return (
    <>
      <SettlementPrintStyles />

      <div className="bg-white text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏）*/}
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3">
          <h1 className="text-base font-semibold">月結對帳單一次列印</h1>
          <span className="text-sm text-zinc-500">
            已載入 {state.loadedCount}／共 {total} 家
            {state.loadedCount === total && !state.allLoaded && "，品名讀取中…"}
          </span>
          {costAllowed && (
            <div className="flex overflow-hidden rounded-md border border-zinc-300 text-sm">
              <SpinButton
                onClick={() => setInternalChosen(false)}
                className={`px-3 py-1.5 ${!internal ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
              >
                分店版（給店家）
              </SpinButton>
              <SpinButton
                onClick={() => setInternalChosen(true)}
                className={`px-3 py-1.5 ${internal ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
              >
                內部版（含成本）
              </SpinButton>
            </div>
          )}
          <SpinButton
            onClick={() => window.print()}
            disabled={blockReason !== undefined}
            title={blockReason}
            className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-400"
          >
            {internal ? "🖨️ 列印內部版" : "🖨️ 列印"}
          </SpinButton>
        </div>

        {/* 印不了的家：紅字講哪一家（同單張頁不加 no-print —— 硬印出來的紙也帶著這行） */}
        {state.issues.map((issue) => (
          <div key={issue.id} role="alert" className="mx-auto mt-3 flex max-w-[210mm] flex-wrap items-center justify-between gap-2 rounded-md border border-red-300 bg-red-50 px-3 py-2 text-sm font-semibold text-red-700">
            <span>{issue.label}：{issue.message}</span>
            <SpinButton
              onClick={() => setRemovedIds((cur) => new Set(cur).add(issue.id))}
              className="no-print rounded-md border border-red-300 bg-white px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-100"
            >
              拿掉這家
            </SpinButton>
          </div>
        ))}

        {state.draftCount > 0 && (
          <div className="no-print mx-auto mt-3 max-w-[210mm] rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">
            其中 {state.draftCount} 家還是草稿，金額之後可能會變
          </div>
        )}

        {state.removed.length > 0 && (
          <div className="no-print mx-auto mt-3 max-w-[210mm] rounded-md border border-zinc-300 bg-zinc-50 px-3 py-2 text-sm text-zinc-700">
            這次沒印 {state.removed.length} 家：{state.removed.map((s) => s.label).join("、")}
            <span className="ml-2 text-xs text-zinc-500">（重新整理可以全部加回來）</span>
          </div>
        )}

        {sheets !== null && state.allLoaded && state.active.length === 0 && (
          <div className="no-print p-6 text-center text-sm text-zinc-500">全部都拿掉了，沒有要印的對帳單。</div>
        )}

        {/* 全部讀完才畫：⚠ 這一層底下只能放警示和 .sheet，最後一個 .sheet 才不會多吐一張白紙（:last-child） */}
        {state.allLoaded && (
          <div>
            {state.active.map((sheet) => sheet.data && (
              <SheetBlock key={sheet.id} sheet={sheet} internal={internal} />
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function SheetBlock({ sheet, internal }: { sheet: BatchSheet; internal: boolean }) {
  const data = sheet.data!;
  return (
    <>
      <SettlementStatementAlerts paper={statementPaper(data.settlement, data.items, data.adjustments)} namesFailed={sheet.namesFailed} />
      <SettlementStatementSheet {...data} internal={internal} batchMarks />
    </>
  );
}
