"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";
import { excelSafeText, toCsv } from "@/lib/printSheet";

type WaveItem = {
  id: number;
  wave_id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  picked_qty: number | null;
};

type WaveRow = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: string;
  created_at: string;
};

type StoreRow = { id: number; code: string | null; name: string };
type SkuRow = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

type StoreSheet = {
  store: StoreRow;
  rows: {
    sku: SkuRow;
    qty: number;
    pickedQty: number;
    waveCodes: string[];
    unitPrice: number | null; // 分店價(prices scope='branch' 現行價)；查無 = null
    subtotal: number | null;
  }[];
  totalPicked: number;
  totalAmount: number; // 只加總查得到分店價的品項
  hasMissingPrice: boolean;
  waveDates: string[]; // 涵蓋的配送日(可能多日)
  orderDates: string[]; // 涵蓋的撿貨單建立日 = 表頭「訂單日」
};

// 表頭金額一律無小數（分店進貨單對的是整數台幣）
function money(n: number): string {
  return `$${Math.round(n).toLocaleString("en-US")}`;
}

// CSV 合計列在「編號」欄放的固定標記（老闆 2026-08-17 追加合計列時定的）。
// 明細列的那一欄永遠是品號或「—」，不可能是這兩個字 —— 老闆在 Excel 把這個值篩掉，
// 就能一次排除全部合計列，樞紐才不會把每家店的金額重複算一次。
const CSV_TOTAL_MARK = "合計";

// CSV 的「店號 / 店名」兩欄。老闆 2026-08-17 要求拆開：`三峽店(S01)` 擠在一格
// 就沒辦法拿去跑 Excel 樞紐，而店號排序比店名穩，所以店號放前面。
// ⚠ stores.code 沒有 NOT NULL，查無一律印「—」：空白格在樞紐裡會顯示成「(空白)」，
//   而本頁其他查無資料的欄位（編號 / 品名）用的也是「—」，保持一致。
//   註：「—」是 U+2014，不是 ASCII 的 `-`，不會被 excelSafeText 當成公式開頭加引號。
function storeCsvCells(s: StoreRow): string[] {
  return [excelSafeText(s.code || "—"), excelSafeText(s.name)];
}

