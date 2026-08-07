"use client";

// 每日進貨對帳單列印 — A4，版型對齊月結對帳單列印（finance/receivables/print）。
// query params:
//   date:     YYYY-MM-DD（必填）
//   store_id: 分店 id；或 "all" = 全部分店依倉別各印一張（自動分頁）
//
// 總倉／HQ 帳號在控制列可切「單店 ↔ 全部分店（依倉別）」，並勾選要印哪些倉別；
// 分店帳號印自己店（RPC 端有 gate，就算改網址也拿不到別店資料）。
// 資料同頁面版：rpc_store_inbound_day_items，金額口徑與月結對帳單一致。

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { getTenantName } from "@/lib/tenant";
import { useAuth } from "@/components/AuthProvider";
import SpinButton from "@/components/SpinButton";

type StoreRow = { id: number; name: string; location_id: number | null };

type DayItem = {
  transfer_id: number;
  transfer_no: string | null;
  transfer_item_id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  qty: number;
  unit_branch_price: number;
  amount: number;
  entry_type: "hq_inbound" | "air_in" | "air_out" | "free_in" | "free_out" | "return_out";
  description: string | null;
  missing_price: boolean;
  received_at: string;
};
type DayDetail = { store_id: number; store_name: string; date: string; items: DayItem[]; total: number };

const ENTRY_TYPE_LABEL: Record<DayItem["entry_type"], string> = {
  hq_inbound: "總倉進貨",
  air_in: "空中轉入",
  air_out: "空中轉出",
  free_in: "自由轉入",
  free_out: "自由轉出",
  return_out: "退貨沖回",
};

const money = (n: number) =>
  `${Number(n) < 0 ? "-" : ""}$${Math.abs(Number(n)).toLocaleString("zh-TW", { maximumFractionDigits: 0 })}`;
const qtyText = (n: number) => Number(n).toLocaleString("zh-TW", { maximumFractionDigits: 3 });

function weekday(dateStr: string) {
  const wd = ["日", "一", "二", "三", "四", "五", "六"];
  return wd[new Date(`${dateStr}T00:00:00Z`).getUTCDay()];
}

