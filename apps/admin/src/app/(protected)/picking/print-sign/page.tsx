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
        // ⚠ 每次查詢一開始，先把上一輪的錯誤與資料全部清掉。
        //   這兩件事**必須成對做**，只做一半比不做更糟：
        //   ‧ 只清資料、不清 error → 老闆遇到一次失敗後列印/CSV 永遠按不下去，要重開分頁才解得掉
        //   ‧ 只清 error、不清資料 → 查詢中途失敗時會留著上一輪的 prices，跟這一輪剛寫進去的
        //     新商品混出一張「金額是舊的」簽收單 —— 而那是要印給店家簽收的錢（阿審 #759 第三輪 P0-2）
        //   ⛔ 清除一律放在這裡（async 內、第一個 await 之前），不要搬到 effect 本體：
        //     搬上去會多一條 react-hooks/set-state-in-effect。
        setError(null);
        setWaves(null);
        setItems([]);
        setStores([]);
        setSkus([]);
        setPrices(new Map());
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
            : Promise.resolve({ data: [] as StoreRow[], error: null }),
          skuIds.length
            ? sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", skuIds)
            : Promise.resolve({ data: [] as SkuRow[], error: null }),
        ]);
        // ⚠ 這兩個查詢的 error 原本沒人看：失敗時 data 是 null → `?? []` 變成空陣列 →
        //   畫面走「此日無已派貨資料」，老闆會以為那天真的沒出貨（阿審 #759 第三輪 P0-1）。
        //   skus 失敗更陰險：紙本與 CSV 會把品號品名印成「—」，看起來就只是缺資料。
        //   一律比照上面 e1 / e2 / e3 的既有寫法直接 throw，交給 catch 走錯誤狀態。
        //   （`error: null` 是上面兩個空清單捷徑補的，補了這裡才讀得到 .error）
        if (ss.error) throw new Error(ss.error.message);
        if (sk.error) throw new Error(sk.error.message);
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
    const waveDateMap = new Map(waves.map((w) => [w.id, w.wave_date]));
    // 撿貨單建立日 → 表頭「訂單日」（wave_date 是配送/出貨日，兩者常差一天）
    const orderDateMap = new Map(
      waves.map((w) => [w.id, new Date(w.created_at).toLocaleDateString("sv-SE")])
    );

    // (store_id) -> (sku_id) -> { qty, picked_qty }，另加該店的 waveDates / orderDates Set
    const byStore = new Map<
      number,
      {
        skus: Map<number, { qty: number; pickedQty: number }>;
        waveDates: Set<string>;
        orderDates: Set<string>;
      }
    >();
    for (const it of items) {
      if (!byStore.has(it.store_id))
        byStore.set(it.store_id, { skus: new Map(), waveDates: new Set(), orderDates: new Set() });
      const slot = byStore.get(it.store_id)!;
      const cur = slot.skus.get(it.sku_id) ?? { qty: 0, pickedQty: 0 };
      cur.qty += it.qty;
      // picked_qty 為 NULL = 該波尚未做「撿貨確認」(rpc_confirm_picked 還沒 backfill)。
      // 這種情況下 fallback 顯示派貨計畫量 qty,讓「撿貨前先列印簽收單給司機」也印得出數量;
      // 撿貨確認後 picked_qty 會被寫成實撿量,短撿差異仍靠下方 (派 {qty}) 標註呈現。
      // 注意:明確被設成 0(短撿到 0)不是 NULL,會照實顯示 0,不走 fallback。
      cur.pickedQty += it.picked_qty == null ? it.qty : it.picked_qty;
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

  // 匯出 CSV — 全部分店合在同一個檔，靠「店號 / 店名」兩欄分辨（老闆 2026-08-17 定案：
  // 不要一間店一個檔）。欄位跟紙本對得起來，才能拿檔案核簽回來的那疊紙。
  function exportCsv() {
    // ⚠ 文字欄一律過 excelSafeText：擋公式注入，也擋 Excel 把 `G00351-01` 這種碼
    //   自作主張改成日期／科學記號。數量與金額維持純數字，Excel 才加得了總。
    // ⚠ 金額先 Math.round 再輸出 —— 紙上的 money() 印的就是四捨五入後的整數，
    //   CSV 若給沒進位的小數，老闆兩邊會對不起來。這裡不做任何別的算術。
    // ⚠ 第一欄「類型」＝明細／合計。**這是唯一能分辨合計列的欄位**，老闆要在 Excel 篩掉
    //   合計列（不然樞紐會把每家店的金額重複算一次）就篩這一欄。
    //   ⛔ 不可以改回用「編號」欄放標記：sku_code 只有 `TEXT NOT NULL`，DB 沒有任何約束
    //      擋得住某個品號真的就叫「合計」；真撞上時篩選會連那列明細一起刪掉，
    //      而且刪掉的是金額、老闆不會發現（阿審 #759 複審 P1）。
    const header = ["類型", "店號", "店名", "編號", "商品名稱", "數量", "訂購量", "單價", "小計"];
    const body = sheets.flatMap((sheet) => [
      ...sheet.rows.map((r) => [
        excelSafeText("明細"),
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
      // ⛔ 刻意不在檔尾再加一列總計：老闆沒要，而且多一層更難篩。
      // ⚠ 編號欄留空 —— 識別合計列一律看「類型」欄（見上面 header 的說明）。
      // ⚠ 數量與金額直接用 sheets 已經算好的 totalPicked / totalAmount，跟紙上那列
      //   印的是同一個值（連四捨五入的時機都一樣），沒有在這裡重算過。
      //   訂購量紙上沒有合計，只能在這裡加總 —— 加法比照 useMemo 裡 totalPicked 的寫法。
      [
        excelSafeText("合計"),
        ...storeCsvCells(sheet.store),
        "",
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
          {/* ⚠ 「出錯了」和「這天真的沒貨」在畫面上必須一眼分得出來 —— 兩者都是空畫面，
              但一個要重試、一個不用。error 優先於其他狀態顯示。 */}
          <span className={error ? "text-sm font-semibold text-red-700" : "text-sm text-zinc-500"}>
            {error
              ? "⚠ 載入失敗（不是沒資料）"
              : waves === null
              ? "載入中…"
              : sheets.length === 0
              ? "（無資料）"
              : `${sheets.length} 間分店、${waves.length} 張撿貨單`}
          </span>
          {/* ⚠ 有 error 就不准列印/匯出：載入到一半失敗時手上這份資料是殘缺的，
              印出去就是拿錯的金額給店家簽收（阿審 #759 第三輪 P0-2）。
              ⛔ 這個 disable 一定要搭配「查詢開始時 setError(null)」一起看 —— 少了那半邊，
                 老闆遇到一次失敗就再也按不了按鈕。 */}
          <SpinButton
            onClick={exportCsv}
            disabled={sheets.length === 0 || error !== null}
            className="ml-auto rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-sm text-zinc-700 hover:bg-zinc-100 disabled:opacity-50"
          >
            ⬇ 匯出 CSV
          </SpinButton>
          <SpinButton
            onClick={() => window.print()}
            disabled={sheets.length === 0 || error !== null}
            className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
          >
            🖨️ 列印
          </SpinButton>
        </div>

        {/* ⚠ 錯誤訊息本身是 Supabase 丟回來的英文技術字串，老闆看不出「要不要重試」，
            所以上面補一句白話結論。原文照留在最下面，工程師才查得下去。 */}
        {error && (
          <div className="no-print m-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">
            <div className="font-semibold">⚠ 資料載入失敗 —— 這不是「今天沒有貨」。</div>
            <div className="mt-1">
              畫面上的資料不完整，已停用列印與匯出 CSV。請重新整理或重選配送日再試一次。
            </div>
            <div className="mt-1 font-mono text-xs break-words text-red-700">{error}</div>
          </div>
        )}

        {/* 簽收單內容 */}
        {/* ⚠ `!error` 這個條件是重點：沒有它，查詢失敗（例如 stores 查不到）也會落到這一行，
            畫面就變成「此日無已派貨資料」—— 系統壞掉偽裝成當天沒出貨，老闆分不出來。 */}
        {sheets.length === 0 && waves !== null && !error && (
          <div className="no-print p-6 text-center text-sm text-zinc-500">
            此日無已派貨資料 — 請選擇有撿貨單的配送日。
          </div>
        )}

        {/* ⛔ 這裡原本有一張「出車總覽」（依店 group、底下再列一次商品）。
            2026-08-17 老闆指示移除：它自己就是一張 A4（`sheet` 有 page-break-after），
            內容又跟後面每一張簽收單完全重複 —— 每次列印白白多印一整張紙。 */}

        {/* ⚠ 有 error 就整批不渲染。價格查詢失敗時 waves/items/stores/skus 其實都已經進 state，
            簽收單照樣排得出來，只是單價全變「—」、合計變 $0，底下還會掛一句
            「※ 標『—』的品項尚未設定分店價」—— 那句在這個情況下是**騙人的**（價格不是沒設，
            是根本沒查到）。按鈕擋得住我們自己的列印鈕，擋不住瀏覽器的 Ctrl+P，
            所以錯誤狀態下乾脆不給任何可印的東西（阿審 #759 第三輪 P0-2:「清空可列印資料」）。
            ⛔ 這是唯一對簽收單本體的改動，而且只在 error 非 null 時生效 ——
              正常情境下每一格的文字與 class 都跟 5a50b7e 逐字元相同（v5 指紋已驗）。 */}
        {(error ? [] : sheets).map((sheet) => (
          <div
            key={sheet.store.id}
            className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0"
          >
            {/* 表頭 — 公司抬頭置中，底下一排三格單頭欄位（店家 ‧ 訂單日 ‧ 出貨日）*/}
            <div className="mb-3 text-center">
              {tenantName && <div className="text-lg font-bold tracking-wide">{tenantName}</div>}
              <div className="text-xs text-zinc-500">分店進貨單</div>
            </div>

            {/* ⛔ 這一區原本有第四格「單號」(撿貨單號 wave_code)。2026-08-17 老闆指示整格刪掉:
                分店根本不需要關心單號是多少。紙上那串是「本張簽收單涵蓋的所有撿貨單」,
                不是逐商品對應 —— 拿在手上也指不出哪一項貨是哪一張單來的,定位能力接近零。
                分店真要對照,系統的收貨畫面(wms/inbound 的收貨視窗)本來就會顯示
                「來自撿貨單 WV-xxx」,不必靠這張紙。
                ⛔ 這裡只講「這張紙上為什麼不印」;wave_code 在別的頁面怎麼用不是本頁的事,
                  也不要在這裡替全站下斷語(前一版就是這樣寫錯了)。
                分店要定位改看「店家＋訂單日＋出貨日」:同一天、同一家店就是這一張。
                ⚠ 連帶收掉了「單號獨佔一整行」那一圈外層 div —— 那圈是上一版為了讓單號不被折行
                  才加的,單號沒了就沒有存在意義,留著只會多一層空殼。
                三個短欄位並排;放不下就自己換行,不去擠壓彼此。
                ⚠ min-w-0 / max-w-full / break-* 是給極端值用的:flex item 預設 min-width:auto,
                  沒有 min-w-0 就縮不到內容寬度以下,超長店名或超長店號會直接把 A4 撐破。
                  店號用 break-all(整串沒有空白也沒有斷點),其餘用 break-words。 */}
            <div className="mb-2 flex flex-wrap gap-x-8 gap-y-1 text-sm">
              <div className="flex min-w-0 max-w-full">
                <span className="w-16 shrink-0 text-zinc-500">店家</span>
                <span className="min-w-0 break-words font-semibold">
                  {sheet.store.name}
                  {sheet.store.code && (
                    <span className="ml-2 break-all font-mono text-xs text-zinc-500">({sheet.store.code})</span>
                  )}
                </span>
              </div>
              <div className="flex min-w-0 max-w-full">
                <span className="w-16 shrink-0 text-zinc-500">訂單日</span>
                <span className="min-w-0 break-words font-mono">{sheet.orderDates.join("、") || "—"}</span>
              </div>
              <div className="flex min-w-0 max-w-full">
                <span className="w-16 shrink-0 text-zinc-500">出貨日</span>
                <span className="min-w-0 break-words font-mono">{sheet.waveDates.join("、") || date}</span>
              </div>
            </div>

            {/* 商品表 — 編號 / 商品名稱 / 數量 / 單價 / 小計（＋點收框）*/}
            <table className="w-full border-collapse text-sm">
              <thead>
                {/* 店名列 —— 2026-08-18 老闆指示新增。解決的是「一次列印很多家店，某家店品項多到
                    印成兩張紙時，第二張紙上完全看不出是哪一間分店」：樓下拿到那疊紙分不出來。
                    ⭐ 為什麼放在 thead 裡（這是本列存在的全部理由，搬走就失效）：
                      列印分頁時瀏覽器會把 thead 的每一列**在每一頁重新印一次**。
                      底下「編號 / 商品名稱 / …」那一列本來就靠這個機制在第二頁重現，
                      把店名塞進同一個 thead，它就跟著一起被重複。
                      ⛔ 所以絕對不可以搬到 <table> 外面、或搬進 tbody —— 那樣就只有第一頁看得到，
                        等於這個功能沒做。
                    ⛔ 刻意**不做頁碼**（老闆 2026-08-18 明確否決）：頁碼只講「第 2 頁」不講是誰的
                      第 2 頁，分不出分店；而且自製頁碼在使用者調列印縮放時會印出說謊的數字。
                    ⚠ colSpan 必須等於本表欄數（目前 6：編號 / 商品名稱 / 數量 / 單價 / 小計 / 點收）。
                      日後增減欄位這裡要一起改，否則表格會錯位 —— 錯位的後果是金額印到別欄。
                    ⚠ 第一頁會同時看到這一列和上面表頭區的「店家」那一格，是老闆看過版面後
                      裁示「先留著兩個」（改動最小、不動他熟悉的版面），不是漏刪。
                    ⚠ 字級 text-sm 只作用在這一列（新增的元素）；上面表頭區與底下欄位名稱列
                      一個字級都沒有動。
                    ⭐ `leading-4 py-0` 是量出來的，不是隨手寫的 —— 老闆非常在意浪費紙：
                      吃掉高度的其實是**行高**，不是字級。text-sm 預設行高 20px，
                      壓成 16px（＝text-xs 的預設行高）再把上下內距歸零之後，
                      這一列剛好塞得進原本的空隙：A4 第一頁仍然放得下 35 樣品項，
                      跟 origin/main **一模一樣**，一張紙都沒有多花。
                      ⛔ 別「順手」把 leading-4 拿掉或把 py 加回來：實測 text-sm+py-0.5、
                        text-xs+py-0.5、text-base 等版本都會讓第一頁少放 1 樣，
                        剛好 35 樣的店就會從 1 張變回 2 張 —— 那正是老闆上一輪
                        刪簽名區才換來的。（八種寫法的逐格頁數見 v8_字級取捨量測報告.txt） */}
                <tr className="bg-zinc-100">
                  <th
                    colSpan={6}
                    className="border border-zinc-400 px-2 py-0 text-left text-sm font-bold leading-4"
                  >
                    {sheet.store.name}
                    {sheet.store.code && (
                      <span className="ml-2 break-all font-mono text-xs font-normal text-zinc-500">
                        ({sheet.store.code})
                      </span>
                    )}
                  </th>
                </tr>
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
                  {/* 點收欄 —— 2026-08-18 老闆指示：**框線留著、格子裡的東西刪掉**。
                      「點收」兩個字與底下每一格的「□」都拿掉，只留一個空的窄格子讓人手寫打勾。
                      ⛔ th / td 本身絕對不能刪：刪了整張表就變 5 欄，老闆要的是「窄一半」不是「不見」。
                      寬度 w-12(48px) → w-6(24px)，就是老闆講的「窄一半」；實測就是 24px 沒被打折。
                      ⚠ px-2 刻意**不動**。這一欄左右內距共 16px，table-layout:auto 底下欄寬會被
                        min-content 頂住，所以內距是有底線的 —— 但 16px < 24px，還沒頂到，
                        w-6 拿得到完整的 24px（px-2 / px-1 / px-0 三種實測都是 24px）。
                        ⛔ 真正會頂到的是更窄的設定：老闆若之後要「8pt」(10.67px)，
                          光內距就比整欄寬，那時**才**必須連 px 一起縮，不然寫了也縮不下去
                          （只改寬度實測停在 17px；對照與量測見 v7 那份三種寬度對照頁）。
                      ⚠ 拿掉 whitespace-nowrap / text-center / text-xs / font-semibold：
                        那四個都只作用在文字上，格子空了就是死 class。 */}
                  <th className="w-6 border border-zinc-400 px-2 py-1" />
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
                    {/* 點收欄：空格子（見表頭那段說明）。px-2 py-0.5 照舊 —— 這一欄不決定列高，
                        同列的商品名稱那格才決定，所以清空不會讓每一列變矮、表格總高不變（實測列高
                        before / after 都是 25px）。 */}
                    <td className="border border-zinc-400 px-2 py-0.5" />
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

            {/* ⛔ 這裡原本有整個簽名區（收貨人簽名 / 日期、送貨人，兩組「簽名＿＿ 日期＿＿」底線），
                以及最後一行「※ 收到請逐項點收…」的說明。2026-08-18 老闆指示通通刪掉。
                那一區是純靜態版面（沒有綁任何資料），拿掉不影響任何一格數字；
                它佔掉的高度是死的（mt-8 ＋ 兩行 mt-12 的留白 ＋ mt-6 的說明），每張簽收單都白吃一段：
                實測 41.2mm ≈ 6.2 列，A4 第一頁放得下的品項從 30 列變成 36 列，
                30～35 樣的店因此從印兩張變成印一張。
                ⛔ 只有版面被刪掉，`sheet.hasMissingPrice` 那句缺價提示要留著 ——
                  它跟金額有關（哪些品項沒被算進合計），不是簽名區的一部分。 */}
          </div>
        ))}
      </div>
    </>
  );
}
