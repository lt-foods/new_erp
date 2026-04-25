"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import { getSupabase } from "@/lib/supabase";

type Supplier = {
  id: number;
  name: string;
  preferred_po_channel: string | null;
  line_contact: string | null;
  email: string | null;
  phone: string | null;
};

type POItem = {
  sku_code: string;
  product_name: string;
  qty_ordered: number;
  unit_cost: number;
  unit_uom: string | null;
};

export function SendPOModal({
  open,
  onClose,
  poId,
  poNo,
  supplier,
  items,
  total,
  onSent,
}: {
  open: boolean;
  onClose: () => void;
  poId: number;
  poNo: string;
  supplier: Supplier | null;
  items: POItem[];
  total: number;
  onSent: () => void;
}) {
  const [channel, setChannel] = useState<string>("line");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (open && supplier?.preferred_po_channel) {
      setChannel(supplier.preferred_po_channel);
    }
  }, [open, supplier?.preferred_po_channel]);

  const lineText = useMemo(() => {
    if (!supplier) return "";
    const lines: string[] = [];
    lines.push(`【採購單 ${poNo}】`);
    lines.push(`供應商：${supplier.name}`);
    lines.push(`下單日：${new Date().toLocaleDateString("zh-TW")}`);
    lines.push("");
    items.forEach((it, i) => {
      lines.push(
        `${i + 1}. ${it.product_name} ${it.sku_code} × ${it.qty_ordered}${it.unit_uom ?? ""} @ $${it.unit_cost.toFixed(0)}`,
      );
    });
    lines.push("");
    lines.push(`未稅總計：$${total.toFixed(0)}`);
    return lines.join("\n");
  }, [supplier, poNo, items, total]);

  const mailtoHref = useMemo(() => {
    if (!supplier?.email) return null;
    const subject = encodeURIComponent(`採購單 ${poNo} - ${supplier.name}`);
    const body = encodeURIComponent(lineText);
    return `mailto:${supplier.email}?subject=${subject}&body=${body}`;
  }, [supplier, poNo, lineText]);

  async function copyText() {
    try {
      await navigator.clipboard.writeText(lineText);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  async function confirmSend() {
    if (!confirm(`確定標記為已發送（${channel}）？此動作不可復原。`)) return;
    setBusy(true);
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_send_purchase_order", {
        p_po_id: poId,
        p_channel: channel,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      onSent();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title={`發送採購訂單 ${poNo}`} maxWidth="max-w-3xl">
      {!supplier ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : (
        <div className="space-y-4">
          {/* 通路選擇 */}
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-5">
            {(["line", "email", "phone", "fax", "manual"] as const).map((c) => {
              const isPreferred = supplier.preferred_po_channel === c;
              return (
                <button
                  key={c}
                  onClick={() => setChannel(c)}
                  className={`rounded-md border px-3 py-2 text-sm ${
                    channel === c
                      ? "border-blue-500 bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300"
                      : "border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                  }`}
                >
                  {channelLabel(c)}
                  {isPreferred && <span className="ml-1 text-xs text-zinc-500">★</span>}
                </button>
              );
            })}
          </div>

          {/* 通路內容 */}
          {channel === "line" && (
            <div className="space-y-3">
              <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-700 dark:bg-zinc-900">
                <div className="mb-2 flex items-center justify-between">
                  <div className="text-zinc-600 dark:text-zinc-400">
                    LINE 聯絡：
                    <span className="font-mono">{supplier.line_contact || "（未設定，請至供應商主檔補）"}</span>
                  </div>
                  <button
                    onClick={copyText}
                    className="rounded-md bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-500"
                  >
                    {copied ? "✓ 已複製" : "📋 複製文字"}
                  </button>
                </div>
                <pre className="whitespace-pre-wrap font-mono text-xs text-zinc-800 dark:text-zinc-200">{lineText}</pre>
              </div>
              <p className="text-xs text-zinc-500">複製後到 LINE 貼給供應商，貼完按下方確認。</p>
            </div>
          )}

          {channel === "email" && (
            <div className="space-y-3">
              <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-700 dark:bg-zinc-900">
                <div className="mb-2 text-zinc-600 dark:text-zinc-400">
                  Email：<span className="font-mono">{supplier.email || "（未設定）"}</span>
                </div>
                {mailtoHref ? (
                  <a
                    href={mailtoHref}
                    className="inline-block rounded-md bg-blue-600 px-3 py-1 text-xs font-medium text-white hover:bg-blue-500"
                  >
                    📧 開啟 Email 草稿
                  </a>
                ) : (
                  <span className="text-xs text-red-600">供應商未設 Email</span>
                )}
                <pre className="mt-2 whitespace-pre-wrap font-mono text-xs text-zinc-800 dark:text-zinc-200">{lineText}</pre>
              </div>
            </div>
          )}

          {channel === "phone" && (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-700 dark:bg-zinc-900">
              <div className="mb-2 text-zinc-600 dark:text-zinc-400">
                電話：<span className="font-mono">{supplier.phone || "（未設定）"}</span>
              </div>
              <p className="text-zinc-500">請電話告知後按確認。</p>
            </div>
          )}

          {(channel === "fax" || channel === "manual") && (
            <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs dark:border-zinc-700 dark:bg-zinc-900">
              <p className="text-zinc-500">{channel === "fax" ? "傳真" : "其他方式"}下單，按確認後紀錄發送時間。</p>
            </div>
          )}

          {error && (
            <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
              {error}
            </div>
          )}

          {/* 動作 */}
          <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-700">
            <button
              onClick={onClose}
              disabled={busy}
              className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              取消
            </button>
            <button
              onClick={confirmSend}
              disabled={busy}
              className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
            >
              {busy ? "發送中…" : "✅ 確認已發送"}
            </button>
          </div>
        </div>
      )}
    </Modal>
  );
}

function channelLabel(c: string): string {
  switch (c) {
    case "line":
      return "LINE";
    case "email":
      return "Email";
    case "phone":
      return "電話";
    case "fax":
      return "傳真";
    case "manual":
      return "手動";
    default:
      return c;
  }
}
