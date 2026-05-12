"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { parseLeleMemberCsv, downloadLeleTemplate, type LeleMemberRow } from "@/lib/parseLeleMemberCsv";
import SpinButton from "@/components/SpinButton";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow } from "@/components/DataTable";

type ValidationStatus =
  | "pending"
  | "ok"
  | "duplicate_existing"
  | "duplicate_in_batch"
  | "error"
  | "committed"
  | "cancelled"
  | "error_at_commit";

type StagedRow = {
  id: number;
  row_index: number;
  parsed_external_id: string | null;
  parsed_name: string | null;
  parsed_name_suffix: string | null;
  parsed_takeout_store_name_hint: string | null;
  parsed_home_store_id: number | null;
  parsed_joined_at: string | null;
  parsed_last_visit_at: string | null;
  validation_status: ValidationStatus;
  validation_errors: { field: string; code: string; value?: string }[];
  resolved_member_id: number | null;
};

type StageStats = {
  total: number;
  ok: number;
  duplicate_in_batch: number;
  duplicate_existing: number;
  errors: number;
};

type Phase = "pristine" | "parsed" | "staged" | "committed";

const PREVIEW_LIMIT = 50;

function statusChip(s: ValidationStatus) {
  const map: Record<ValidationStatus, { label: string; cls: string }> = {
    pending:            { label: "待驗證", cls: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300" },
    ok:                 { label: "可匯入", cls: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300" },
    duplicate_existing: { label: "已存在",  cls: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300" },
    duplicate_in_batch: { label: "批內重複", cls: "bg-amber-100 text-amber-700 dark:bg-amber-950 dark:text-amber-300" },
    error:              { label: "錯誤",    cls: "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300" },
    committed:          { label: "已匯入",  cls: "bg-sky-100 text-sky-700 dark:bg-sky-950 dark:text-sky-300" },
    cancelled:          { label: "已取消",  cls: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400" },
    error_at_commit:    { label: "匯入失敗", cls: "bg-rose-100 text-rose-700 dark:bg-rose-950 dark:text-rose-300" },
  };
  const m = map[s];
  return <span className={`inline-flex rounded-full px-2 py-0.5 text-xs ${m.cls}`}>{m.label}</span>;
}

export default function MemberImportPage() {
  const [phase, setPhase] = useState<Phase>("pristine");
  const [file, setFile] = useState<File | null>(null);
  const [parsedRows, setParsedRows] = useState<LeleMemberRow[]>([]);
  const [parseError, setParseError] = useState<string | null>(null);
  const [batchId, setBatchId] = useState<string | null>(null);
  const [stats, setStats] = useState<StageStats | null>(null);
  const [stagedRows, setStagedRows] = useState<StagedRow[]>([]);
  const [stagedTotal, setStagedTotal] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [commitResult, setCommitResult] = useState<{ committed: number; skipped: number } | null>(null);
  const [confirmCommit, setConfirmCommit] = useState(false);

  const onPickFile = useCallback(async (f: File | null) => {
    setError(null);
    setParseError(null);
    setFile(f);
    setParsedRows([]);
    setStats(null);
    setStagedRows([]);
    setBatchId(null);
    setCommitResult(null);
    setPhase("pristine");
    if (!f) return;
    const result = await parseLeleMemberCsv(f);
    if (!result.ok) {
      setParseError(result.error);
      return;
    }
    setParsedRows(result.rows);
    setPhase("parsed");
  }, []);

  const handleStage = useCallback(async () => {
    if (!parsedRows.length) return;
    setError(null);
    const bid = (typeof crypto !== "undefined" && "randomUUID" in crypto)
      ? crypto.randomUUID()
      : `b_${Date.now()}_${Math.random().toString(36).slice(2)}`;

    const payload = parsedRows.map((r) => ({
      external_id: r.external_id,
      name_raw: r.name_raw,
      label: r.label,
      joined_at: r.joined_at,
      last_visit_at: r.last_visit_at,
    }));

    const { data, error: err } = await getSupabase().rpc("rpc_stage_member_import", {
      p_batch_id: bid,
      p_source: "lele",
      p_rows: payload,
    });
    if (err) {
      setError(err.message);
      return;
    }
    setBatchId(bid);
    setStats(data as StageStats);
    await reloadStaged(bid);
    setPhase("staged");
  }, [parsedRows]);

  const reloadStaged = useCallback(async (bid: string) => {
    const { data, error: err, count } = await getSupabase()
      .from("member_imports")
      .select(
        "id, row_index, parsed_external_id, parsed_name, parsed_name_suffix, parsed_takeout_store_name_hint, parsed_home_store_id, parsed_joined_at, parsed_last_visit_at, validation_status, validation_errors, resolved_member_id",
        { count: "exact" },
      )
      .eq("batch_id", bid)
      .order("row_index", { ascending: true })
      .limit(PREVIEW_LIMIT);
    if (err) {
      setError(err.message);
      return;
    }
    setStagedRows((data ?? []) as StagedRow[]);
    setStagedTotal(count ?? 0);
  }, []);

  const handleCommit = useCallback(async () => {
    if (!batchId) return;
    setError(null);
    const { data, error: err } = await getSupabase().rpc("rpc_commit_member_import", {
      p_batch_id: batchId,
    });
    if (err) {
      setError(err.message);
      return;
    }
    setCommitResult(data as { committed: number; skipped: number });
    setConfirmCommit(false);
    await reloadStaged(batchId);
    setPhase("committed");
  }, [batchId, reloadStaged]);

  const handleCancel = useCallback(async () => {
    if (!batchId) return;
    setError(null);
    const { error: err } = await getSupabase().rpc("rpc_cancel_member_import", {
      p_batch_id: batchId,
    });
    if (err) {
      setError(err.message);
      return;
    }
    setBatchId(null);
    setStagedRows([]);
    setStats(null);
    setPhase("pristine");
    setFile(null);
    setParsedRows([]);
  }, [batchId]);

  const canCommit = useMemo(() => phase === "staged" && (stats?.ok ?? 0) > 0, [phase, stats]);

  return (
    <div className="space-y-4 p-6">
      <header className="flex items-center justify-between gap-4">
        <div>
          <h1 className="text-lg font-semibold">會員匯入（樂樂顧客 CSV）</h1>
          <p className="mt-1 text-xs text-zinc-500">
            從樂樂團購訂單管理系統「顧客管理」匯出 CSV，以「顧客代號」為 dedupe key 比對既有會員。
          </p>
        </div>
        <div className="flex items-center gap-2">
          <SpinButton
            onClick={() => downloadLeleTemplate()}
            className="whitespace-nowrap rounded-md border border-zinc-300 bg-white px-3 py-2 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
          >
            下載範本 CSV
          </SpinButton>
          <Link
            href="/members"
            className="whitespace-nowrap rounded-md border border-zinc-300 bg-white px-3 py-2 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
          >
            ← 回會員列表
          </Link>
        </div>
      </header>

      {/* 步驟 1：選檔 */}
      <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
        <h2 className="mb-2 text-sm font-medium">① 選擇 CSV 檔案</h2>
        <input
          type="file"
          accept=".csv,text/csv"
          onChange={(e) => onPickFile(e.target.files?.[0] ?? null)}
          className="block w-full text-sm file:mr-3 file:rounded-md file:border-0 file:bg-zinc-900 file:px-3 file:py-2 file:text-white hover:file:bg-zinc-800 dark:file:bg-zinc-100 dark:file:text-zinc-900"
        />
        {file && (
          <p className="mt-2 text-xs text-zinc-500">
            {file.name}（{(file.size / 1024).toFixed(1)} KB）
            {parsedRows.length > 0 && ` · 解析 ${parsedRows.length} 筆`}
          </p>
        )}
        {parseError && (
          <p className="mt-2 text-xs text-rose-600">{parseError}</p>
        )}
      </section>

      {/* 步驟 2：stage */}
      {phase === "parsed" && (
        <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="mb-2 text-sm font-medium">② 上傳到 staging 驗證</h2>
          <p className="text-xs text-zinc-500">
            客端已解析 {parsedRows.length} 筆。下一步上傳到 staging 由後端驗證去重、解析名字、對應取貨店。
          </p>
          <div className="mt-3 flex gap-2">
            <SpinButton
              onClick={handleStage}
              className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
            >
              上傳到 staging
            </SpinButton>
          </div>
        </section>
      )}

      {/* 步驟 3：staged 預覽 + commit */}
      {(phase === "staged" || phase === "committed") && stats && (
        <section className="space-y-3 rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
          <h2 className="text-sm font-medium">
            {phase === "committed" ? "④ 匯入完成" : "③ 驗證結果"}
          </h2>
          <div className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-5">
            <Stat label="總筆數" value={stats.total} />
            <Stat label="可匯入" value={stats.ok} tone="emerald" />
            <Stat label="已存在" value={stats.duplicate_existing} tone="amber" />
            <Stat label="批內重複" value={stats.duplicate_in_batch} tone="amber" />
            <Stat label="錯誤" value={stats.errors} tone="rose" />
          </div>

          {commitResult && (
            <div className="rounded-md border border-sky-200 bg-sky-50 p-3 text-xs text-sky-800 dark:border-sky-900 dark:bg-sky-950 dark:text-sky-200">
              已寫入 {commitResult.committed} 筆 / 跳過 {commitResult.skipped} 筆。
              <Link href="/members" className="ml-2 underline">前往會員列表</Link>
            </div>
          )}

          <div className="text-xs text-zinc-500">
            預覽前 {Math.min(PREVIEW_LIMIT, stagedTotal)} 筆（共 {stagedTotal} 筆）
          </div>

          <Table>
            <THead>
              <Th>#</Th>
              <Th>樂樂代號</Th>
              <Th>姓名</Th>
              <Th>取貨店 hint</Th>
              <Th>取貨店對應</Th>
              <Th>加入日期</Th>
              <Th>狀態</Th>
              <Th>錯誤</Th>
            </THead>
            <TBody>
              {stagedRows.length === 0 ? (
                <EmptyRow colSpan={8}>還沒有 staging 資料</EmptyRow>
              ) : (
                stagedRows.map((r) => (
                  <Tr key={r.id}>
                    <Td className="font-mono text-xs text-zinc-400">{r.row_index}</Td>
                    <Td className="font-mono text-xs">{r.parsed_external_id ?? "—"}</Td>
                    <Td>
                      {r.parsed_name ?? "—"}
                      {r.parsed_name_suffix && (
                        <span className="ml-1 text-xs text-zinc-400">／{r.parsed_name_suffix}</span>
                      )}
                    </Td>
                    <Td className="text-xs">{r.parsed_takeout_store_name_hint ?? "—"}</Td>
                    <Td className="text-xs">{r.parsed_home_store_id ? `store#${r.parsed_home_store_id}` : "—"}</Td>
                    <Td className="text-xs">{r.parsed_joined_at?.slice(0, 10) ?? "—"}</Td>
                    <Td>{statusChip(r.validation_status)}</Td>
                    <Td className="text-xs text-rose-600">
                      {r.validation_errors?.length
                        ? r.validation_errors.map((e) => `${e.field}:${e.code}`).join("、")
                        : "—"}
                    </Td>
                  </Tr>
                ))
              )}
            </TBody>
          </Table>

          {phase === "staged" && (
            <div className="flex justify-end gap-2 pt-2">
              <SpinButton
                onClick={handleCancel}
                className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
              >
                取消批次
              </SpinButton>
              <SpinButton
                onClick={() => setConfirmCommit(true)}
                disabled={!canCommit}
                className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                確認匯入 {stats.ok} 筆
              </SpinButton>
            </div>
          )}
        </section>
      )}

      {/* commit 二次確認 */}
      {confirmCommit && stats && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/50 px-4">
          <div className="w-full max-w-md rounded-lg border border-zinc-200 bg-white p-5 shadow-xl dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="text-base font-semibold">確認匯入</h3>
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
              將寫入 <b>{stats.ok}</b> 筆新會員。
              {stats.duplicate_existing > 0 && <> 已存在 {stats.duplicate_existing} 筆不重複寫入。</>}
            </p>
            <div className="mt-4 flex justify-end gap-2">
              <SpinButton
                onClick={() => setConfirmCommit(false)}
                className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:hover:bg-zinc-800"
              >
                取消
              </SpinButton>
              <SpinButton
                onClick={handleCommit}
                className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-700"
              >
                確認匯入
              </SpinButton>
            </div>
          </div>
        </div>
      )}

      {error && (
        <div className="rounded-md border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
          <p className="font-medium">操作失敗</p>
          <p className="mt-1 font-mono text-xs">{error}</p>
        </div>
      )}
    </div>
  );
}

function Stat({ label, value, tone }: { label: string; value: number; tone?: "emerald" | "amber" | "rose" }) {
  const toneCls =
    tone === "emerald" ? "text-emerald-600 dark:text-emerald-400" :
    tone === "amber"   ? "text-amber-600 dark:text-amber-400" :
    tone === "rose"    ? "text-rose-600 dark:text-rose-400" :
                         "text-zinc-900 dark:text-zinc-100";
  return (
    <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-800/50">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`text-lg font-semibold ${toneCls}`}>{value}</div>
    </div>
  );
}
