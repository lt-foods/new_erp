"use client";

// 把虛擬會員（guest，從 LLM 解析或人工建檔）合併到 LINE 實體會員
// 走既有 rpc_merge_member（自動把 orders / cards / 點數 / 儲值 全搬過去）

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

type Candidate = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  line_user_id: string | null;
  member_type: string | null;
};

export function MemberMergeModal({
  open,
  onClose,
  guestMember,
  onMerged,
}: {
  open: boolean;
  onClose: () => void;
  guestMember: { id: number; name: string | null; phone: string | null; member_no: string };
  onMerged: () => void;
}) {
  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<Candidate[] | null>(null);
  const [target, setTarget] = useState<Candidate | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // 預填查詢字（用 guest 的姓名 or 電話）
  useEffect(() => {
    if (!open) return;
    setQuery(guestMember.phone?.replace(/^line:/, "") || guestMember.name || "");
    setCandidates(null);
    setTarget(null);
    setReason("");
    setErr(null);
  }, [open, guestMember]);

  async function search() {
    const q = query.trim();
    if (q.length < 2) { setErr("請至少輸入 2 字"); return; }
    setErr(null);
    setCandidates(null);
    const sb = getSupabase();
    const safe = q.replace(/[%,()]/g, " ");
    const { data, error } = await sb
      .from("members")
      .select("id, member_no, name, phone, line_user_id, member_type")
      .neq("id", guestMember.id)                  // 不合併自己
      .neq("status", "merged")                     // 已合併的不能再被合
      .neq("status", "deleted")
      .or(`name.ilike.%${safe}%,phone.ilike.%${safe}%,member_no.ilike.%${safe}%`)
      .order("last_visit_at", { ascending: false, nullsFirst: false })
      .limit(20);
    if (error) { setErr(error.message); return; }
    setCandidates((data ?? []) as Candidate[]);
  }

  async function submit() {
    if (!target) { setErr("請選擇要合併到的目標會員"); return; }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }
      const { error } = await sb.rpc("rpc_merge_member", {
        p_guest_id: guestMember.id,
        p_real_id:  target.id,
        p_operator: operator,
        p_reason:   reason || null,
      });
      if (error) { setErr(translateRpcError(error)); return; }
      alert(`合併完成：#${guestMember.member_no} → ${target.name ?? target.member_no}`);
      onMerged();
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`合併虛擬會員 → 真實會員`} maxWidth="max-w-2xl">
      <div className="space-y-4 text-sm">
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-800 dark:bg-amber-950/40">
          <div className="text-xs text-amber-800 dark:text-amber-300">
            <b>來源（虛擬會員）：</b>{guestMember.name ?? "—"}
            <span className="font-mono">{guestMember.member_no}</span>
            {guestMember.phone && <span className="font-mono">{guestMember.phone}</span>}
            <br />
            合併後此會員會被標 <code>merged</code>，所有訂單 / 儲值 / 點數 / 卡片 / 標籤都會搬到目標會員。
          </div>
        </div>

        <div className="flex gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); search(); }}}
            placeholder="搜尋目標會員（姓名 / 電話 / 會員編號）"
            className="flex-1 rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-900"
          />
          <button
            onClick={search}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            🔍 搜尋
          </button>
        </div>

        {candidates !== null && (
          <div className="max-h-64 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-800">
            {candidates.length === 0 ? (
              <p className="p-4 text-center text-xs text-zinc-500">查無對應會員</p>
            ) : (
              <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {candidates.map((c) => (
                  <li
                    key={c.id}
                    onClick={() => setTarget(c)}
                    className={`flex cursor-pointer items-center justify-between gap-3 p-3 hover:bg-zinc-50 dark:hover:bg-zinc-800 ${
                      target?.id === c.id ? "bg-emerald-50 dark:bg-emerald-950" : ""
                    }`}
                  >
                    <div>
                      <div className="font-medium">
                        {c.name ?? "—"}{" "}
                        <span className="ml-1 font-mono text-xs text-zinc-500">{c.member_no}</span>
                      </div>
                      <div className="text-xs text-zinc-500">
                        {c.phone ?? "—"}
                        {c.line_user_id ? <span className="text-emerald-600 dark:text-emerald-400">LINE 已綁</span> : <span className="text-zinc-400">未綁 LINE</span>}
                        　<span className="text-[10px] text-zinc-400">{c.member_type ?? "—"}</span>
                      </div>
                    </div>
                    {target?.id === c.id && (
                      <span className="rounded-md bg-emerald-600 px-2 py-1 text-xs text-white">已選</span>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">合併原因（選填，會記錄到 member_merges）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="如：客人後來綁了 LINE / 同人重複建檔"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </button>
          <button
            onClick={submit}
            disabled={busy || !target}
            className="rounded-md bg-rose-600 px-4 py-2 text-sm font-medium text-white hover:bg-rose-700 disabled:opacity-50"
          >
            {busy ? "合併中…" : "✅ 確認合併（不可還原）"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
