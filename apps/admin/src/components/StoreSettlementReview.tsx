"use client";

// 分店端「月結對帳」：總部送單後線上核對。
// - 逐行核對，有問題的行按「有問題」+ 必填備註 → 送出爭議（換總部處理）
// - 全部無誤 → 同意畫押（鎖定、產生應付帳款）
// - 匯款後按「我已匯款」（可附帳號後五碼），等總部確認收款結案
// 只顯示分店價口徑（單價/小計），不顯示總倉成本。

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { useAuth } from "@/components/AuthProvider";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";

type StoreRow = { id: number; code: string; name: string };

type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  item_count: number;
  status: "sent" | "disputed" | "confirmed" | "remitted" | "settled" | "draft" | "cancelled";
  sent_at: string | null;
  store_agreed_at: string | null;
  remitted_at: string | null;
  remit_note: string | null;
  settled_at: string | null;
};

type Item = {
  id: number;
  transfer_id: number;
  transfer_item_id: number;
  sku_id: number;
  qty_received: number;
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
};

type Dispute = {
  id: number;
  transfer_item_id: number;
  reason: string;
  status: "open" | "resolved";
  resolution_note: string | null;
};

type Transfer = { id: number; transfer_no: string };
type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };

const ENTRY_TYPE_LABEL: Record<Item["entry_type"], string> = {
  hq_inbound: "總倉進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

const STATUS_LABEL: Record<string, string> = {
  sent: "待核對",
  disputed: "爭議處理中",
  confirmed: "已同意待匯款",
  remitted: "已匯款待總部確認",
  settled: "已結案",
};
const STATUS_COLOR: Record<string, string> = {
  sent: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  disputed: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  remitted: "bg-indigo-100 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-300",
  settled: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
};

export default function StoreSettlementReview() {
  const { user } = useAuth();
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [pickedStoreId, setPickedStoreId] = useState<number | null>(null);
  const [rows, setRows] = useState<Settlement[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [detail, setDetail] = useState<Settlement | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase().from("stores").select("id, code, name").order("name");
      if (cancelled) return;
      setStores((data ?? []) as StoreRow[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 帳號綁定的店（app_metadata.stores 店名 → stores 列）
  const myStores = useMemo(() => {
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores)) return [];
    return stores.filter((s) => userStores.includes(s.name));
  }, [user, stores]);
  const storeId = pickedStoreId ?? myStores[0]?.id ?? null;

  useEffect(() => {
    if (storeId === null) return;
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase()
        .from("store_monthly_settlements")
        .select("id, settlement_month, store_id, payable_amount, item_count, status, sent_at, store_agreed_at, remitted_at, remit_note, settled_at")
        .eq("store_id", storeId)
        .in("status", ["sent", "disputed", "confirmed", "remitted", "settled"])
        .order("settlement_month", { ascending: false })
        .limit(24);
      if (cancelled) return;
      if (e) { setError(e.message); setRows([]); return; }
      setError(null);
      setRows((data ?? []) as Settlement[]);
    })();
    return () => { cancelled = true; };
  }, [storeId, reloadTick]);

  if (user && myStores.length === 0 && stores.length > 0) {
    return (
      <p className="rounded-md border border-amber-300 bg-amber-50 p-4 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
        此帳號未綁定分店，請聯絡總部設定。
      </p>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      {myStores.length > 1 && (
        <label className="text-sm">
          <span className="mb-1 block text-xs text-zinc-500">分店</span>
          <select
            value={storeId ?? ""}
            onChange={(e) => setPickedStoreId(Number(e.target.value) || null)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            {myStores.map((s) => (
              <option key={s.id} value={s.id}>{s.name}</option>
            ))}
          </select>
        </label>
      )}

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{error}</p>
        </div>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">月份</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">應付金額</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">明細行數</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">狀態</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">動作</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {rows === null ? (
              <tr><td colSpan={5} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : rows.length === 0 ? (
              <tr><td colSpan={5} className="p-6 text-center text-zinc-500">目前沒有待處理的對帳單。</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                <td className="px-3 py-2 font-mono text-xs">{r.settlement_month?.slice(0, 7)}</td>
                <td className="px-3 py-2 text-right font-mono text-rose-600">
                  ${Number(r.payable_amount).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                </td>
                <td className="px-3 py-2 text-right font-mono">{r.item_count}</td>
                <td className="px-3 py-2">
                  <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[r.status] ?? ""}`}>
                    {STATUS_LABEL[r.status] ?? r.status}
                  </span>
                </td>
                <td className="px-3 py-2 text-right">
                  <SpinButton
                    onClick={() => setDetail(r)}
                    className={`rounded-md px-3 py-1 text-xs ${
                      r.status === "sent" || r.status === "confirmed"
                        ? "bg-blue-600 font-medium text-white hover:bg-blue-700"
                        : "border border-zinc-300 hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
                    }`}
                  >
                    {r.status === "sent" ? "核對" : r.status === "confirmed" ? "回報匯款" : "查看"}
                  </SpinButton>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <Modal
        open={detail !== null}
        onClose={() => setDetail(null)}
        title={detail ? `${detail.settlement_month?.slice(0, 7)} 月結對帳單` : ""}
        maxWidth="max-w-3xl"
      >
        {detail && (
          <ReviewDetail
            key={detail.id}
            settlement={detail}
            onChanged={() => {
              setDetail(null);
              setReloadTick((t) => t + 1);
            }}
          />
        )}
      </Modal>
    </div>
  );
}

function ReviewDetail({ settlement, onChanged }: { settlement: Settlement; onChanged: () => void }) {
  const [items, setItems] = useState<Item[] | null>(null);
  const [disputes, setDisputes] = useState<Dispute[]>([]);
  const [transfers, setTransfers] = useState<Map<number, Transfer>>(new Map());
  const [skus, setSkus] = useState<Map<number, Sku>>(new Map());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // 有問題的行：transfer_item_id → 備註
  const [flags, setFlags] = useState<Map<number, string>>(new Map());
  const [remitNote, setRemitNote] = useState("");

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [{ data, error }, { data: dData }] = await Promise.all([
        sb
          .from("store_monthly_settlement_items")
          .select("id, transfer_id, transfer_item_id, sku_id, qty_received, unit_branch_price, branch_amount, received_at, entry_type, description")
          .eq("settlement_id", settlement.id)
          .order("entry_type", { ascending: true })
          .order("received_at", { ascending: true }),
        sb
          .from("store_settlement_disputes")
          .select("id, transfer_item_id, reason, status, resolution_note")
          .eq("settlement_id", settlement.id)
          .order("raised_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (error) { setErr(error.message); setItems([]); return; }
      setDisputes((dData ?? []) as Dispute[]);
      const list = (data ?? []) as Item[];
      setItems(list);

      const txIds = Array.from(new Set(list.map((it) => it.transfer_id)));
      const skuIds = Array.from(new Set(list.map((it) => it.sku_id)));
      const [{ data: tx }, { data: sk }] = await Promise.all([
        txIds.length ? sb.from("transfers").select("id, transfer_no").in("id", txIds) : Promise.resolve({ data: [] as Transfer[] }),
        skuIds.length ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds) : Promise.resolve({ data: [] as Sku[] }),
      ]);
      if (cancelled) return;
      const tm = new Map<number, Transfer>();
      for (const t of (tx ?? []) as Transfer[]) tm.set(t.id, t);
      setTransfers(tm);
      const sm = new Map<number, Sku>();
      for (const s of (sk ?? []) as Sku[]) sm.set(s.id, s);
      setSkus(sm);
    })();
    return () => { cancelled = true; };
  }, [settlement.id]);

  const disputeByItem = useMemo(() => {
    const m = new Map<number, Dispute>();
    for (const d of disputes) {
      const prev = m.get(d.transfer_item_id);
      if (!prev || d.status === "open") m.set(d.transfer_item_id, d);
    }
    return m;
  }, [disputes]);

  // 爭議行排最上方
  const sortedItems = useMemo(() => {
    if (!items) return null;
    const rank = (it: Item) => {
      const d = disputeByItem.get(it.transfer_item_id);
      if (d?.status === "open") return 0;
      if (d) return 1;
      return 2;
    };
    return [...items].sort((a, b) => rank(a) - rank(b));
  }, [items, disputeByItem]);

  const isSent = settlement.status === "sent";
  const flaggedCount = flags.size;
  const allReasonsFilled = Array.from(flags.values()).every((v) => v.trim().length > 0);
  const total = (items ?? []).reduce((s, it) => s + Number(it.branch_amount ?? 0), 0);

  async function callRpc(fn: string, params: Record<string, unknown>) {
    setBusy(true);
    setErr(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error } = await sb.rpc(fn, { ...params, p_operator: operator });
      if (error) throw new Error(error.message);
      onChanged();
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function onAgree() {
    if (flaggedCount > 0) return;
    if (!confirm("確認整份對帳單無誤並同意畫押？同意後金額鎖定、產生應付帳款，不可再提出爭議。")) return;
    void callRpc("rpc_store_review_settlement", {
      p_settlement_id: settlement.id,
      p_agree: true,
      p_disputes: null,
    });
  }

  function onSubmitDisputes() {
    if (flaggedCount === 0 || !allReasonsFilled) return;
    if (!confirm(`送出 ${flaggedCount} 筆爭議給總部處理？`)) return;
    void callRpc("rpc_store_review_settlement", {
      p_settlement_id: settlement.id,
      p_agree: false,
      p_disputes: Array.from(flags.entries()).map(([transfer_item_id, reason]) => ({
        transfer_item_id,
        reason: reason.trim(),
      })),
    });
  }

  function onRemit() {
    if (!confirm("確認已匯款給總部？")) return;
    void callRpc("rpc_mark_settlement_remitted", {
      p_settlement_id: settlement.id,
      p_note: remitNote.trim() || null,
    });
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="text-sm">
          應付總部金額：
          <span className="ml-1 font-mono text-lg font-semibold text-rose-600">
            ${Number(settlement.payable_amount).toLocaleString("zh-TW")}
          </span>
        </div>
        <span className={`inline-block rounded px-2 py-0.5 text-xs ${STATUS_COLOR[settlement.status] ?? ""}`}>
          {STATUS_LABEL[settlement.status] ?? settlement.status}
        </span>
      </div>

      {settlement.status === "disputed" && (
        <div className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          已送出爭議，等總部處理後會重新送來核對。爭議行列在最上方。
        </div>
      )}
      {settlement.status === "confirmed" && (
        <div className="rounded-md border border-blue-300 bg-blue-50 p-3 text-sm text-blue-800 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-300">
          🔒 對帳單已同意鎖定。請匯款 <span className="font-mono font-semibold">${Number(settlement.payable_amount).toLocaleString("zh-TW")}</span> 給總部後，回來按「我已匯款」。
        </div>
      )}
      {settlement.status === "remitted" && (
        <div className="rounded-md border border-indigo-300 bg-indigo-50 p-3 text-sm text-indigo-800 dark:border-indigo-800 dark:bg-indigo-950 dark:text-indigo-300">
          已回報匯款{settlement.remit_note ? `（備註：${settlement.remit_note}）` : ""}，等總部確認收款結案。
        </div>
      )}
      {settlement.status === "settled" && (
        <div className="rounded-md border border-emerald-300 bg-emerald-50 p-3 text-sm text-emerald-800 dark:border-emerald-950 dark:bg-emerald-950 dark:text-emerald-300">
          ✅ 本月對帳已結案，謝謝。
        </div>
      )}
      {isSent && (
        <p className="text-xs text-zinc-500">
          逐行核對：金額有問題的行按「有問題」並填原因；全部無誤直接按「同意畫押」。
        </p>
      )}

      <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">類型</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">收貨日</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">調撥單</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">商品</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">數量</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">單價</th>
              <th className="px-3 py-2 text-right text-xs font-medium uppercase tracking-wide text-zinc-500">小計</th>
              <th className="px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500">核對</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {sortedItems === null ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">載入中…</td></tr>
            ) : sortedItems.length === 0 ? (
              <tr><td colSpan={8} className="p-3 text-center text-zinc-500">無明細。</td></tr>
            ) : sortedItems.map((it) => {
              const tx = transfers.get(it.transfer_id);
              const sku = skus.get(it.sku_id);
              const isFree = it.description != null;
              const d = disputeByItem.get(it.transfer_item_id);
              const flagged = flags.has(it.transfer_item_id);
              return (
                <tr key={it.id} className={d?.status === "open" ? "bg-red-50 dark:bg-red-950/40" : flagged ? "bg-amber-50 dark:bg-amber-950/40" : ""}>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{ENTRY_TYPE_LABEL[it.entry_type] ?? it.entry_type}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{new Date(it.received_at).toLocaleDateString("zh-TW")}</td>
                  <td className="whitespace-nowrap px-3 py-2 font-mono text-xs">{tx?.transfer_no ?? `#${it.transfer_id}`}</td>
                  <td className="px-3 py-2 text-xs">
                    {it.description ? (
                      <span className="break-words">{it.description}</span>
                    ) : (
                      <>
                        <span className="font-mono text-zinc-500">{sku?.sku_code ?? "—"}</span>{" "}
                        <span>{sku?.product_name ?? "—"}</span>
                        {sku?.variant_name && <span className="ml-1 text-zinc-400">/ {sku.variant_name}</span>}
                      </>
                    )}
                    {d && (
                      <div className="mt-1 text-xs text-red-700 dark:text-red-400">
                        🗣 {d.reason}
                        {d.status === "resolved" && (
                          <span className="ml-1 text-emerald-700 dark:text-emerald-400">
                            （總部已處理{d.resolution_note ? `：${d.resolution_note}` : ""}）
                          </span>
                        )}
                      </div>
                    )}
                    {flagged && (
                      <input
                        value={flags.get(it.transfer_item_id) ?? ""}
                        onChange={(e) =>
                          setFlags((m) => new Map(m).set(it.transfer_item_id, e.target.value))
                        }
                        placeholder="請填原因（必填），例：實際金額應為 $280"
                        className="mt-1 w-full rounded-md border border-amber-400 bg-white px-2 py-1 text-xs dark:border-amber-700 dark:bg-zinc-800"
                      />
                    )}
                  </td>
                  <td className="px-3 py-2 text-right font-mono">{Number(it.qty_received).toLocaleString()}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right font-mono text-zinc-500">
                    {isFree ? "—" : `$${Number(it.unit_branch_price ?? 0).toFixed(2)}`}
                  </td>
                  <td className={`whitespace-nowrap px-3 py-2 text-right font-mono ${Number(it.branch_amount ?? 0) < 0 ? "text-amber-600" : ""}`}>
                    ${Number(it.branch_amount ?? 0).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                  </td>
                  <td className="px-3 py-2">
                    {isSent ? (
                      <SpinButton
                        onClick={() =>
                          setFlags((m) => {
                            const next = new Map(m);
                            if (next.has(it.transfer_item_id)) next.delete(it.transfer_item_id);
                            else next.set(it.transfer_item_id, "");
                            return next;
                          })
                        }
                        className={`whitespace-nowrap rounded-md px-2 py-1 text-xs ${
                          flagged
                            ? "bg-amber-500 font-medium text-white"
                            : "border border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                        }`}
                      >
                        {flagged ? "↩ 取消" : "有問題"}
                      </SpinButton>
                    ) : d?.status === "open" ? (
                      <span className="text-xs text-red-600 dark:text-red-400">爭議中</span>
                    ) : null}
                  </td>
                </tr>
              );
            })}
          </tbody>
          {items && items.length > 0 && (
            <tfoot className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <td colSpan={6} className="px-3 py-2 text-right text-xs text-zinc-500">合計</td>
                <td className="px-3 py-2 text-right font-mono font-medium text-rose-600">
                  ${total.toLocaleString("zh-TW", { maximumFractionDigits: 0 })}
                </td>
                <td></td>
              </tr>
            </tfoot>
          )}
        </table>
      </div>

      {err && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          <p className="font-mono text-xs">{err}</p>
        </div>
      )}

      {isSent && (
        <div className="flex flex-wrap items-center justify-end gap-2">
          {flaggedCount > 0 ? (
            <>
              {!allReasonsFilled && (
                <span className="text-xs text-amber-700 dark:text-amber-400">每筆有問題的行都要填原因</span>
              )}
              <SpinButton
                onClick={onSubmitDisputes}
                disabled={busy || !allReasonsFilled}
                className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {busy ? "送出中…" : `⚠️ 送出爭議（${flaggedCount} 筆）`}
              </SpinButton>
            </>
          ) : (
            <SpinButton
              onClick={onAgree}
              disabled={busy}
              className="rounded-md bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
            >
              {busy ? "送出中…" : "✅ 全部無誤，同意畫押"}
            </SpinButton>
          )}
        </div>
      )}

      {settlement.status === "confirmed" && (
        <div className="flex flex-wrap items-end justify-end gap-2">
          <label className="text-xs">
            <span className="mb-1 block text-zinc-500">匯款備註（選填，例：帳號後五碼）</span>
            <input
              value={remitNote}
              onChange={(e) => setRemitNote(e.target.value)}
              className="w-56 rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
          </label>
          <SpinButton
            onClick={onRemit}
            disabled={busy}
            className="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:opacity-50"
          >
            {busy ? "送出中…" : "💸 我已匯款"}
          </SpinButton>
        </div>
      )}
    </div>
  );
}