export default function DailyInboundPrintPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const sp = useSearchParams();
  const { user, tenant } = useAuth();
  const tenantName = tenant?.name ?? getTenantName();

  const date = sp.get("date") ?? "";
  const storeIdParam = sp.get("store_id") ?? "";
  const singleStoreId = /^\d+$/.test(storeIdParam) ? Number(storeIdParam) : null;

  // 與每日對帳頁同一套判斷：stores metadata 含「總倉」或沒綁店（legacy admin）= HQ
  const isHq = useMemo(() => {
    const userStores = user?.app_metadata?.stores as unknown;
    if (!Array.isArray(userStores) || userStores.length === 0) return true;
    return userStores.includes("總倉");
  }, [user]);

  const [mode, setMode] = useState<"single" | "all">(storeIdParam === "all" ? "all" : "single");
  const [stores, setStores] = useState<StoreRow[] | null>(null);
  const [single, setSingle] = useState<DayDetail | null>(null);
  // all 模式：store_id → 明細（null = 查失敗/無權，先塞 undefined 表示載入中）
  const [allDetails, setAllDetails] = useState<Map<number, DayDetail | null> | null>(null);
  const [checked, setChecked] = useState<Set<number>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const autoPrinted = useRef(false);

  const paramError = !date
    ? "缺 date 參數"
    : singleStoreId === null && storeIdParam !== "all"
      ? "缺 store_id 參數"
      : null;

  // 店名清單（all 模式的勾選列表；順序 = 每日對帳頁的店序）
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .not("location_id", "is", null)
        .order("name");
      if (!cancelled) setStores((data ?? []) as StoreRow[]);
    })();
    return () => { cancelled = true; };
  }, []);

  // 單店明細
  useEffect(() => {
    if (paramError || singleStoreId === null) return;
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase().rpc("rpc_store_inbound_day_items", {
        p_store_id: singleStoreId,
        p_date: date,
      });
      if (cancelled) return;
      if (e) { setErr(e.message); return; }
      setSingle(data as unknown as DayDetail);
    })();
    return () => { cancelled = true; };
  }, [paramError, singleStoreId, date]);

  // all 模式：逐店抓當日明細（無權/失敗的店略過，分店帳號誤入也只會印到自己店）
  useEffect(() => {
    if (paramError || mode !== "all" || !stores || allDetails !== null) return;
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const results = await Promise.all(
        stores.map(async (s) => {
          const { data, error: e } = await sb.rpc("rpc_store_inbound_day_items", {
            p_store_id: s.id,
            p_date: date,
          });
          return [s.id, e ? null : (data as unknown as DayDetail)] as const;
        })
      );
      if (cancelled) return;
      const map = new Map<number, DayDetail | null>(results);
      setAllDetails(map);
      // 預設勾選：當日有明細的倉別
      setChecked(new Set(stores.filter((s) => (map.get(s.id)?.items.length ?? 0) > 0).map((s) => s.id)));
    })();
    return () => { cancelled = true; };
  }, [paramError, mode, stores, allDetails, date]);

  // PDF 存檔預設檔名
  useEffect(() => {
    const label = mode === "all" ? "全部分店" : single?.store_name;
    if (!label) return;
    const original = document.title;
    document.title = `每日進貨對帳_${label}_${date}`;
    return () => { document.title = original; };
  }, [mode, single, date]);

  // 單店：資料到手自動跳列印（同轉貨單列印慣例）。all 模式讓使用者先勾倉別。
  useEffect(() => {
    if (mode !== "single" || !single || autoPrinted.current) return;
    autoPrinted.current = true;
    const t = setTimeout(() => window.print(), 400);
    return () => clearTimeout(t);
  }, [mode, single]);

  if (paramError) return <div className="p-6 text-sm text-red-700">{paramError}</div>;
  if (err) return <div className="p-6 text-sm text-red-700">{err}</div>;

  const loadedCount = allDetails?.size ?? 0;
  const allLoading = mode === "all" && (!stores || allDetails === null);
  const sheets: DayDetail[] =
    mode === "single"
      ? single ? [single] : []
      : (stores ?? [])
          .filter((s) => checked.has(s.id))
          .map((s) => allDetails?.get(s.id))
          .filter((d): d is DayDetail => !!d && d.items.length > 0);

  return (
    <>
      <style jsx global>{`
        @media print {
          @page { size: A4; margin: 10mm; }
          .no-print { display: none !important; }
          .sheet { page-break-after: always; }
          .sheet:last-child { page-break-after: auto; }
          body { background: white !important; }
          .stmt-table { font-size: 10px; }
          .stmt-table th, .stmt-table td { padding: 2px 4px; }
          .stmt-table thead { display: table-header-group; }
          .stmt-table tr { break-inside: avoid; }
        }
      `}</style>

      <div className="min-h-screen bg-zinc-100 text-zinc-900 print:bg-white">
        {/* 控制列（列印時隱藏） */}
        <div className="no-print sticky top-0 z-20 border-b border-zinc-200 bg-zinc-50 p-3">
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="text-base font-semibold">每日進貨對帳單列印</h1>
            <span className="text-sm text-zinc-500">
              {date}（{weekday(date)}）
              {mode === "single" && single && ` / ${single.store_name} / ${money(single.total)}`}
            </span>
            {isHq && (
              <div className="flex overflow-hidden rounded-md border border-zinc-300 text-sm">
                {singleStoreId !== null && (
                  <SpinButton
                    onClick={() => setMode("single")}
                    className={`px-3 py-1.5 ${mode === "single" ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
                  >
                    單店
                  </SpinButton>
                )}
                <SpinButton
                  onClick={() => setMode("all")}
                  className={`px-3 py-1.5 ${mode === "all" ? "bg-zinc-900 font-semibold text-white" : "bg-white text-zinc-600 hover:bg-zinc-100"}`}
                >
                  全部分店（依倉別）
                </SpinButton>
              </div>
            )}
            <SpinButton
              onClick={() => window.print()}
              disabled={sheets.length === 0}
              className="ml-auto rounded-md bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
            >
              🖨️ 列印{mode === "all" ? `（${sheets.length} 張）` : ""}
            </SpinButton>
            <SpinButton
              onClick={() => window.close()}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-100"
            >
              關閉
            </SpinButton>
          </div>

          {/* all 模式：倉別勾選列表 */}
          {mode === "all" && (
            <div className="mt-2">
              {allLoading ? (
                <p className="text-xs text-zinc-500">
                  載入各倉別明細中…（{loadedCount}/{stores?.length ?? "?"}）
                </p>
              ) : (
                <div className="flex flex-wrap items-center gap-x-4 gap-y-1">
                  <span className="text-xs text-zinc-500">要印的倉別：</span>
                  {(stores ?? []).map((s) => {
                    const d = allDetails?.get(s.id);
                    const has = (d?.items.length ?? 0) > 0;
                    return (
                      <label
                        key={s.id}
                        className={`flex items-center gap-1 text-xs ${has ? "" : "text-zinc-400"}`}
                      >
                        <input
                          type="checkbox"
                          disabled={!has}
                          checked={checked.has(s.id)}
                          onChange={(e) => {
                            setChecked((prev) => {
                              const next = new Set(prev);
                              if (e.target.checked) next.add(s.id); else next.delete(s.id);
                              return next;
                            });
                          }}
                        />
                        {s.name}
                        {has ? (
                          <span className="font-mono text-zinc-500">{money(d!.total)}</span>
                        ) : (
                          <span>（{d === null ? "無權限" : "無資料"}）</span>
                        )}
                      </label>
                    );
                  })}
                </div>
              )}
            </div>
          )}
        </div>

        {/* 對帳單內容：每個倉別一張，列印自動分頁 */}
        {mode === "single" && !single ? (
          <div className="p-6 text-sm text-zinc-500">載入中…</div>
        ) : sheets.length === 0 && !allLoading ? (
          <div className="p-6 text-sm text-zinc-500">
            {mode === "all" ? "沒有可列印的倉別（當日皆無明細或未勾選）。" : "當日無明細。"}
          </div>
        ) : (
          sheets.map((d) => <Sheet key={d.store_id} detail={d} tenantName={tenantName} />)
        )}
      </div>
    </>
  );
}

function Sheet({ detail, tenantName }: { detail: DayDetail; tenantName: string }) {
  const today = new Date().toLocaleDateString("zh-TW");
  return (
    <div className="sheet mx-auto my-6 max-w-[210mm] border border-zinc-300 bg-white p-8 print:my-0 print:border-0 print:p-0">
      {/* 表頭 */}
      <div className="mb-4 flex items-start justify-between border-b-2 border-zinc-900 pb-3">
        <div>
          <div className="text-xl font-bold">每日進貨對帳單</div>
          {tenantName && <div className="mt-0.5 text-xs text-zinc-500">{tenantName}</div>}
        </div>
        <div className="text-right text-sm">
          <div>
            進貨日期：
            <span className="font-mono font-semibold">
              {detail.date}（{weekday(detail.date)}）
            </span>
          </div>
          <div className="mt-0.5 text-xs text-zinc-500">列印日：{today}</div>
        </div>
      </div>

      {/* 分店 + 當日合計 */}
      <div className="mb-4 grid grid-cols-2 gap-4 text-sm">
        <div>
          <div className="text-xs text-zinc-500">分店（倉別）</div>
          <div className="text-lg font-semibold">{detail.store_name}</div>
        </div>
        <div className="text-right">
          <div className="text-xs text-zinc-500">當日進貨金額（分店價）</div>
          <div className="text-lg font-semibold text-rose-600">{money(detail.total)}</div>
          <div className="mt-0.5 text-xs text-zinc-500">{detail.items.length} 個品項</div>
        </div>
      </div>

      {/* 明細表 */}
      <table className="stmt-table w-full border-collapse text-xs">
        <thead>
          <tr className="border-b-2 border-zinc-900">
            <th className="border border-zinc-400 px-2 py-1.5 text-left">#</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left">品名</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left">商品編號</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left">類別</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-right">數量</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-right">分店價</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-right">小計</th>
            <th className="border border-zinc-400 px-2 py-1.5 text-left">單號</th>
          </tr>
        </thead>
        <tbody>
          {detail.items.map((it, i) => {
            const isFree = it.entry_type === "free_in" || it.entry_type === "free_out";
            return (
              <tr key={`${it.entry_type}-${it.transfer_item_id}`}>
                <td className="border border-zinc-400 px-2 py-1">{i + 1}</td>
                <td className="border border-zinc-400 px-2 py-1">
                  {it.product_name ?? `SKU #${it.sku_id}`}
                  {it.variant_name && <span className="ml-1 text-zinc-500">/ {it.variant_name}</span>}
                  {it.missing_price && <span className="ml-1 font-semibold">（未設分店價）</span>}
                </td>
                <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">{it.sku_code ?? "—"}</td>
                <td className="border border-zinc-400 px-2 py-1 whitespace-nowrap">{ENTRY_TYPE_LABEL[it.entry_type]}</td>
                <td className="border border-zinc-400 px-2 py-1 text-right font-mono">{qtyText(it.qty)}</td>
                <td className="border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap">
                  {isFree ? "估價" : money(it.unit_branch_price)}
                </td>
                <td className={`border border-zinc-400 px-2 py-1 text-right font-mono whitespace-nowrap ${it.amount < 0 ? "text-amber-600" : ""}`}>
                  {money(it.amount)}
                </td>
                <td className="border border-zinc-400 px-2 py-1 font-mono whitespace-nowrap">
                  {it.transfer_no ?? `#${it.transfer_id}`}
                </td>
              </tr>
            );
          })}
          <tr className="bg-zinc-100 font-semibold">
            <td colSpan={6} className="border border-zinc-400 px-2 py-1.5 text-right">當日合計</td>
            <td className="border border-zinc-400 px-2 py-1.5 text-right font-mono whitespace-nowrap text-rose-600">
              {money(detail.total)}
            </td>
            <td className="border border-zinc-400 px-2 py-1.5"></td>
          </tr>
        </tbody>
      </table>

      {/* 說明 */}
      <div className="mt-3 text-[10px] text-zinc-500">
        ※ 金額為分店價（總倉賣斷給分店的價格），口徑與月結對帳單相同；空中轉出／退貨沖回為負值。
        自由轉入／轉出以轉貨時申報的估價入帳。正式應付金額以每月的月結對帳單為準。
      </div>

      {/* 簽收區 */}
      <div className="mt-8 grid grid-cols-2 gap-8 text-sm">
        <div>
          <div className="text-xs text-zinc-500">分店確認 / 日期</div>
          <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
            簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
          </div>
        </div>
        <div>
          <div className="text-xs text-zinc-500">總倉確認 / 日期</div>
          <div className="mt-12 border-t border-zinc-900 pt-1 text-xs text-zinc-500">
            簽名 ＿＿＿＿＿＿＿＿　日期 ＿＿＿＿＿＿
          </div>
        </div>
      </div>
    </div>
  );
}
