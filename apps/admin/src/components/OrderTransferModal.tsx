"use client";

import { useEffect, useRef, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type Store = { id: number; name: string; code: string };
type MemberHit = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  home_store_id: number | null;
  home_store_name: string | null;
  no_new_order: boolean | null;
  admin_note: string | null;
};

export function OrderTransferModal({
  orderId,
  orderNo,
  currentPickupStoreId,
  currentMemberLabel,
  open,
  onClose,
  onSubmitted,
}: {
  orderId: number;
  orderNo: string;
  currentPickupStoreId: number | null;
  currentMemberLabel: string;
  open: boolean;
  onClose: () => void;
  onSubmitted: (newOrderId: number) => void;
}) {
  const [stores, setStores] = useState<Store[]>([]);
  const [toStore, setToStore] = useState<number | "">("");
  const [toMember, setToMember] = useState<number | "internal">("internal");
  const [pickedMember, setPickedMember] = useState<MemberHit | null>(null);
  const [term, setTerm] = useState("");
  const [searchOpen, setSearchOpen] = useState(false);
  const [results, setResults] = useState<MemberHit[]>([]);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const searchWrapRef = useRef<HTMLDivElement | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: ss } = await sb
        .from("stores")
        .select("id, name, code")
        .eq("is_active", true)
        .order("name");
      if (!cancelled) setStores((ss as Store[] | null) ?? []);
    })();
    return () => {
      cancelled = true;
    };
  }, [open]);

  // close member search dropdown when clicking outside
  useEffect(() => {
    if (!searchOpen) return;
    const onDown = (e: MouseEvent) => {
      if (!searchWrapRef.current?.contains(e.target as Node)) setSearchOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [searchOpen]);

  // debounced rpc_search_members (same RPC used by member page / order entry)
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (term.length < 1 && !searchOpen) return;
    debounceRef.current = setTimeout(async () => {
      const sb = getSupabase();
      const { data } = await sb.rpc("rpc_search_members", {
        p_term: term,
        p_limit: 10,
      });
      setResults((data as MemberHit[] | null) ?? []);
    }, 200);
    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [term, searchOpen]);

  const submit = async () => {
    if (!toStore) {
      setErr("請選擇接收店");
      return;
    }
    if (toStore === currentPickupStoreId) {
      if (!confirm("接收店與原店相同（同店換客人）。確定繼續？")) return;
    }
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: { user } } = await sb.auth.getUser();
      const { data, error: e } = await sb.rpc("rpc_transfer_order_to_store", {
        p_order_id: orderId,
        p_to_pickup_store_id: toStore,
        p_to_member_id: toMember === "internal" ? null : toMember,
        p_to_channel_id: null,
        p_operator: user?.id,
        p_reason: reason || null,
      });
      if (e) throw new Error(e.message);
      const newId = data as number;
      onSubmitted(newId);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal open={open} onClose={onClose} title={`轉出訂單 ${orderNo}`} maxWidth="max-w-lg">
      <div className="space-y-3 p-4 text-sm">
        {err && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {err}
          </div>
        )}

        <div className="rounded-md bg-zinc-50 p-2 text-xs text-zinc-600 dark:bg-zinc-900 dark:text-zinc-400">
          原訂單：{currentMemberLabel}（取貨店：
          {stores.find((s) => s.id === currentPickupStoreId)?.name ?? `#${currentPickupStoreId}`}）
        </div>

        <label className="flex flex-col gap-1">
          <span className="text-zinc-500">接收店</span>
          <select
            value={toStore}
            onChange={(e) => {
              const v = e.target.value;
              setToStore(v === "" ? "" : Number(v));
              setToMember("internal");
              setPickedMember(null);
              setTerm("");
              setResults([]);
              setSearchOpen(false);
            }}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">— 請選擇 —</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
        </label>

        {toStore !== "" && (
          <div className="flex flex-col gap-1">
            <span className="text-zinc-500">接收人</span>
            <div className="relative" ref={searchWrapRef}>
              <input
                value={
                  toMember === "internal" && !term && !searchOpen
                    ? "— 掛到接收店店長（內部 member）—"
                    : pickedMember
                      ? `${pickedMember.name ?? "—"} (${pickedMember.member_no})`
                      : term
                }
                onFocus={() => setSearchOpen(true)}
                onChange={(e) => {
                  if (pickedMember || toMember !== "internal") {
                    setPickedMember(null);
                    setToMember("internal");
                  }
                  setTerm(e.target.value);
                  setSearchOpen(true);
                }}
                placeholder="搜尋 會員編號 / 姓名 / 手機"
                className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
              />
              {searchOpen && (
                <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-80 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800">
                  <SpinButton
                    type="button"
                    onClick={() => {
                      setToMember("internal");
                      setPickedMember(null);
                      setTerm("");
                      setSearchOpen(false);
                    }}
                    className={`block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-700 ${
                      toMember === "internal" ? "bg-zinc-50 dark:bg-zinc-900" : ""
                    }`}
                  >
                    — 掛到接收店店長（內部 member）—
                  </SpinButton>
                  {results.length > 0 && (
                    <div className="border-t border-zinc-100 dark:border-zinc-700">
                      <div className="px-2 py-1 text-xs font-medium text-zinc-400">會員</div>
                      {results.map((m) => (
                        <SpinButton
                          key={m.id}
                          type="button"
                          onClick={() => {
                            setToMember(m.id);
                            setPickedMember(m);
                            setTerm("");
                            setSearchOpen(false);
                          }}
                          className="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-700"
                        >
                          <span className="font-medium">{m.name ?? "—"}</span>
                          {m.admin_note && (
                            <span className="ml-1 rounded bg-amber-100 px-1 text-[9px] text-amber-800">
                              🔒 {m.admin_note}
                            </span>
                          )}
                          <span className="ml-2 text-zinc-500">
                            {m.member_no} · {m.phone ?? "—"}
                          </span>
                          {m.no_new_order && (
                            <span className="ml-2 font-medium text-red-600">🚫 黑名單禁加單</span>
                          )}
                          {m.home_store_name && (
                            <span className="ml-2 text-[11px] text-zinc-400">
                              主店：{m.home_store_name}
                            </span>
                          )}
                        </SpinButton>
                      ))}
                    </div>
                  )}
                  {term.length > 0 && results.length === 0 && (
                    <div className="border-t border-zinc-100 px-3 py-2 text-xs text-zinc-400 dark:border-zinc-700">
                      無符合會員
                    </div>
                  )}
                </div>
              )}
            </div>
            <span className="text-[11px] text-zinc-400">
              不選 = 自動建 / 用 store_internal member（適用：店長收下、內部處理）
            </span>
          </div>
        )}

        <label className="flex flex-col gap-1">
          <span className="text-zinc-500">轉出原因</span>
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：客人棄單、改寄朋友店…"
            rows={2}
            className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="flex justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            disabled={busy}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={submit}
            disabled={busy || !toStore}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white disabled:bg-zinc-300"
          >
            {busy ? "轉出中…" : "確認轉出"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