export default function PrintSignPage() {
  const [date, setDate] = useState("");
  const [waveIds, setWaveIds] = useState<number[] | null>(null); // 非 null 表示用 ID list,優先於 date
  const [waves, setWaves] = useState<WaveRow[] | null>(null);
  const [items, setItems] = useState<WaveItem[]>([]);
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [skus, setSkus] = useState<SkuRow[]>([]);
  const [prices, setPrices] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [tenantName, setTenantName] = useState("");

  // 從 query 抓 waveIds 或 date
  useEffect(() => {
    if (typeof window === "undefined") return;
    const params = new URLSearchParams(window.location.search);
    const idsStr = params.get("waveIds");
    if (idsStr) {
      const ids = idsStr.split(",").map((s) => Number(s)).filter((n) => Number.isFinite(n) && n > 0);
      if (ids.length > 0) {
        setWaveIds(ids);
        return;
      }
    }
    const d = params.get("date");
    if (d) setDate(d);
    else setDate(new Date().toLocaleDateString("sv-SE"));
  }, []);

  useEffect(() => {
    if (!date && !waveIds) return;
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const q = sb
          .from("picking_waves")
          .select("id, wave_code, wave_date, status, created_at")
          .neq("status", "cancelled")
          .order("wave_date", { ascending: true })
          .order("created_at", { ascending: true });
        const { data: waveRows, error: e1 } = await (waveIds
          ? q.in("id", waveIds)
          : q.eq("wave_date", date));
        if (e1) throw new Error(e1.message);
        const list = (waveRows as WaveRow[] | null) ?? [];
        if (cancelled) return;
        setWaves(list);
        if (list.length === 0) {
          setItems([]);
          setStores([]);
          setSkus([]);
          return;
        }

        const ids = list.map((w) => w.id);
        const { data: itemRows, error: e2 } = await sb
          .from("picking_wave_items")
          .select("id, wave_id, sku_id, store_id, qty, picked_qty")
          .in("wave_id", ids);
        if (e2) throw new Error(e2.message);
        const its = ((itemRows as WaveItem[] | null) ?? []).map((r) => ({
          ...r,
          qty: Number(r.qty),
          picked_qty: r.picked_qty == null ? null : Number(r.picked_qty),
        }));
        if (cancelled) return;
        setItems(its);

        const storeIds = Array.from(new Set(its.map((r) => r.store_id)));
        const skuIds = Array.from(new Set(its.map((r) => r.sku_id)));
        const [ss, sk] = await Promise.all([
          storeIds.length
            ? sb.from("stores").select("id, code, name").in("id", storeIds).order("code")
            : Promise.resolve({ data: [] as StoreRow[] }),
          skuIds.length
            ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds)
            : Promise.resolve({ data: [] as SkuRow[] }),
        ]);
        if (!cancelled) {
          setStores((ss.data as StoreRow[]) ?? []);
          setSkus((sk.data as SkuRow[]) ?? []);
        }

        // 單價 = 現行分店價（prices scope='branch' 且 effective_to IS NULL）。
        // 這是派貨守衛也在檢查的那個價，跟月結拿到的價一致；查無價的品項印「—」不併入合計。
        // .in() 有長度上限，跟派貨工作台一樣切 150 一批。
        const priceMap = new Map<number, number>();
        for (let i = 0; i < skuIds.length; i += 150) {
          const chunk = skuIds.slice(i, i + 150);
          const { data: priceRows, error: e3 } = await sb
            .from("prices")
            .select("sku_id, price")
            .eq("scope", "branch")
            .is("effective_to", null)
            .in("sku_id", chunk);
          if (e3) throw new Error(e3.message);
          for (const p of (priceRows ?? []) as { sku_id: number; price: number }[]) {
            if (!priceMap.has(p.sku_id)) priceMap.set(p.sku_id, Number(p.price));
          }
        }
        if (!cancelled) setPrices(priceMap);

        const { data: tenantData } = await sb.from("tenants").select("name").limit(1);
        if (!cancelled) {
          const t = (tenantData as { name: string }[] | null)?.[0];
          if (t?.name) setTenantName(t.name);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [date, waveIds]);

  const sheets: StoreSheet[] = useMemo(() => {
    if (!waves || items.length === 0) return [];
    const skuMap = new Map(skus.map((s) => [s.id, s]));
    const waveCodeMap = new Map(waves.map((w) => [w.id, w.wave_code]));
    const waveDateMap = new Map(waves.map((w) => [w.id, w.wave_date]));
    // 撿貨單建立日 → 表頭「訂單日」（wave_date 是配送/出貨日，兩者常差一天）
    const orderDateMap = new Map(
      waves.map((w) => [w.id, new Date(w.created_at).toLocaleDateString("sv-SE")])
    );

    // (store_id) -> (sku_id) -> { qty, picked_qty, waveCodes Set, waveDates Set }
    const byStore = new Map<
      number,
      {
        skus: Map<number, { qty: number; pickedQty: number; waveCodes: Set<string> }>;
        waveDates: Set<string>;
        orderDates: Set<string>;
      }
    >();
    for (const it of items) {
      if (!byStore.has(it.store_id))
        byStore.set(it.store_id, { skus: new Map(), waveDates: new Set(), orderDates: new Set() });
      const slot = byStore.get(it.store_id)!;
      const cur = slot.skus.get(it.sku_id) ?? {
        qty: 0,
        pickedQty: 0,
        waveCodes: new Set<string>(),
      };
      cur.qty += it.qty;
      // picked_qty 為 NULL = 該波尚未做「撿貨確認」(rpc_confirm_picked 還沒 backfill)。
      // 這種情況下 fallback 顯示派貨計畫量 qty,讓「撿貨前先列印簽收單給司機」也印得出數量;
      // 撿貨確認後 picked_qty 會被寫成實撿量,短撿差異仍靠下方 (派 {qty}) 標註呈現。
      // 注意:明確被設成 0(短撿到 0)不是 NULL,會照實顯示 0,不走 fallback。
      cur.pickedQty += it.picked_qty == null ? it.qty : it.picked_qty;
      const wc = waveCodeMap.get(it.wave_id);
      if (wc) cur.waveCodes.add(wc);
      const wd = waveDateMap.get(it.wave_id);
      if (wd) slot.waveDates.add(wd);
      const od = orderDateMap.get(it.wave_id);
      if (od) slot.orderDates.add(od);
      slot.skus.set(it.sku_id, cur);
    }

    const result: StoreSheet[] = [];
    for (const store of stores) {
      const slot = byStore.get(store.id);
      if (!slot || slot.skus.size === 0) continue;
      const rows = Array.from(slot.skus.entries())
        .map(([skuId, v]) => {
          const unitPrice = prices.get(skuId) ?? null;
          return {
            sku: skuMap.get(skuId) ?? { id: skuId, sku_code: null, product_name: null, variant_name: null },
            qty: v.qty,
            pickedQty: v.pickedQty,
            waveCodes: Array.from(v.waveCodes).sort(),
            unitPrice,
            // 小計照「實際配發量」算 — 短撿時分店只該被收到的貨算錢
            subtotal: unitPrice == null ? null : unitPrice * v.pickedQty,
          };
        })
        .sort((a, b) => (a.sku.sku_code ?? "").localeCompare(b.sku.sku_code ?? ""))
        // 派貨計畫中(qty>0)的品項都要列上,即使尚未撿貨/短缺到 0
        // ─ 司機 / 收貨店家才知道「應該」收到什麼,short-pick 也看得出來
        .filter((r) => r.qty > 0 || r.pickedQty > 0);
      if (rows.length === 0) continue;
      const totalPicked = rows.reduce((s, r) => s + r.pickedQty, 0);
      const totalAmount = rows.reduce((s, r) => s + (r.subtotal ?? 0), 0);
      const hasMissingPrice = rows.some((r) => r.unitPrice == null);
      result.push({
        store,
        rows,
        totalPicked,
        totalAmount,
        hasMissingPrice,
        waveDates: Array.from(slot.waveDates).sort(),
        orderDates: Array.from(slot.orderDates).sort(),
      });
    }
    return result;
  }, [waves, items, stores, skus, prices]);

  // 匯出 CSV — 全部分店合在同一個檔，靠前兩欄「店號 / 店名」分辨（老闆 2026-08-17 定案：
  // 不要一間店一個檔）。欄位跟紙本對得起來，才能拿檔案核簽回來的那疊紙。
  function exportCsv() {
    // ⚠ 文字欄一律過 excelSafeText：擋公式注入，也擋 Excel 把 `G00351-01` 這種碼
    //   自作主張改成日期／科學記號。數量與金額維持純數字，Excel 才加得了總。
    // ⚠ 金額先 Math.round 再輸出 —— 紙上的 money() 印的就是四捨五入後的整數，
    //   CSV 若給沒進位的小數，老闆兩邊會對不起來。這裡不做任何別的算術。
    const header = ["店號", "店名", "編號", "商品名稱", "數量", "訂購量", "單價", "小計"];
    const body = sheets.flatMap((sheet) => [
      ...sheet.rows.map((r) => [
        ...storeCsvCells(sheet.store),
        excelSafeText(r.sku.sku_code ?? "—"),
        excelSafeText(
          r.sku.variant_name
            ? `${r.sku.product_name ?? "—"} / ${r.sku.variant_name}`
            : r.sku.product_name ?? "—"
        ),
        // 數量＝實配量（跟紙上那格一樣）；訂購量在紙上是括號註記，CSV 拆成獨立欄好對帳
        r.pickedQty,
        r.qty,
        r.unitPrice == null ? "" : Math.round(r.unitPrice),
        r.subtotal == null ? "" : Math.round(r.subtotal),
      ]),
      // 每家店的明細後面接一列合計（老闆 2026-08-17 追加）。
      // ⚠ 編號欄放 CSV_TOTAL_MARK 就是為了讓老闆一個篩選排除掉整批合計列 ——
      //   他拆兩欄的目的是跑樞紐，而樞紐會把這一列的金額跟明細再加一次。
      // ⛔ 刻意不在檔尾再加一列總計：老闆沒要，而且多一層更難篩。
      // ⚠ 數量與金額直接用 sheets 已經算好的 totalPicked / totalAmount，跟紙上那列
      //   印的是同一個值（連四捨五入的時機都一樣），沒有在這裡重算過。
      //   訂購量紙上沒有合計，只能在這裡加總 —— 加法比照 useMemo 裡 totalPicked 的寫法。
      [
        ...storeCsvCells(sheet.store),
        excelSafeText(CSV_TOTAL_MARK),
        excelSafeText(
          sheet.store.code
            ? `${sheet.store.name}(${sheet.store.code}) 合計`
            : `${sheet.store.name} 合計`
        ),
        sheet.totalPicked,
        sheet.rows.reduce((s, r) => s + r.qty, 0),
        "", // 單價：把各品項的單價加起來沒有意義，留空
        Math.round(sheet.totalAmount),
      ],
    ]);
    const csv = toCsv([header, ...body]);
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    // ⛔ 檔名的日期只取自資料庫的 wave_date（查無就用今天），**不用網址上的 ?date=** ——
    //    那是使用者可控字串，直接接進 a.download 等於讓網址決定檔名。
    const fileDate =
      Array.from(new Set(sheets.flatMap((s) => s.waveDates))).sort()[0] ??
      new Date().toLocaleDateString("sv-SE");
    a.href = url;
    a.download = `分店簽收單_${fileDate}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  }

  if (!date && !waveIds) {
    return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  }

  return (
    <>
      <style jsx global>{`
        @media print {
          @page {
            size: A4;
            margin: 12mm;
          }
          .no-print {
            display: none !important;
          }
          .sheet {
            page-break-after: always;
          }
          .sheet:last-child {
            page-break-after: auto;
          }
          body {
            background: white !important;
          }
        }
      `}</style>

      <div className="bg-white text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏）*/}
        <div className="no-print sticky top-0 z-20 flex flex-wrap items-center gap-3 border-b border-zinc-200 bg-zinc-50 p-3 print:hidden">
          <h1 className="text-base font-semibold">分店簽收單列印</h1>
          {waveIds ? (
            <span className="text-sm text-zinc-600">
              指定 {waveIds.length} 張撿貨單
              {waves && waves.length > 0 && (
                <span className="ml-2 font-mono text-xs text-zinc-500">
                  ({waves.map((w) => w.wave_code).join("、")})
                </span>
              )}
            </span>
          ) : (
            <label className="flex items-center gap-2 text-sm">
              <span>配送日</span>
              <DatePicker
                value={date}
                onChange={setDate}
                className="rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
              />
            </label>
          )}
          <span className="text-sm text-zinc-500">
            {waves === null
              ? "載入中…"
              : sheets.length === 0
              ? "（無資料）"
              : `${sheets.length} 間分店、${waves.length} 張撿貨單`}
          </span>
          <SpinButton
            onClick={exportCsv}
            disabled={sheets.length === 0}
            className="ml-auto rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm text-zinc-700 hover:bg-zinc-100 disabled:opacity-50"
          >
            ⬇ 匯出 CSV
          </SpinButton>
          <SpinButton
            onClick={() => window.print()}
            disabled={sheets.length === 0}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            🖨️ 列印
          </SpinButton>
        </div>

        {error && (
          <div className="no-print m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            {error}
          </div>
        )}

        {/* 簽收單內容 */}
        {sheets.length === 0 && waves !== null && (
          <div className="no-print p-6 text-center text-sm text-zinc-500">
            此日無已派貨資料 — 請選擇有撿貨單的配送日。
          </div>
        )}

        {/* ⛔ 這裡原本有一張「出車總覽」（依店 group、底下再列一次商品）。
            2026-08-17 老闆指示移除：它自己就是一張 A4（`sheet` 有 page-break-after），
            內容又跟後面每一張簽收單完全重複 —— 每次列印白白多印一整張紙。 */}

        {sheets.map((sheet) => (
          <div
            key={sheet.store.id}
            className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0"
          >
            {/* 表頭 — 公司抬頭置中，底下左右兩欄的單頭欄位（單號/訂單日 ‧ 店家/出貨日）*/}
            <div className="mb-3 text-center">
              {tenantName && <div className="text-lg font-bold tracking-wide">{tenantName}</div>}
              <div className="text-xs text-zinc-500">分店進貨單</div>
            </div>

            <div className="mb-2 text-sm">
              {/* 三個短欄位並排；放不下就自己換行,不去擠壓彼此 */}
              <div className="flex flex-wrap gap-x-8">
                <div className="flex">
                  <span className="w-16 shrink-0 text-zinc-500">店家</span>
                  <span className="font-semibold">
                    {sheet.store.name}
                    {sheet.store.code && (
                      <span className="ml-2 font-mono text-xs text-zinc-500">({sheet.store.code})</span>
                    )}
                  </span>
                </div>
                <div className="flex">
                  <span className="w-16 shrink-0 text-zinc-500">訂單日</span>
                  <span className="font-mono">{sheet.orderDates.join("、") || "—"}</span>
                </div>
                <div className="flex">
                  <span className="w-16 shrink-0 text-zinc-500">出貨日</span>
                  <span className="font-mono">{sheet.waveDates.join("、") || date}</span>
                </div>
              </div>
              {/* ⚠ 單號一定要自己獨佔一整行。
                  原本它跟上面三欄同在一個 grid-cols-2 裡,只分到半頁寬(約 85mm),
                  而一張簽收單常涵蓋十幾張撿貨單,單號串起來就被折成好幾行,吃掉整個紙頭。
                  單號本身一個都不能省(老闆 2026-08-17 明確:「我沒有要把單號拿掉」),
                  所以解法是給它整行寬度,不是縮字或縮寫。 */}
              <div className="flex">
                <span className="w-16 shrink-0 text-zinc-500">單號</span>
                <span className="font-mono font-semibold">
                  {Array.from(new Set(sheet.rows.flatMap((r) => r.waveCodes))).join("、") || "—"}
                </span>
              </div>
            </div>

            {/* 商品表 — 編號 / 商品名稱 / 數量 / 單價 / 小計（＋點收框）*/}
            <table className="w-full border-collapse text-sm">
              <thead>
                <tr className="bg-zinc-100">
                  {/* ⚠ 編號欄一定要 whitespace-nowrap。
                      不是「沒給寬度」那麼單純:`G00351-01` 裡的連字號是合法斷行點,
                      所以這一欄的 min-content 只有 `G00351-` 那麼寬 —— 表格一被長品名擠,
                      瀏覽器就名正言順把它縮到 7 個字寬、把碼折成兩行。
                      給固定寬度沒有用(table-layout: auto 底下 width 只是建議值,min-content 仍會贏),
                      要 nowrap 把 min-content 撐成整串碼,這一欄才縮不下去。
                      作法比照既有的 finance/receivables/print。 */}
                  <th className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">編號</th>
                  <th className="border border-zinc-400 px-2 py-1 text-left text-xs font-semibold">商品名稱</th>
                  <th className="w-16 border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">數量</th>
                  <th className="w-20 border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">單價</th>
                  <th className="w-24 border border-zinc-400 px-2 py-1 text-right text-xs font-semibold">小計</th>
                  <th className="w-12 whitespace-nowrap border border-zinc-400 px-2 py-1 text-center text-xs font-semibold">
                    點收
                  </th>
                </tr>
              </thead>
              <tbody>
                {sheet.rows.map((r) => (
                  <tr key={r.sku.id}>
                    <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 font-mono text-xs">
                      {r.sku.sku_code ?? "—"}
                    </td>
                    <td className="border border-zinc-400 px-2 py-0.5">
                      {r.sku.product_name ?? "—"}
                      {r.sku.variant_name && (
                        <span className="ml-1 text-xs text-zinc-500">/ {r.sku.variant_name}</span>
                      )}
                    </td>
                    {/* 數量 = 實際配發量；短撿時在旁邊補註訂購量，分店才對得出少了什麼。
                        nowrap 是預防性的：目前的量級（個位/十位數）在 w-16 裡本來就排得下，
                        但數量一多（例如以克計價的品項）「(訂 N)」就會掉到第二行、整列變高。 */}
                    <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">
                      <span className={r.pickedQty < r.qty ? "text-rose-600" : ""}>{r.pickedQty}</span>
                      {r.pickedQty < r.qty && (
                        <span className="ml-1 text-[10px] text-zinc-500">(訂 {r.qty})</span>
                      )}
                    </td>
                    <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">
                      {r.unitPrice == null ? "—" : money(r.unitPrice)}
                    </td>
                    <td className="whitespace-nowrap border border-zinc-400 px-2 py-0.5 text-right font-mono">
                      {r.subtotal == null ? "—" : money(r.subtotal)}
                    </td>
                    <td className="border border-zinc-400 px-2 py-0.5 text-center">
                      <span className="text-zinc-300">□</span>
                    </td>
                  </tr>
                ))}
                {/* 補空行讓表格美觀（品項很少時才會出現，手寫補品項也用得上） */}
                {Array.from({ length: Math.max(0, 5 - sheet.rows.length) }).map((_, i) => (
                  <tr key={`empty-${i}`}>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                    <td className="border border-zinc-400 px-2 py-2"></td>
                  </tr>
                ))}
                {/* 合計列 — 件數 + 金額，對齊紙本單 */}
                <tr className="bg-zinc-100 font-semibold">
                  <td colSpan={2} className="border border-zinc-400 px-2 py-1 text-right">
                    合計
                  </td>
                  <td className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right font-mono">
                    {sheet.totalPicked} 件
                  </td>
                  <td className="border border-zinc-400 px-2 py-1"></td>
                  <td className="whitespace-nowrap border border-zinc-400 px-2 py-1 text-right font-mono">
                    {money(sheet.totalAmount)}
                  </td>
                  <td className="border border-zinc-400 px-2 py-1"></td>
                </tr>
              </tbody>
            </table>

            {sheet.hasMissingPrice && (
              <div className="mt-1 text-[10px] text-zinc-500">
                ※ 標「—」的品項尚未設定分店價，未計入合計金額。
              </div>
            )}

            {/* 簽名區 */}
            <div className="mt-8 grid grid-cols-2 gap-8 text-sm">
              <div>
                <div className="text-xs text-zinc-500">收貨人簽名 / 日期</div>
                <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                  簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
                </div>
              </div>
              <div>
                <div className="text-xs text-zinc-500">送貨人</div>
                <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
                  簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
                </div>
              </div>
            </div>

            <div className="mt-6 text-[10px] text-zinc-500">
              ※ 收到請逐項點收，數量不符請於收貨人簽名旁註明短少 / 多到項目與數量。
            </div>
          </div>
        ))}
      </div>
    </>
  );
}
