"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type Store = { id: number; name: string; code: string };
type Member = {
  id: number;
  member_no: string;
  name: string | null;
  member_type: string;
  home_store_id: number | null;
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
  const [members, setMembers] = useState<Member[]>([]);
  const [toStore, setToStore] = useState<number | "">("");
  const [toMember, setToMember] = useState<number | "internal">("internal");
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

  // load home members of selected store (for picker)
  useEffect(() => {
    if (toStore === "" || toStore === 0) {
      setMembers([]);
      return;
    }
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data: ms } = await sb
        .from("members")
        .select("id, member_no, name, member_type, home_store_id")
        .eq("home_store_id", toStore)
        .neq("member_type", "store_internal")
        .order("name")
        .limit(50);
      if (!cancelled) setMembers((ms as Member[] | null) ?? []);
    })();
    return () => {
      cancelled = true;
    };
  }, [toStore]);

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
          <label className="flex flex-col gap-1">
            <span className="text-zinc-500">接收人</span>
            <select
              value={toMember}
              onChange={(e) =>
                setToMember(e.target.value === "internal" ? "internal" : Number(e.target.value))
              }
              className="rounded-md border border-zinc-300 bg-white px-2 py-1 dark:border-zinc-700 dark:bg-zinc-800"
            >
              <option value="internal">— 掛到接收店店長（內部 member）—</option>
              {members.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.name ?? "—"} ({m.member_no})
                </option>
              ))}
            </select>
            <span className="text-[11px] text-zinc-400">
              不選 = 自動建 / 用 store_internal member（適用：店長收下、內部處理）
            </span>
          </label>
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
