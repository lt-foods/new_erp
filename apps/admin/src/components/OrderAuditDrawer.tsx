"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";

type AuditRow = {
  id: number;
  entity_type: "order" | "item";
  entity_id: number | null;
  field: "unit_price" | "item_notes" | "item_discount_amount" | "item_discount_percent" | "discount_amount" | "discount_percent" | "order_notes" | "qty" | "status" | "is_gift" | "wallet_paid_amount";
  before_value: unknown;
  after_value: unknown;
  edit_reason: string | null;
  operator_id: string;
  created_at: string;
};

const FIELD_LABEL: Record<string, string> = {
  unit_price: "單價",
  item_notes: "商品備註",
  item_discount_amount: "單品折扣 $",
  item_discount_percent: "單品折扣 %",
  discount_amount: "整單折扣 $",
  discount_percent: "整單折扣 %",
  order_notes: "單頭備註",
  qty: "數量",
  status: "狀態",
  is_gift: "贈品",
  wallet_paid_amount: "已收儲值金",
};

const STATUS_LABEL: Record<string, string> = {
  pending:         "下單",
  confirmed:       "已確認",
  reserved:        "已派貨",
  shipping:        "運送中",
  ready:           "分店收貨",
  picked:          "已取貨",
  completed:       "完成",
  cancelled:       "取消",
  expired:         "過期",
  transferred_out: "已轉出",
};

function valLabel(v: unknown, field?: string): string {
  if (v === null || v === undefined) return "—";
  if (typeof v === "string") {
    if (v === "") return '""';
    if (field === "status") return STATUS_LABEL[v] ?? v;
    return v;
  }
  return String(v);
}

export function OrderAuditDrawer({
  open,
  onClose,
  orderId,
}: {
  open: boolean;
  onClose: () => void;
  orderId: number;
}) {
  const [rows, setRows] = useState<AuditRow[] | null>(null);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error } = await sb
        .from("customer_order_audit_log")
        .select(
          "id, entity_type, entity_id, field, before_value, after_value, edit_reason, operator_id, created_at",
        )
        .eq("order_id", orderId)
        .order("created_at", { ascending: false });
      if (cancelled) return;
      if (error) {
        setRows([]);
        return;
      }
      const rs = (data ?? []) as AuditRow[];
      setRows(rs);
      const uids = Array.from(new Set(rs.map((r) => r.operator_id))).filter(Boolean);
      if (uids.length > 0) {
        const { data: ns } = await sb.rpc("rpc_get_staff_names", { p_uids: uids });
        const m = new Map<string, string>();
        for (const n of (ns as { id: string; display_name: string }[] | null) ?? []) {
          m.set(n.id, n.display_name);
        }
        if (!cancelled) setStaffNames(m);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, orderId]);

  return (
    <Modal open={open} onClose={onClose} title="編輯歷史" maxWidth="max-w-3xl">
      {rows === null ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : rows.length === 0 ? (
        <div className="text-sm text-zinc-500">尚無編輯紀錄</div>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">時間</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">欄位</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">變更</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">操作人</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">修改原因</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {rows.map((r) => (
                <tr key={r.id}>
                  <td className="whitespace-nowrap px-3 py-2 text-zinc-500">
                    {new Date(r.created_at).toLocaleString("zh-TW", { hour12: false })}
                  </td>
                  <td className="whitespace-nowrap px-3 py-2">
                    {FIELD_LABEL[r.field] ?? r.field}
                    {r.entity_type === "item" && r.entity_id != null && (
                      <span className="ml-1 text-[10px] text-zinc-400">#{r.entity_id}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 font-mono">
                    <span className="text-zinc-500 line-through">{valLabel(r.before_value, r.field)}</span>
                    <span className="mx-1">→</span>
                    <span>{valLabel(r.after_value, r.field)}</span>
                  </td>
                  <td className="whitespace-nowrap px-3 py-2 text-zinc-500">
                    {staffNames.get(r.operator_id) ?? r.operator_id.slice(0, 8)}
                  </td>
                  <td className="px-3 py-2 text-zinc-500">{r.edit_reason ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Modal>
  );
}
