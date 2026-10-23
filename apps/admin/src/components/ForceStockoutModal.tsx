"use client";

// 採購單「已到貨也能斷貨」確認視窗（20261022100000_po_force_stockout_after_received.sql）
//
// 流程：打開就叫 rpc_preview_force_stockout（只讀）→ 列出會取消誰、怎麼收尾、不動的、擋下原因、
//   回收貨待辦 → 手打商品代碼＋填原因（通知預設不勾）→ rpc_force_stockout_po_item →
//   顯示結果，並重抓一次待辦（抓不到就沿用預覽那份）。
// ⛔ 只有名單 po_force_stockout_operators 上的人叫得動（後端擋）；頁面另外用 rpc_can_force_stockout 決定要不要顯示按鈕。
// ⛔ 沒有復原鈕（老闆 10/22 定案）——所以預覽要把人數、件數、店家、團號講清楚，代碼打對才按得下去。
// 判斷與措辭都在 lib/forceStockout.ts（有 node --test），這裡只負責畫面與呼叫。

import { useEffect, useState, type ReactNode } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { PO_TERM_ZH } from "@/lib/poStatus";
import {
  FORCE_STOCKOUT_REASON_MAX,
  canSubmitForceStockout,
  fmtQty,
  normalizeSkuInput,
  paidOrderLines,
  previewStopLines,
  reasonProblem,
  resultLines,
  returnTodoLines,
  skuCodeMatches,
  summaryLines,
  untouchedLines,
  type ForceStockoutPreview,
  type ForceStockoutResult,
  type ReturnTodoRow,
} from "@/lib/forceStockout";

export type ForceStockoutTarget = {
  poItemId: number;
  poNo: string;
  label: string;
  skuCode: string;
  unit: string;
  qtyOrdered: number;
  qtyReceived: number;
};

/**
 * 由頁面在「要開的時候」才掛上去（關掉就卸下），所以每次打開都是全新的狀態。
 * 按完之後關視窗才重讀頁面（同 POStoreAddModal：重讀時整頁會切成「載入中」）。
 */
