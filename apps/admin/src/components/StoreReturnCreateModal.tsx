"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";

// 店家退貨頁「＋ 我要退貨」彈窗。
//
// ⭐ 老闆 2026-09-04 裁示 2（乙案）：送出的那一刻**一筆庫存都不動** ——
//   帳上還是原本的數字，旁邊標「退貨中 N」；總倉按「同意收回」那一刻才真的扣。
//   後端是 rpc_create_store_return（20260904020000），前端不做任何庫存動作。
//
// ⛔ 這一支跟 OrderReturnCreateModal（內部調撥頁那顆橘色鈕）是**兩條不同的路**，
//   不要合併：那一支必須先挑一張客人訂單、建單當下就扣庫存、而且會把客人訂單收尾
//   （20260801000000:279-330）。本頁不綁訂單，所以那些事一件都不會發生。

/** 老闆 2026-09-04 逐字定的四個原因。⛔ 後端 rpc_create_store_return 也有同一份白名單，要改兩邊一起改。 */
const REASONS = ["少收", "破損", "過期", "客人退"] as const;
type Reason = (typeof REASONS)[number];

const REASON_HINT: Record<Reason, string> = {
  少收: "這批貨總倉派了、但店裡沒收到那麼多。",
  破損: "貨到店裡就是壞的、或在店裡壞掉了。",
  過期: "效期到了賣不掉，要退回總倉。",
  客人退: "客人買了又拿回來還。",
};

type SkuHit = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

type PickedLine = SkuHit & {
  qty: number;
  onHand: number;   // 店裡帳上有幾件
  pending: number;  // 已經送出、還在等總倉回覆的件數
};

function skuLabel(s: SkuHit): string {
  return `${s.product_name ?? ""}${s.variant_name ? ` / ${s.variant_name}` : ""}`.trim() || `#${s.id}`;
}

