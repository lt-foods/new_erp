"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

export type ExceptionEvent = {
  id: number;
  action: "opened" | "note" | "resolved" | "reopened";
  note: string | null;
  result: string | null;
  created_by: string;
  created_at: string;
};

export type ExceptionCase = {
  id: number;
  row_key: string;
  type: "po_shortage" | "po_damage" | "po_over" | "transfer_short";
  snapshot: {
    doc_no?: string;
    sku_code?: string | null;
    sku_label?: string;
    warehouse_name?: string | null;
    reason?: string | null;
    expected?: number;
    actual?: number;
    diff?: number;
  };
  status: "open" | "resolved";
  result: string | null;
  opened_at: string;
  resolved_at: string | null;
  updated_at: string;
  is_live: boolean;
  events: ExceptionEvent[];
};

export type ExceptionSubject = {
  rowKey: string;
  type: ExceptionCase["type"];
  docNo: string;
  skuCode: string | null;
  skuLabel: string;
  warehouseName: string | null;
  expected: number;
  actual: number;
  diff: number;
};

const ACTION_LABEL: Record<ExceptionEvent["action"], string> = {
  opened: "系統建立追蹤",
  note: "處理經過",
  resolved: "已結案",
  reopened: "重新開啟追蹤",
};

function dateTime(value: string) {
  return new Date(value).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" });
}

