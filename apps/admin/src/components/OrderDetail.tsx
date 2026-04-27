"use client";

import { Fragment, useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { OrderTransferModal } from "@/components/OrderTransferModal";

type OrderHead = {
  id: number;
  order_no: string;
  status: string;
  pickup_deadline: string | null;
  nickname_snapshot: string | null;
  created_at: string;
  updated_at: string;
  pickup_store_id: number | null;
  campaign_id: number | null;
  transferred_from_order_id: number | null;
  is_air_transfer: boolean | null;
  member: { id: number; name: string | null; phone: string | null; member_no: string } | null;
  campaign: { id: number; campaign_no: string; name: string } | null;
  store: { id: number; name: string } | null;
};

type ItemRow = {
  id: number;
  qty: number;
  unit_price: number;
  status: string;
  source: string;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
  sku: { id: number; sku_code: string; product_name: string | null; variant_name: string | null } | null;
};

type TimelineStep = {
  label: string;
  ts: string | null;
  done: boolean;
  detail?: string;
  detailHref?: string;
  detailOnClick?: () => void;
};

function staffLabel(uid: string | null, names: Map<string, string>): string {
  if (!uid) return "—";
  return names.get(uid) ?? uid.slice(0, 8);
}

function fmtDt(iso: string): string {
  return new Date(iso).toLocaleString("zh-TW", { hour12: false });
}

export function OrderDetail({
  orderId,
  onNavigate,
}: {
  orderId: number;
  onNavigate?: (orderId: number, orderNo: string) => void;
}) {
  const [head, setHead] = useState<OrderHead | null>(null);
  const [items, setItems] = useState<ItemRow[] | null>(null);
  const [timeline, setTimeline] = useState<TimelineStep[] | null>(null);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const [transferOpen, setTransferOpen] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const [hRes, iRes] = await Promise.all([
        sb.from("customer_orders")
          .select("id, order_no, status, pickup_deadline, nickname_snapshot, created_at, updated_at, pickup_store_id, campaign_id, transferred_from_order_id, is_air_transfer, member:members(id, name, phone, member_no), campaign:group_buy_campaigns(id, campaign_no, name), store:stores!customer_orders_pickup_store_id_fkey(id, name)")
          .eq("id", orderId).maybeSingle(),
        sb.from("customer_order_items")
          .select("id, qty, unit_price, status, source, created_at, updated_at, created_by, updated_by, sku:skus(id, sku_code, product_name, variant_name)")
          .eq("order_id", orderId)
          .order("created_at", { ascending: true }),
      ]);
      if (cancelled) return;
      if (hRes.error) { setError(hRes.error.message); return; }
      const headData = hRes.data as unknown as OrderHead;
      setHead(headData);
      if (iRes.error) { setError(iRes.error.message); return; }
      const itemsData = (iRes.data ?? []) as unknown as ItemRow[];
      setItems(itemsData);

      // ========== 載入加單者 user names ==========
      const uids = new Set<string>();
      for (const it of itemsData) {
        if (it.created_by) uids.add(it.created_by);
        if (it.updated_by) uids.add(it.updated_by);
      }
      if (uids.size > 0) {
        const { data: names } = await sb.rpc("rpc_get_staff_names", {
          p_uids: Array.from(uids),
        });
        const m = new Map<string, string>();
        for (const n of (names as { id: string; display_name: string }[] | null) ?? []) {
          m.set(n.id, n.display_name);
        }
        if (!cancelled) setStaffNames(m);
      }

      // ========== 載入 timeline ==========
      const skuIds = itemsData.map((it) => it.sku?.id).filter((x): x is number => !!x);
      const tl = await buildTimeline(headData, skuIds, onNavigate);
      if (!cancelled) setTimeline(tl);
    })();
    return () => { cancelled = true; };
  }, [orderId, reloadTick]);

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }
  if (!head || !items) return <div className="text-sm text-zinc-500">載入中…</div>;

  const totalQty = items.reduce((s, i) => s + Number(i.qty), 0);
  const totalAmount = items.reduce((s, i) => s + Number(i.qty) * Number(i.unit_price), 0);

  const canTransfer = ["pending", "confirmed", "reserved"].includes(head.status);
  const isTransferredOut = head.status === "transferred_out";
  const memberLabel = head.member
    ? `${head.member.name ?? "—"} (${head.member.member_no})`
    : `(${head.nickname_snapshot ?? "—"})`;

  return (
    <div className="space-y-4 text-sm">
      {(canTransfer || isTransferredOut) && (
        <div className="flex items-center justify-end gap-2">
          {canTransfer && (
            <button
              onClick={() => setTransferOpen(true)}
              className="rounded-md border border-blue-300 px-3 py-1 text-xs font-medium text-blue-700 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-300 dark:hover:bg-blue-950"
              title="客人棄單 / 轉到其他店店長 / 互助接手"
            >
              ↗ 轉出此訂單
            </button>
          )}
          {isTransferredOut && (
            <span className="text-xs text-zinc-500">⚠️ 此訂單已轉出</span>
          )}
        </div>
      )}

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Field label="訂單號" value={<span className="font-mono">{head.order_no}</span>} />
        <Field label="狀態" value={head.status} />
        <Field label="取貨截止" value={head.pickup_deadline ?? "—"} />
        <Field
          label="會員"
          value={
            head.member ? (
              <span>
                {head.member.name ?? "—"}{" "}
                <span className="font-mono text-xs text-zinc-500">{head.member.member_no}</span>
                <br />
                <span className="font-mono text-xs text-zinc-500">{head.member.phone ?? "—"}</span>
              </span>
            ) : (
              <span className="text-zinc-500">({head.nickname_snapshot ?? "—"})</span>
            )
          }
        />
        <Field label="開團" value={head.campaign ? `${head.campaign.campaign_no} ${head.campaign.name}` : "—"} />
        <Field label="取貨店" value={head.store?.name ?? "—"} />
        <Field label="建立" value={fmtDt(head.created_at)} />
        <Field label="最後更新" value={fmtDt(head.updated_at)} />
      </div>

      {/* 進度 timeline（採購到貨 → 撿貨 → 派貨 → 分店收貨） */}
      <Timeline steps={timeline} />

      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <div className="flex items-center justify-between border-b border-zinc-200 bg-zinc-50 px-3 py-2 text-xs font-medium dark:border-zinc-800 dark:bg-zinc-900">
          <span>明細（{items.length} 項 · {totalQty} 件 · ${totalAmount}）</span>
        </div>
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-zinc-200 text-xs dark:divide-zinc-800">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">商品</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">數量</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">單價</th>
                <th className="px-3 py-2 text-right font-medium text-zinc-500">小計</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">第一次加</th>
                <th className="px-3 py-2 text-left font-medium text-zinc-500">最後更新</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
              {items.length === 0 ? (
                <tr><td colSpan={6} className="p-4 text-center text-zinc-500">尚無明細</td></tr>
              ) : items.map((it) => {
                const sub = Number(it.qty) * Number(it.unit_price);
                return (
                  <tr key={it.id}>
                    <td className="px-3 py-2">
                      {it.sku ? (
                        <span>
                          {it.sku.product_name ?? "—"}
                          {it.sku.variant_name && <span className="text-zinc-500"> / {it.sku.variant_name}</span>}
                          <span className="ml-1 font-mono text-zinc-400">{it.sku.sku_code}</span>
                        </span>
                      ) : "—"}
                    </td>
                    <td className="px-3 py-2 text-right font-mono">{Number(it.qty)}</td>
                    <td className="px-3 py-2 text-right font-mono text-zinc-500">${Number(it.unit_price)}</td>
                    <td className="px-3 py-2 text-right font-mono">${sub}</td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.created_at)}<br />
                      <span className="text-[10px]">by {staffLabel(it.created_by, staffNames)}</span>
                    </td>
                    <td className="px-3 py-2 text-zinc-500">
                      {fmtDt(it.updated_at)}<br />
                      <span className="text-[10px]">by {staffLabel(it.updated_by, staffNames)}</span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
        <p className="border-t border-zinc-200 bg-zinc-50 px-3 py-1.5 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
          ※ 同顧客在同活動連 key 多次會合併到同一筆，舊 qty 被新值覆寫。如需「每次 +N 紀錄」請告知改完整版（加 append-only audit table）。
        </p>
      </div>

      <OrderTransferModal
        open={transferOpen}
        onClose={() => setTransferOpen(false)}
        orderId={head.id}
        orderNo={head.order_no}
        currentPickupStoreId={head.pickup_store_id}
        currentMemberLabel={memberLabel}
        onSubmitted={(newId) => {
          setTransferOpen(false);
          alert(`訂單已轉出 → 新訂單 #${newId}`);
          setReloadTick((n) => n + 1);
        }}
      />
    </div>
  );
}

async function buildTimeline(
  head: OrderHead,
  skuIds: number[],
  onNavigate?: (orderId: number, orderNo: string) => void,
): Promise<TimelineStep[]> {
  const sb = getSupabase();

  // transferred_out: 訂單已關閉、流程不再進行；只顯示一個結束 step
  if (head.status === "transferred_out") {
    // 找新訂單號做 detail link（從 customer_orders 用 transferred_to_order_id）
    let newOrderInfo = "已轉出（流程關閉、不入金額統計）";
    let newOrderHref: string | undefined;
    let newOrderClick: (() => void) | undefined;
    const { data: self } = await sb
      .from("customer_orders")
      .select("transferred_to_order_id")
      .eq("id", head.id)
      .maybeSingle();
    const newId = (self as { transferred_to_order_id: number | null } | null)?.transferred_to_order_id;
    if (newId) {
      const { data: newOrd } = await sb
        .from("customer_orders")
        .select("order_no")
        .eq("id", newId)
        .maybeSingle();
      const newNo = (newOrd as { order_no: string } | null)?.order_no;
      if (newNo) {
        newOrderInfo = `已轉出 → 新訂單 ${newNo}`;
        if (onNavigate) {
          newOrderClick = () => onNavigate(newId, newNo);
        } else {
          newOrderHref = `/orders?id=${newId}`;
        }
      }
    }
    return [
      {
        label: "訂單關閉（已轉出）",
        ts: head.updated_at,
        done: true,
        detail: newOrderInfo,
        detailHref: newOrderHref,
        detailOnClick: newOrderClick,
      },
    ];
  }

  // transferred-in: 從別張訂單轉進來（5b-1 整單轉 / 5c partial 拆單）
  // 不走採購／撿貨／派貨流程，改顯示「轉出店 → 運送中 → 分店收貨 → 顧客取貨」
  if (head.transferred_from_order_id) {
    const { data: src } = await sb
      .from("customer_orders")
      .select("id, order_no, pickup_store_id, store:stores!customer_orders_pickup_store_id_fkey(name)")
      .eq("id", head.transferred_from_order_id)
      .maybeSingle();
    type SrcRow = { id: number; order_no: string; pickup_store_id: number | null; store: { name: string } | { name: string }[] | null };
    const s = src as unknown as SrcRow | null;
    const srcStoreName = s?.store
      ? (Array.isArray(s.store) ? s.store[0]?.name : s.store.name) ?? "—"
      : "—";
    const srcDetail = s ? `來源：${srcStoreName} 訂單 ${s.order_no}` : `來源訂單 #${head.transferred_from_order_id}`;
    const srcHref = s ? `/orders?id=${s.id}` : undefined;
    const srcClick = (s && onNavigate) ? () => onNavigate(s.id, s.order_no) : undefined;

    // Status → step done 的 rank：每步驟有「需 status >= X 才 done」的閾值
    const TRANSFER_RANK: Record<string, number> = {
      pending: 0, confirmed: 1, reserved: 2, shipping: 3,
      ready: 4, partially_ready: 4,
      partially_completed: 5, completed: 5,
      expired: -1, cancelled: -1, transferred_out: -1,
    };
    const rank = TRANSFER_RANK[head.status] ?? 0;

    const sourceStep: TimelineStep = {
      label: "轉出店",
      ts: head.created_at,
      done: true,
      detail: srcDetail,
      detailHref: onNavigate ? undefined : srcHref,
      detailOnClick: srcClick,
    };
    const customerStep: TimelineStep = {
      label: "顧客取貨",
      ts: null,
      done: rank >= 5,
      detail: rank >= 5 ? "已完成" : `當前：${head.status}`,
    };

    if (head.is_air_transfer) {
      // 空中轉：店對店直送
      return [
        sourceStep,
        {
          label: "分店收貨",
          ts: null,
          done: rank >= 4,
          detail: rank >= 4 ? "（分店已可取貨）" : "（空中轉、暫無系統紀錄）",
        },
        customerStep,
      ];
    }
    // 非空中轉：經總倉
    return [
      sourceStep,
      {
        label: "總倉收到",
        ts: null,
        done: rank >= 1,
        detail: rank >= 1 ? "（訂單已確認）" : "（待確認→已確認後標記）",
      },
      {
        label: "運送中",
        ts: null,
        done: rank >= 3,
        detail: rank >= 3 ? "（總倉已出貨）" : "（總倉出貨）",
      },
      {
        label: "分店收貨",
        ts: null,
        done: rank >= 4,
        detail: rank >= 4 ? "（分店已可取貨）" : "（暫無系統紀錄）",
      },
      customerStep,
    ];
  }

  const campaignId = head.campaign_id;
  const storeId = head.pickup_store_id;
  const status = head.status;

  // Step 1: 採購到貨 — campaign 對應的 POs 是否都 fully_received
  let poDone = false;
  let poTs: string | null = null;
  let poDetail = "";
  // 只看這張訂單裡實際 SKU 對應的 PO（過濾掉同 campaign 但其它 SKU 用到的 PO）
  if (campaignId && skuIds.length > 0) {
    const { data: pris } = await sb
      .from("purchase_request_items")
      .select("po_item_id")
      .eq("source_campaign_id", campaignId)
      .in("sku_id", skuIds)
      .not("po_item_id", "is", null);
    const poItemIds = ((pris as { po_item_id: number | null }[] | null) ?? [])
      .map((r) => r.po_item_id)
      .filter((x): x is number => x !== null);
    if (poItemIds.length > 0) {
      const { data: pois } = await sb
        .from("purchase_order_items")
        .select("po_id")
        .in("id", poItemIds);
      const poIds = Array.from(
        new Set(((pois as { po_id: number }[] | null) ?? []).map((r) => r.po_id)),
      );
      if (poIds.length > 0) {
        const { data: pos } = await sb
          .from("purchase_orders")
          .select("id, status, updated_at")
          .in("id", poIds);
        const poList = ((pos as { id: number; status: string; updated_at: string }[] | null) ?? []);
        const allDone = poList.length > 0 && poList.every((p) => p.status === "fully_received" || p.status === "closed");
        if (allDone) {
          poDone = true;
          poTs = poList
            .map((p) => p.updated_at)
            .sort()
            .reverse()[0] ?? null;
        }
        poDetail = `${poList.filter((p) => p.status === "fully_received" || p.status === "closed").length}/${poList.length} PO`;
      }
    }
  }

  // Step 2/3/4: wave → transfer
  let wavePicked = false;
  let waveTs: string | null = null;
  let waveDetail = "";
  let waveHref: string | undefined;
  let xferShipped = false;
  let shippedTs: string | null = null;
  let xferReceived = false;
  let receivedTs: string | null = null;
  let xferDetail = "";
  let xferHref: string | undefined;

  if (campaignId && storeId && skuIds.length > 0) {
    // 找此 order 對應的 wave_ids（同 campaign + 同店 + 同 sku）
    const { data: pwis } = await sb
      .from("picking_wave_items")
      .select("wave_id")
      .eq("campaign_id", campaignId)
      .eq("store_id", storeId)
      .in("sku_id", skuIds);
    const waveIds = Array.from(
      new Set(((pwis as { wave_id: number }[] | null) ?? []).map((r) => r.wave_id)),
    );

    if (waveIds.length > 0) {
      // wave 狀態
      const { data: ws } = await sb
        .from("picking_waves")
        .select("id, wave_code, status, updated_at")
        .in("id", waveIds);
      const waves = ((ws as { id: number; wave_code: string; status: string; updated_at: string }[] | null) ?? []);
      const allPicked = waves.length > 0 && waves.every((w) => ["picked", "shipped", "cancelled"].includes(w.status));
      if (allPicked) {
        wavePicked = true;
        waveTs = waves
          .map((w) => w.updated_at)
          .sort()
          .reverse()[0] ?? null;
      }
      if (waves.length === 1) {
        waveDetail = waves[0].wave_code;
        waveHref = `/picking/history?wave=${waves[0].id}`;
      } else if (waves.length > 1) {
        waveDetail = `${waves.length} 張撿貨單`;
        waveHref = `/picking/history`;
      }

      // transfer for each wave to this store
      const transferNos = waveIds.map((wid) => `WAVE-${wid}-S${storeId}`);
      const { data: ts } = await sb
        .from("transfers")
        .select("transfer_no, status, shipped_at, received_at")
        .in("transfer_no", transferNos);
      const xfers = ((ts as { transfer_no: string; status: string; shipped_at: string | null; received_at: string | null }[] | null) ?? []);
      if (xfers.length === 1) {
        xferDetail = xfers[0].transfer_no;
        xferHref = `/transfers/`;
      } else if (xfers.length > 1) {
        xferDetail = `${xfers.length} 張 TR`;
        xferHref = `/transfers/`;
      }
      if (xfers.length > 0) {
        const allShipped = xfers.every((t) => ["shipped", "received", "closed"].includes(t.status));
        if (allShipped) {
          xferShipped = true;
          shippedTs = xfers
            .map((t) => t.shipped_at)
            .filter((x): x is string => !!x)
            .sort()
            .reverse()[0] ?? null;
        }
        const allReceived = xfers.every((t) => ["received", "closed"].includes(t.status));
        if (allReceived) {
          xferReceived = true;
          receivedTs = xfers
            .map((t) => t.received_at)
            .filter((x): x is string => !!x)
            .sort()
            .reverse()[0] ?? null;
        }
      }
    }
  }

  // Step 5: 顧客取貨 — order.status
  const pickedUp = status === "completed" || status === "picked_up";

  return [
    { label: "採購到貨", ts: poTs, done: poDone, detail: poDetail || undefined },
    { label: "撿貨完成", ts: waveTs, done: wavePicked, detail: waveDetail || undefined, detailHref: waveHref },
    { label: "派貨出倉", ts: shippedTs, done: xferShipped, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "分店收貨", ts: receivedTs, done: xferReceived, detail: xferDetail || undefined, detailHref: xferHref },
    { label: "顧客取貨", ts: null, done: pickedUp, detail: status },
  ];
}

function Timeline({ steps }: { steps: TimelineStep[] | null }) {
  if (steps === null) {
    return (
      <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
        進度載入中…
      </div>
    );
  }
  return (
    <div className="rounded-md border border-zinc-200 bg-zinc-50 p-3 dark:border-zinc-800 dark:bg-zinc-900">
      <div className="mb-2 text-xs font-medium text-zinc-500">進度</div>
      <ol className="flex items-start gap-1 overflow-x-auto text-xs">
        {steps.map((s, i) => (
          <Fragment key={s.label}>
            <li className="flex min-w-0 flex-col items-center text-center">
              <span
                className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold ${
                  s.done
                    ? "bg-emerald-600 text-white"
                    : "bg-zinc-300 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300"
                }`}
              >
                {s.done ? "✓" : i + 1}
              </span>
              <div className={`mt-1 text-[11px] ${s.done ? "font-medium" : "text-zinc-500"}`}>
                {s.label}
              </div>
              {s.detail && (
                s.detailOnClick ? (
                  <button
                    type="button"
                    onClick={s.detailOnClick}
                    className="text-[10px] font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {s.detail}
                  </button>
                ) : s.detailHref ? (
                  <a
                    href={s.detailHref}
                    className="text-[10px] font-mono text-blue-600 hover:underline dark:text-blue-400"
                  >
                    {s.detail}
                  </a>
                ) : (
                  <div className="text-[10px] text-zinc-500">{s.detail}</div>
                )
              )}
              {s.ts && (
                <div className="text-[10px] text-zinc-400">
                  {new Date(s.ts).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                </div>
              )}
            </li>
            {i < steps.length - 1 && (
              <li
                aria-hidden
                className={`mt-3 h-[2px] flex-1 ${
                  steps[i + 1].done ? "bg-emerald-400" : "bg-zinc-300 dark:bg-zinc-700"
                }`}
              />
            )}
          </Fragment>
        ))}
      </ol>
    </div>
  );
}

function Field({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div>
      <div className="text-xs text-zinc-500">{label}</div>
      <div>{value}</div>
    </div>
  );
}