export function ForceStockoutModal({
  target,
  onClose,
  onDone,
}: {
  target: ForceStockoutTarget;
  onClose: () => void;
  onDone: () => unknown;
}) {
  const [preview, setPreview] = useState<ForceStockoutPreview | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const [skuInput, setSkuInput] = useState("");
  const [reason, setReason] = useState("");
  const [notify, setNotify] = useState(false); // 老闆 10/22：預設不勾
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<ForceStockoutResult | null>(null);
  const [todoAfter, setTodoAfter] = useState<ReturnTodoRow[] | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase().rpc("rpc_preview_force_stockout", {
        p_po_item_id: target.poItemId,
      });
      if (cancelled) return;
      if (err) {
        setLoadErr(err.message);
        return;
      }
      setPreview(data as ForceStockoutPreview);
    })().catch((e: unknown) => {
      if (!cancelled) setLoadErr(e instanceof Error ? e.message : String(e));
    });
    return () => {
      cancelled = true;
    };
  }, [target.poItemId]);

  const canSubmit = !busy && !result && canSubmitForceStockout(preview, skuInput, reason);

  async function submit() {
    if (!preview || !canSubmitForceStockout(preview, skuInput, reason)) return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data, error: rpcErr } = await sb.rpc("rpc_force_stockout_po_item", {
        p_po_item_id: target.poItemId,
        p_sku_code_confirm: normalizeSkuInput(skuInput),
        p_notify: notify,
        p_reason: reason.trim(),
      });
      if (rpcErr) throw new Error(rpcErr.message);
      setResult((data ?? {}) as ForceStockoutResult);
      // 待辦重抓一次（派車／收貨狀態可能剛好變了）；抓不到就沿用預覽那份，不影響結果
      try {
        const { data: again, error: againErr } = await sb.rpc("rpc_preview_force_stockout", {
          p_po_item_id: target.poItemId,
        });
        if (!againErr && again) setTodoAfter(((again as ForceStockoutPreview).return_todo ?? null) as ReturnTodoRow[] | null);
      } catch {
        /* 沿用預覽那份 */
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function close() {
    onClose();
    if (result) await onDone();
  }

  const stop = preview ? previewStopLines(preview) : [];
  const s = preview?.summary;
  const reasonMsg = reason.trim() === "" ? null : reasonProblem(reason);
  const codeTyped = skuInput.trim() !== "";
  const codeOk = skuCodeMatches(skuInput, preview?.sku_code);

  return (
    <Modal open onClose={busy ? () => {} : close} title={`已到貨也能斷貨 · ${target.label}`} maxWidth="max-w-2xl">
      <div className="space-y-4 text-sm">
        <p className="text-xs text-zinc-500">
          {PO_TERM_ZH} {target.poNo} · {target.skuCode} · 已收 {fmtQty(target.qtyReceived)}／訂購 {fmtQty(target.qtyOrdered)}{" "}
          {target.unit}
        </p>

        <div className="rounded-md border border-rose-300 bg-rose-50 px-3 py-2 text-xs leading-5 text-rose-900 dark:border-rose-800 dark:bg-rose-950 dark:text-rose-200">
          <div className="font-semibold">⚠ 按下去會把下面這些團裡、這個商品、還沒取貨的客人一次取消，沒有復原鈕。</div>
          <div>・部分好貨、部分壞貨的情況不要用（會全部取消）。</div>
          <div>・採購單還在收貨中時，還沒收滿的那一列請用原本的「⛔ 斷貨」（這顆不會出現）；採購單已經全部到貨或結案，就算那一列沒收滿也會出現這顆，按了一樣取消全部還沒取貨的客人。</div>
          <div>・按之前請確認沒有人正在處理這一團的請購／採購，也避開店家正在收貨、刪改這些訂單的時間；萬一系統說有人在操作，等一下再按就好，什麼都不會改。</div>
          <div>・{PO_TERM_ZH}那一項不會標斷貨；實體貨照退貨流程收回（下面有待辦）。</div>
        </div>

        {loadErr ? (
          <div className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-rose-700 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
            讀不到預覽：{loadErr}
          </div>
        ) : !preview ? (
          <div className="text-zinc-500">讀取中…</div>
        ) : (
          <>
            {stop.length > 0 ? (
              <div className="rounded-md border border-rose-300 bg-rose-50 px-3 py-2 text-rose-700 dark:border-rose-800 dark:bg-rose-950 dark:text-rose-300">
                {!result && preview.block_reasons.length > 0 ? (
                  <div className="mb-1 font-semibold">不能按：</div>
                ) : null}
                {stop.map((line, i) => (
                  <div key={i}>・{line}</div>
                ))}
              </div>
            ) : null}

            {/* 涵蓋的團：範圍＝那張請購單連到的所有團（機制索引「連帶二」），要讓人核對 */}
            {(preview.campaigns ?? []).length > 0 ? (
              <Section title={`涵蓋的團（${(preview.campaigns ?? []).length} 個：這一項的請購單連到的團）`}>
                <ul className="space-y-0.5">
                  {(preview.campaigns ?? []).map((c) => {
                    const hit = s?.by_campaign.find((b) => Number(b.campaign_id) === Number(c.id));
                    return (
                      <li key={c.id} className="flex flex-wrap gap-x-2">
                        <span className="font-mono text-xs">{c.campaign_no ?? "?"}</span>
                        <span className="min-w-0">{c.name ?? ""}</span>
                        <span className="text-zinc-500">
                          {hit ? `取消 ${fmtQty(hit.items)} 筆／${fmtQty(hit.qty)} 件` : "沒有這個商品要取消"}
                        </span>
                      </li>
                    );
                  })}
                </ul>
              </Section>
            ) : null}

            {!result && s && Number(s.items) > 0 ? (
              <Section title="會發生什麼">
                {summaryLines(s).map((line, i) => (
                  <div key={i}>{line}</div>
                ))}
                <div className="mt-2 overflow-x-auto">
                  <table className="w-full min-w-[320px] text-xs">
                    <thead>
                      <tr className="text-left text-zinc-500">
                        <th className="py-1 pr-2 font-medium">店</th>
                        <th className="py-1 pr-2 text-right font-medium">客人</th>
                        <th className="py-1 pr-2 text-right font-medium">單</th>
                        <th className="py-1 pr-2 text-right font-medium">筆</th>
                        <th className="py-1 text-right font-medium">件</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
                      {s.by_store.map((r) => (
                        <tr key={r.store_id}>
                          <td className="py-1 pr-2">{r.store_name}</td>
                          <td className="py-1 pr-2 text-right">{fmtQty(r.members)}</td>
                          <td className="py-1 pr-2 text-right">{fmtQty(r.orders)}</td>
                          <td className="py-1 pr-2 text-right">{fmtQty(r.items)}</td>
                          <td className="py-1 text-right">{fmtQty(r.qty)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </Section>
            ) : null}

            {s && s.paid_orders.length > 0 ? (
              <Section title={`付過錢或用過儲值金的單（${s.paid_orders.length} 張，要人工確認退款）`}>
                {paidOrderLines(s.paid_orders).map((line, i) => (
                  <div key={i}>・{line}</div>
                ))}
              </Section>
            ) : null}

            {untouchedLines(preview).length > 0 ? (
              <Section title="不會動到的">
                {untouchedLines(preview).map((line, i) => (
                  <div key={i}>・{line}</div>
                ))}
              </Section>
            ) : null}

            <Section title="回收貨的待辦（照現在的退貨流程，系統不會代替）">
              {returnTodoLines(result ? (todoAfter ?? preview.return_todo) : preview.return_todo).map((line, i) => (
                <div key={i}>・{line}</div>
              ))}
            </Section>

            {result ? (
              <div className="rounded-md border border-emerald-300 bg-emerald-50 px-3 py-2 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950 dark:text-emerald-200">
                <div className="font-semibold">{result.nothing_to_do ? "沒有改任何東西" : "✅ 完成"}</div>
                {resultLines(result).map((line, i) => (
                  <div key={i}>{line}</div>
                ))}
                {paidOrderLines(result.paid_orders).length > 0 ? (
                  <div className="mt-1">
                    要人工確認退款：
                    {paidOrderLines(result.paid_orders).map((line, i) => (
                      <div key={i}>・{line}</div>
                    ))}
                  </div>
                ) : null}
              </div>
            ) : preview.can_execute ? (
              <div className="space-y-3 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
                <label className="block">
                  <span className="mb-1 block text-xs font-medium text-zinc-500">
                    確認：請輸入商品代碼 <span className="font-mono text-zinc-700 dark:text-zinc-300">{preview.sku_code}</span>
                    （前後空白不算，其他一字不差、大小寫要一樣，才按得下去）
                  </span>
                  <input
                    type="text"
                    autoComplete="off"
                    spellCheck={false}
                    disabled={busy}
                    value={skuInput}
                    onChange={(e) => setSkuInput(e.target.value)}
                    className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono dark:border-zinc-700 dark:bg-zinc-900"
                  />
                  {codeTyped && !codeOk ? (
                    <span className="mt-0.5 block text-xs text-rose-600 dark:text-rose-400">代碼不一樣（大小寫也要一樣）</span>
                  ) : null}
                </label>
                <label className="block">
                  <span className="mb-1 block text-xs font-medium text-zinc-500">
                    原因（必填，會寫進每一筆的編輯歷史；{FORCE_STOCKOUT_REASON_MAX} 字以內）
                  </span>
                  <textarea
                    rows={2}
                    disabled={busy}
                    value={reason}
                    onChange={(e) => setReason(e.target.value)}
                    placeholder="例：叫錯款式，廠商沒有正確款"
                    className="w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-900"
                  />
                  {reasonMsg ? <span className="mt-0.5 block text-xs text-rose-600 dark:text-rose-400">{reasonMsg}</span> : null}
                </label>
                <label className="flex items-start gap-2">
                  <input
                    type="checkbox"
                    className="mt-1"
                    disabled={busy}
                    checked={notify}
                    onChange={(e) => setNotify(e.target.checked)}
                  />
                  <span>
                    同時在會員通知中心發「商品斷貨通知」（一位會員一則、不推 LINE；沒綁會員的單發不了）
                  </span>
                </label>
              </div>
            ) : null}
          </>
        )}

        {error ? (
          <div className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-rose-700 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-300">
            <div>{error}</div>
            <div className="mt-1 text-xs">
              如果是連線中斷：不確定有沒有執行。請重新整理頁面、再打開這個視窗看預覽——寫「已經做過了」就代表已經取消好了。
            </div>
          </div>
        ) : null}

        <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
          <button
            type="button"
            onClick={close}
            disabled={busy}
            className="min-h-[44px] rounded-md border border-zinc-300 px-3 py-2 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            {result ? "關閉" : "取消"}
          </button>
          {!result ? (
            <SpinButton
              onClick={submit}
              disabled={!canSubmit}
              loading={busy}
              className="min-h-[44px] rounded-md bg-rose-600 px-4 py-2 font-medium text-white hover:bg-rose-500 disabled:opacity-50"
            >
              確定取消
            </SpinButton>
          ) : null}
        </div>
      </div>
    </Modal>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div>
      <div className="mb-1 text-xs font-medium text-zinc-500">{title}</div>
      <div className="space-y-0.5">{children}</div>
    </div>
  );
}