export default function StoreReturnCreateModal({
  open,
  onClose,
  onCreated,
  storeId,
  storeName,
  storeLocationId,
}: {
  open: boolean;
  onClose: () => void;
  onCreated: (transferId: number) => void;
  storeId: number;
  storeName: string;
  storeLocationId: number;
}) {
  const [search, setSearch] = useState("");
  const [hits, setHits] = useState<SkuHit[]>([]);
  const [searching, setSearching] = useState(false);
  const [lines, setLines] = useState<PickedLine[]>([]);
  const [reason, setReason] = useState<Reason | "">("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // ⭐ 關掉要整個清空（不然下次打開會帶著上一次沒送出的東西，很容易送錯）——
  //   做法是**由呼叫端在關閉時整個 unmount 這支元件**（wms/returns/page.tsx 用
  //   `{showCreate && <StoreReturnCreateModal .../>}`），state 自然歸零。
  //   ⛔ 不要改成「在 useEffect 裡逐一 setXxx 清掉」：那是多寫一段會壞掉的程式碼，
  //     而且會踩 react-hooks/set-state-in-effect。

  // 商品搜尋（編號 / 品名 / 規格），debounce 300ms —— 寫法沿用 AddStockModal:65-89
  useEffect(() => {
    const q = search.replace(/[,()%*]/g, " ").trim();
    if (!open || !q) {
      setHits([]);
      return;
    }
    let cancelled = false;
    setSearching(true);
    const t = setTimeout(async () => {
      const { data } = await getSupabase()
        .from("skus")
        .select("id, sku_code, product_name, variant_name")
        .or(`sku_code.ilike.%${q}%,product_name.ilike.%${q}%,variant_name.ilike.%${q}%`)
        .order("id", { ascending: false })
        .limit(20);
      if (!cancelled) {
        setHits((data as SkuHit[]) ?? []);
        setSearching(false);
      }
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [search, open]);

  async function pick(s: SkuHit) {
    setError(null);
    if (lines.some((l) => l.id === s.id)) {
      setSearch("");
      setHits([]);
      return;
    }
    const sb = getSupabase();
    // 在庫與「已經在等總倉回覆」的件數 —— 兩個數字都要，因為可退上限 = 在庫 − 退貨中。
    // v_store_pending_returns 是 20260904020000 建的 view（母體定義寫在那支檔頭）。
    const [{ data: bal }, { data: pend }] = await Promise.all([
      sb
        .from("stock_balances")
        .select("on_hand")
        .eq("location_id", storeLocationId)
        .eq("sku_id", s.id)
        .maybeSingle(),
      sb
        .from("v_store_pending_returns")
        .select("pending_qty")
        .eq("location_id", storeLocationId)
        .eq("sku_id", s.id)
        .maybeSingle(),
    ]);
    const onHand = Number((bal as { on_hand: number } | null)?.on_hand ?? 0);
    const pending = Number((pend as { pending_qty: number } | null)?.pending_qty ?? 0);
    const room = Math.max(onHand - pending, 0);
    if (room <= 0) {
      setError(
        `「${skuLabel(s)}」現在退不了：店裡帳上有 ${onHand} 件，` +
          `其中 ${pending} 件已經送出在等總倉回覆了。`,
      );
      return;
    }
    setLines((prev) => [...prev, { ...s, qty: 1, onHand, pending }]);
    setSearch("");
    setHits([]);
  }

  function setQty(skuId: number, raw: string) {
    const v = Math.floor(Number(raw));
    setLines((prev) =>
      prev.map((l) =>
        l.id === skuId
          ? { ...l, qty: Number.isFinite(v) ? Math.max(0, Math.min(v, Math.max(l.onHand - l.pending, 0))) : 0 }
          : l,
      ),
    );
  }

  const totalQty = useMemo(() => lines.reduce((a, l) => a + l.qty, 0), [lines]);
  const canSubmit = !busy && reason !== "" && lines.length > 0 && lines.every((l) => l.qty > 0);

  async function submit() {
    // canSubmit 裡已經有 reason !== ""，TypeScript 會沿著它把型別收斂掉，
    // 這裡再寫一次 reason === "" 會被判成永遠不成立的比較（TS2367）。
    if (!canSubmit) return;
    const summary = lines.map((l) => `　・${skuLabel(l)} × ${l.qty}`).join("\n");
    if (
      !confirm(
        `送出退貨給總倉？\n\n店家：${storeName}\n原因：${reason}\n${summary}\n\n` +
          `送出後庫存不會馬上扣 —— 帳上的數字不變，只是旁邊會標「退貨中」。\n` +
          `總倉按「同意收回」的那一刻才真的扣；不同意的話什麼都不會動。`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_create_store_return", {
        p_store_id: storeId,
        p_lines: lines.map((l) => ({ sku_id: l.id, qty: l.qty })),
        p_reason: reason,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      const r = (res ?? {}) as { transfer_id?: number; transfer_no?: string };
      alert(
        `✅ 已送出退貨單 ${r.transfer_no ?? ""}（共 ${totalQty} 件）。\n\n` +
          `庫存還沒扣 —— 要等總倉按「同意收回」。\n` +
          `48 小時內總倉沒處理的話，系統會自動視同同意。`,
      );
      onCreated(Number(r.transfer_id ?? 0));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open={open} onClose={onClose} title="＋ 我要退貨（退回總倉）" maxWidth="max-w-2xl">
      <div className="space-y-4 text-sm">
        {error && (
          <div className="rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
          退貨店家：<strong className="text-zinc-800 dark:text-zinc-200">{storeName}</strong>
        </div>

        {/* ── 步驟 1：選商品 ── */}
        <div>
          <span className="mb-1 block text-xs font-medium text-zinc-500">1. 要退什麼商品</span>
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="🔍 搜尋 商品名 / 編號 / 規格…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
          {(hits.length > 0 || searching) && (
            <div className="mt-1 max-h-56 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-700">
              {searching && hits.length === 0 && (
                <div className="px-3 py-2 text-xs text-zinc-500">搜尋中…</div>
              )}
              {hits.map((s) => (
                <SpinButton
                  key={s.id}
                  onClick={() => pick(s)}
                  className="block w-full border-b border-zinc-100 px-3 py-2 text-left last:border-b-0 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
                >
                  <span className="font-mono text-xs text-zinc-500">{s.sku_code}</span> {skuLabel(s)}
                </SpinButton>
              ))}
            </div>
          )}
        </div>

        {/* ── 步驟 2：數量 ── */}
        {lines.length > 0 && (
          <div>
            <span className="mb-1 block text-xs font-medium text-zinc-500">2. 各退幾件</span>
            <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
              <table className="min-w-full text-xs">
                <thead className="bg-zinc-50 text-zinc-500 dark:bg-zinc-900">
                  <tr>
                    <th className="px-3 py-1.5 text-left">商品</th>
                    <th className="px-3 py-1.5 text-right">店裡帳上</th>
                    <th className="px-3 py-1.5 text-right">已在等回覆</th>
                    <th className="px-3 py-1.5 text-right">這次退</th>
                    <th className="px-3 py-1.5"></th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                  {lines.map((l) => (
                    <tr key={l.id}>
                      <td className="px-3 py-1.5">
                        <span className="font-mono text-[11px] text-zinc-500">{l.sku_code}</span>{" "}
                        {skuLabel(l)}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums">{l.onHand}</td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-amber-700 dark:text-amber-400">
                        {l.pending > 0 ? l.pending : "—"}
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <input
                          type="number"
                          min={1}
                          max={Math.max(l.onHand - l.pending, 0)}
                          value={l.qty}
                          onChange={(e) => setQty(l.id, e.target.value)}
                          className="w-20 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
                        />
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <SpinButton
                          onClick={() => setLines((prev) => prev.filter((x) => x.id !== l.id))}
                          className="text-xs text-zinc-500 underline"
                        >
                          移除
                        </SpinButton>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-1 text-[11px] text-zinc-500">
              上限 ＝ 店裡帳上的件數 −「已在等回覆」的件數。
            </p>
          </div>
        )}

        {/* ── 步驟 3：原因 ── */}
        <div>
          <span className="mb-1 block text-xs font-medium text-zinc-500">3. 為什麼要退（選一個）</span>
          <div className="flex flex-wrap gap-2">
            {REASONS.map((r) => (
              <SpinButton
                key={r}
                onClick={() => setReason(r)}
                title={REASON_HINT[r]}
                className={`rounded-md border px-3 py-1.5 text-sm ${
                  reason === r
                    ? "border-orange-500 bg-orange-50 font-semibold text-orange-700 dark:border-orange-600 dark:bg-orange-950 dark:text-orange-300"
                    : "border-zinc-300 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                }`}
              >
                {r}
              </SpinButton>
            ))}
          </div>
          {reason !== "" && (
            <p className="mt-1 text-[11px] text-zinc-500">{REASON_HINT[reason]}</p>
          )}
          {/* ⚠⚠ 「客人退」有兩種完全不同的情況，只有一種可以走這一頁。
              查證（三處都是現行程式碼）：
                ① 這一頁建的退貨單 customer_order_id 是 NULL（20260904020000 刻意的）；
                ② 取貨守門只算「掛在同一張訂單上」的退貨
                   （rpc_record_pickup 最新版 20260801000000:695 `t.customer_order_id = p_order_id`）；
                ③ 訂單收尾與應收扣減同樣只吃掛訂單的退貨（同檔 :279-330）。
              ⇒ 客人**還沒取**就不要了，走這一頁的話：訂單不會結掉、客人照樣被收錢、
                 而且他還是可以來取貨 —— 那是實際會出事的，所以這裡要講出來。
              ⛔ 這段話只是告訴店家走哪條路，**沒有**把「客人退」這個選項拿掉
                 （四個原因是老闆 2026-09-04 逐字定的）。 */}
          {reason === "客人退" && (
            <p className="mt-1 rounded-md border border-amber-300 bg-amber-50 p-2 text-[11px] text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
              ⚠ 這個選項是給「<strong>客人已經領走了、又拿回來還</strong>」用的。
              <br />
              如果是「客人還沒來領就說不要了」，<strong>請不要用這一頁</strong> ——
              要到那張訂單上處理（退貨或轉給別人）。從這裡送出的話，那張訂單不會結掉、
              客人照樣要付錢，而且他還是領得到貨。
            </p>
          )}
          {reason === "少收" && (
            <p className="mt-1 rounded-md border border-amber-300 bg-amber-50 p-2 text-[11px] text-amber-900 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
              ⚠ 如果是<strong>某一張調撥單收到的數量不對</strong>，請直接在「收貨」頁把實收數字改對 ——
              那條路總倉會看到差額、錢也會自動跟著算。這裡送出的是「把貨退回總倉」，兩邊都做會重複。
            </p>
          )}
        </div>

        <div className="flex items-center justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={submit}
            disabled={!canSubmit}
            className="rounded-md bg-orange-600 px-5 py-2 font-semibold text-white hover:bg-orange-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy ? "送出中…" : `送出退貨（${totalQty} 件）`}
          </SpinButton>
        </div>

        {/* ⚠ 這段講的是「按下去之後會發生什麼」，兩邊都講（做了會怎樣／不做會怎樣）。
            每一句的出處：不扣庫存＝20260904020000 建單段刻意不呼叫 rpc_outbound；
            同意才扣＝20260904020010；不同意零動作＝20260904020020；
            48 小時＝20260903010020（cron jobid=5，老闆 2026-09-04 已貼上線）。 */}
        <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-[11px] leading-relaxed text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
          送出之後會發生什麼：
          <br />・庫存<strong>不會</strong>馬上扣，帳上的數字不變，只是旁邊多一個「退貨中 N」。
          <br />・總倉按「同意收回」<strong>那一刻</strong>才真的從店裡扣掉、記進總倉。
          <br />・總倉按「不同意退貨」＝什麼都沒動過，貨還是在店裡。
          <br />・總倉 48 小時沒處理，系統會自動視同同意收回。
          <br />・⚠ 送出之後如果把這批貨賣掉或給客人取走了，總倉按同意時會<strong>扣不動而失敗</strong>，
          那張單會一直卡著。請把貨留著。
        </div>
      </div>
    </Modal>
  );
}
