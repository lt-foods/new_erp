"use client";

// 會員合併（重複建檔合併 — 把「未綁 LINE 的會員」併進「已綁 LINE 的會員」）
// 兩個方向共用同一支 rpc_merge_member（RPC 守衛：source.line_user_id IS NULL）
// - direction="guest-to-real":   從未綁 LINE 端開（既有「合併到實體會員」按鈕）
// - direction="real-from-guest": 從已綁 LINE 端開（新「合併進來」按鈕）
// rpc_merge_member 會搬：訂單 / 卡片 / 點數 / 儲值 / 標籤 / 暱稱對應 / 流水

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

type Direction = "guest-to-real" | "real-from-guest";

type AnchorMember = { id: number; name: string | null; phone: string | null; member_no: string };

export function MemberMergeModal({
  open,
  onClose,
  guestMember,
  realMember,
  onMerged,
}: {
  open: boolean;
  onClose: () => void;
  /** mode = guest-to-real：傳 guestMember；mode = real-from-guest：傳 realMember */
  guestMember?: AnchorMember;
  realMember?: AnchorMember;
  onMerged: () => void;
}) {
  const direction: Direction = guestMember ? "guest-to-real" : "real-from-guest";
  const anchor: AnchorMember | null = guestMember ?? realMember ?? null;

  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<Candidate[] | null>(null);
  const [target, setTarget] = useState<Candidate | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open || !anchor) return;
    // guest-to-real：用 guest 的姓名/手機去搜實體會員
    // real-from-guest：搜尋框留空（實體會員的姓名通常跟 guest 不同，guest 多半是 LLM 從留言抓 nickname）
    setQuery(direction === "guest-to-real"
      ? (anchor.phone?.replace(/^line:/, "") || anchor.name || "")
      : "");
    setCandidates(null);
    setTarget(null);
    setReason("");
    setErr(null);
  }, [open, anchor, direction]);

  async function search() {
    if (!anchor) return;
    const q = query.trim();
    if (q.length < 2) { setErr("請至少輸入 2 字"); return; }
    setErr(null);
    setCandidates(null);
    const sb = getSupabase();
    const safe = q.replace(/[%,()]/g, " ");
    let req = sb
      .from("members")
      .select("id, member_no, name, phone, line_user_id, member_type")
      .neq("id", anchor.id)
      .or(`name.ilike.%${safe}%,phone.ilike.%${safe}%,member_no.ilike.%${safe}%`)
      .order("last_visit_at", { ascending: false, nullsFirst: false })
      .limit(20);

    if (direction === "guest-to-real") {
      // 找合併目標：必須已綁 LINE、status active
      req = req
        .not("line_user_id", "is", null)
        .eq("status", "active");
    } else {
      // 找被合併進來的會員：必須未綁 LINE、status active（不能合 merged 進來）
      req = req
        .is("line_user_id", null)
        .eq("status", "active");
    }

    const { data, error } = await req;
    if (error) { setErr(error.message); return; }
    setCandidates((data ?? []) as Candidate[]);
  }

  async function submit() {
    if (!anchor || !target) { setErr("請選擇合併對象"); return; }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) { setErr("尚未登入"); return; }

      const guestId = direction === "guest-to-real" ? anchor.id : target.id;
      const realId  = direction === "guest-to-real" ? target.id : anchor.id;

      const { error } = await sb.rpc("rpc_merge_member", {
        p_guest_id: guestId,
        p_real_id:  realId,
        p_operator: operator,
        p_reason:   reason || null,
      });
      if (error) { setErr(translateRpcError(error)); return; }
      const guestLabel = direction === "guest-to-real" ? anchor.member_no : target.member_no;
      const realLabel  = direction === "guest-to-real" ? (target.name ?? target.member_no) : (anchor.name ?? anchor.member_no);
      alert(`合併完成：#${guestLabel} → ${realLabel}`);
      onMerged();
    } finally {
      setBusy(false);
    }
  }

  if (!anchor) return null;

  const title = direction === "guest-to-real"
    ? "合併到已綁 LINE 的會員"
    : "把『未綁 LINE 的會員』合併進來";

  return (
    <Modal open={open} onClose={onClose} title={title} maxWidth="max-w-2xl">
      <div className="space-y-4 text-sm">
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 dark:border-amber-800 dark:bg-amber-950/40">
          <div className="text-xs text-amber-800 dark:text-amber-300">
            {direction === "guest-to-real" ? (
              <>
                <b>來源（未綁 LINE 的這筆，會被標 merged）：</b>{anchor.name ?? "—"}
                <span className="ml-1 font-mono">{anchor.member_no}</span>
                {anchor.phone && <span className="ml-1 font-mono">{anchor.phone}</span>}
              </>
            ) : (
              <>
                <b>目標（此筆已綁 LINE 的會員，訂單會搬來這）：</b>{anchor.name ?? "—"}
                <span className="ml-1 font-mono">{anchor.member_no}</span>
                {anchor.phone && <span className="ml-1 font-mono">{anchor.phone}</span>}
              </>
            )}
            <br />
            合併後來源會被標 <code>merged</code>，所有訂單 / 儲值 / 點數 / 卡片 / 標籤都會搬到目標。
          </div>
        </div>

        <div className="flex gap-2">
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); search(); }}}
            placeholder={direction === "guest-to-real"
              ? "搜尋目標：已綁 LINE 的會員（姓名 / 電話 / 會員編號）"
              : "搜尋要合併進來的：未綁 LINE 的會員（姓名 / 電話 / 會員編號）"}
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
                        {c.phone && !c.phone.startsWith("line:") ? c.phone : "—"}
                        {c.line_user_id ? <span className="ml-2 text-emerald-600 dark:text-emerald-400">LINE 已綁</span> : <span className="ml-2 text-zinc-400">未綁 LINE</span>}
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