export function ExceptionHistoryModal({
  subject,
  caseRecord,
  onClose,
  onChanged,
}: {
  subject: ExceptionSubject;
  caseRecord?: ExceptionCase;
  onClose: () => void;
  onChanged: () => void;
}) {
  const [note, setNote] = useState("");
  const [result, setResult] = useState("");
  const [busy, setBusy] = useState<"note" | "resolve" | "reopen" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [names, setNames] = useState<Record<string, string>>({});
  const resolved = caseRecord?.status === "resolved";
  const transferShort = subject.type === "transfer_short";

  useEffect(() => {
    const ids = [...new Set((caseRecord?.events ?? []).map((event) => event.created_by).filter(Boolean))];
    if (!ids.length) return;
    const sb = getSupabase();
    sb.rpc("rpc_get_staff_names", { p_uids: ids }).then(({ data }) => {
      const mapped: Record<string, string> = {};
      for (const row of (data ?? []) as Array<{ id: string; display_name: string | null }>) {
        mapped[row.id] = row.display_name || "總部人員";
      }
      setNames(mapped);
    });
  }, [caseRecord]);

  async function operator() {
    const { data } = await getSupabase().auth.getSession();
    if (!data.session?.user?.id) throw new Error("尚未登入");
    return data.session.user.id;
  }

  async function addNote() {
    if (!note.trim()) { setError("請填處理經過"); return; }
    setBusy("note"); setError(null);
    try {
      const { error: rpcError } = await getSupabase().rpc("rpc_hq_exception_add_note", {
        p_row_key: subject.rowKey, p_note: note, p_operator: await operator(),
      });
      if (rpcError) throw rpcError;
      setNote(""); onChanged();
    } catch (e) { setError(translateRpcError(e)); } finally { setBusy(null); }
  }

  async function resolve() {
    if (!result.trim()) { setError("結案必須填最後結果"); return; }
    setBusy("resolve"); setError(null);
    try {
      const { error: rpcError } = await getSupabase().rpc("rpc_hq_exception_resolve", {
        p_row_key: subject.rowKey, p_result: result, p_note: note || null, p_operator: await operator(),
      });
      if (rpcError) throw rpcError;
      setNote(""); setResult(""); onChanged();
    } catch (e) { setError(translateRpcError(e)); } finally { setBusy(null); }
  }

  async function reopen() {
    if (!caseRecord || !note.trim()) { setError("重新開啟必須填原因"); return; }
    setBusy("reopen"); setError(null);
    try {
      const { error: rpcError } = await getSupabase().rpc("rpc_hq_exception_reopen", {
        p_case_id: caseRecord.id, p_reason: note, p_operator: await operator(),
      });
      if (rpcError) throw rpcError;
      setNote(""); onChanged();
    } catch (e) { setError(translateRpcError(e)); } finally { setBusy(null); }
  }

  return (
    <Modal open onClose={onClose} title={resolved ? "異常處理歷程（已結案）" : "異常處理歷程"} maxWidth="max-w-2xl">
      <div className="rounded-md border border-zinc-200 p-3 text-sm dark:border-zinc-800">
        <div className="font-mono text-xs">{subject.docNo}</div>
        <div className="mt-1 font-medium">{subject.skuCode && <span className="mr-1 font-mono text-xs text-zinc-500">{subject.skuCode}</span>}{subject.skuLabel}</div>
        <div className="mt-1 text-xs text-zinc-500">{subject.warehouseName ?? "—"} · 預期 {subject.expected} / 實際 {subject.actual} / 差額 {subject.diff}</div>
        {caseRecord?.snapshot.reason && <div className="mt-2 rounded bg-amber-50 px-2 py-1 text-xs text-amber-800 dark:bg-amber-950/40 dark:text-amber-300">原始說明：{caseRecord.snapshot.reason}</div>}
        {caseRecord?.result && <div className="mt-2 rounded bg-emerald-50 px-2 py-1 text-xs text-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-300">結案結果：{caseRecord.result}</div>}
      </div>

      <ol className="mt-4 max-h-64 space-y-3 overflow-y-auto border-l border-zinc-200 pl-4 text-sm dark:border-zinc-700">
        {(caseRecord?.events ?? []).map((event) => (
          <li key={event.id} className="relative">
            <span className="absolute -left-[21px] top-1 h-2.5 w-2.5 rounded-full bg-blue-500" />
            <div className="font-medium">{ACTION_LABEL[event.action]}</div>
            {(event.note || event.result) && <div className="mt-0.5 whitespace-pre-wrap text-zinc-600 dark:text-zinc-300">{event.note}{event.note && event.result ? "\n" : ""}{event.result && `結果：${event.result}`}</div>}
            <div className="mt-0.5 text-xs text-zinc-400">{names[event.created_by] ?? "總部人員"} · {dateTime(event.created_at)}</div>
          </li>
        ))}
        {!caseRecord && <li className="text-zinc-500">尚未留下處理紀錄；第一次儲存時會自動保留目前這筆異常的完整快照。</li>}
      </ol>

      <label className="mt-4 block text-xs">
        <span className="font-semibold">{resolved ? "重新開啟原因 *" : "處理經過"}</span>
        <textarea value={note} onChange={(event) => setNote(event.target.value)} rows={3}
          placeholder={resolved ? "例如：物流答應補送但尚未到貨" : "例如：8/21 已通知物流，等對方回覆"}
          className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-base dark:border-zinc-700 dark:bg-zinc-800" />
      </label>
      {!resolved && !transferShort && (
        <label className="mt-3 block text-xs"><span className="font-semibold">最後結果（結案必填）</span>
          <textarea value={result} onChange={(event) => setResult(event.target.value)} rows={2} placeholder="例如：供應商 8/25 折讓 $120"
            className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-base dark:border-zinc-700 dark:bg-zinc-800" />
        </label>
      )}
      {transferShort && !resolved && <p className="mt-3 rounded bg-amber-50 p-2 text-xs text-amber-800 dark:bg-amber-950/40 dark:text-amber-300">收貨短少請用列表的「處理」完成真正動作並結案；這裡只能先留下追蹤經過。</p>}
      {error && <div className="mt-3 rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>}
      <div className="mt-4 flex flex-wrap justify-end gap-2">
        <SpinButton onClick={onClose} className="min-h-[44px] rounded-md border border-zinc-300 px-3 text-sm dark:border-zinc-700">關閉</SpinButton>
        {resolved ? (
          <SpinButton onClick={reopen} disabled={busy !== null} className="min-h-[44px] rounded-md bg-amber-600 px-3 text-sm font-semibold text-white disabled:opacity-50">{busy === "reopen" ? "處理中…" : "重新開啟追蹤"}</SpinButton>
        ) : <>
          <SpinButton onClick={addNote} disabled={busy !== null} className="min-h-[44px] rounded-md border border-blue-600 px-3 text-sm font-semibold text-blue-700 disabled:opacity-50 dark:text-blue-300">{busy === "note" ? "儲存中…" : "新增處理經過"}</SpinButton>
          {!transferShort && <SpinButton onClick={resolve} disabled={busy !== null} className="min-h-[44px] rounded-md bg-emerald-600 px-3 text-sm font-semibold text-white disabled:opacity-50">{busy === "resolve" ? "結案中…" : "填結果並結案"}</SpinButton>}
        </>}
      </div>
    </Modal>
  );
}
