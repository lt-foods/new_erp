"use client";

// 現場銷售「結帳時補庫存」稽核紀錄。
//
// 為什麼要有這一頁：結帳畫面上的「架上有貨 → 先補 N 件庫存」是全站少數
// **憑空生庫存**的入口。它解掉了店員的真實困境（貨在架上、帳上沒有、客人就站
// 在櫃台前），但沒有人看得到補了多少的話，權宜之計會變成日常，帳與實體越差
// 越遠而完全沒有訊號 —— CLAUDE.md 記過的幽靈庫存災情都是這個形狀。
//
// 這一頁就是那個訊號面板：同一家店天天在補 = 帳跟實體長期脫節，該排盤點。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { translateRpcError } from "@/lib/rpcError";
import { useUserBranchStoreId, useDefaultStoreFromUser } from "@/lib/useDefaultStoreFromUser";

type StoreRow = { id: number; name: string; location_id: number | null };

type SummaryRow = {
  ymd: string;
  store_id: number;
  store_name: string;
  movements: number;
  qty: number;
  skus: number;
  operators: number;
  orders: number;
};

type DetailRow = {
  movement_id: number;
  created_at: string;
  store_name: string;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  qty: number;
  unit_cost: number | null;
  order_no: string | null;
  operator_id: string | null;
};

// 日界跟 RPC 一樣切在台北，不然「今天」在午夜前後兩邊會對不上
function taipeiDate(offsetDays = 0): string {
  return new Date(Date.now() + 8 * 3600 * 1000 - offsetDays * 86400000).toISOString().slice(0, 10);
}

function label(r: DetailRow): string {
  const a = (r.product_name ?? "").trim();
  const b = (r.variant_name ?? "").trim();
  if (a && b && a !== b) return `${a} / ${b}`;
  return a || b || r.sku_code || "—";
}

export default function PosTopupsPage() {
  const [stores, setStores] = useState<StoreRow[]>([]);
  const [pickedStoreId, setPickedStoreId] = useState<string>("");
  const branchStoreId = useUserBranchStoreId(stores);
  // 分店帳號鎖自己店（衍生值，不在 effect 裡 setState）
  const storeId = branchStoreId != null ? String(branchStoreId) : pickedStoreId;
  useDefaultStoreFromUser(stores, pickedStoreId, setPickedStoreId, branchStoreId == null);

  const [from, setFrom] = useState(taipeiDate(30));
  const [to, setTo] = useState(taipeiDate(0));
  const [summary, setSummary] = useState<SummaryRow[] | null>(null);
  const [rows, setRows] = useState<DetailRow[] | null>(null);
  const [qtyTotal, setQtyTotal] = useState(0);
  const [rowsTotal, setRowsTotal] = useState(0);
  const [staffNames, setStaffNames] = useState<Map<string, string>>(new Map());
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase()
        .from("stores")
        .select("id, name, location_id")
        .eq("is_active", true)
        .order("name");
      if (cancelled) return;
      if (e) setError(e.message);
      else setStores((data as StoreRow[]) ?? []);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      const { data, error: e } = await sb.rpc("rpc_walkin_stock_topups", {
        p_store_id: storeId ? Number(storeId) : null,
        p_date_from: from || null,
        p_date_to: to || null,
      });
      if (cancelled) return;
      if (e) {
        setError(translateRpcError(e));
        setSummary([]);
        setRows([]);
        return;
      }
      setError(null);
      const d = (data ?? {}) as Record<string, unknown>;
      const rs = (d.rows as DetailRow[]) ?? [];
      setSummary((d.summary as SummaryRow[]) ?? []);
      setRows(rs);
      setQtyTotal(Number(d.qty_total ?? 0));
      setRowsTotal(Number(d.rows_total ?? 0));

      const uids = Array.from(new Set(rs.map((r) => r.operator_id).filter((x): x is string => !!x)));
      if (uids.length === 0) return;
      const { data: ns } = await sb.rpc("rpc_get_staff_names", { p_uids: uids });
      if (cancelled) return;
      const m = new Map<string, string>();
      for (const n of (ns as { id: string; display_name: string }[] | null) ?? []) {
        m.set(n.id, n.display_name);
      }
      setStaffNames(m);
    })();
    return () => {
      cancelled = true;
    };
  }, [storeId, from, to]);

  // 區間內補過幾天 —— 天數多＝常態性補帳，那是盤點問題，不是結帳問題
  const busyStores = useMemo(() => {
    const m = new Map<string, { name: string; days: number; qty: number }>();
    for (const s of summary ?? []) {
      const cur = m.get(s.store_name) ?? { name: s.store_name, days: 0, qty: 0 };
      cur.days += 1;
      cur.qty += Number(s.qty);
      m.set(s.store_name, cur);
    }
    return [...m.values()].filter((x) => x.days >= 3).sort((a, b) => b.qty - a.qty);
  }, [summary]);

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <h1 className="text-lg font-semibold">🧾 現場銷售補庫存紀錄</h1>
        <span className="text-xs text-zinc-500">結帳當下「架上有貨、帳上沒有」而補進來的庫存</span>
        <span className="flex-1" />
        <Link href="/pos" className="text-sm underline">
          ← 回現場銷售
        </Link>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap items-center gap-2 text-sm">
        {branchStoreId == null && (
          <select
            value={pickedStoreId}
            onChange={(e) => setPickedStoreId(e.target.value)}
            className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">全部門市</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        )}
        <input
          type="date"
          value={from}
          onChange={(e) => setFrom(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
        />
        <span className="text-zinc-400">～</span>
        <input
          type="date"
          value={to}
          onChange={(e) => setTo(e.target.value)}
          className="rounded-md border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800"
        />
        <span className="text-xs text-zinc-500">
          共 {rowsTotal} 筆 / {qtyTotal} 件
        </span>
      </div>

      {busyStores.length > 0 && (
        <div className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-900 dark:bg-amber-950/60 dark:text-amber-200">
          這幾家店在這段期間經常要補帳，代表帳跟架上長期對不起來 —— 補帳只是應急，
          該排一次盤點把數字重新對齊：
          <ul className="mt-1 list-inside list-disc">
            {busyStores.map((s) => (
              <li key={s.name}>
                {s.name}：{s.days} 天、共 {s.qty} 件
              </li>
            ))}
          </ul>
          <Link href="/inventory/stocktake" className="mt-1 inline-block underline">
            → 去盤點
          </Link>
        </div>
      )}

      <div>
        <div className="mb-1 text-xs text-zinc-500">依日期 × 分店</div>
        <Table>
          <THead>
            <Tr>
              <Th>日期</Th>
              <Th>分店</Th>
              <Th className="text-right">筆數</Th>
              <Th className="text-right">件數</Th>
              <Th className="text-right">品項數</Th>
              <Th className="text-right">單數</Th>
              <Th className="text-right">操作人</Th>
            </Tr>
          </THead>
          <TBody>
            {summary === null ? (
              <LoadingRow colSpan={7} />
            ) : summary.length === 0 ? (
              <EmptyRow colSpan={7}>這段期間沒有補庫存紀錄 👍</EmptyRow>
            ) : (
              summary.map((s) => (
                <Tr key={`${s.ymd}-${s.store_id}`}>
                  <Td>{s.ymd}</Td>
                  <Td>{s.store_name}</Td>
                  <Td className="text-right tabular-nums">{s.movements}</Td>
                  <Td className="text-right font-semibold tabular-nums">{Number(s.qty)}</Td>
                  <Td className="text-right tabular-nums">{s.skus}</Td>
                  <Td className="text-right tabular-nums">{s.orders}</Td>
                  <Td className="text-right tabular-nums">{s.operators}</Td>
                </Tr>
              ))
            )}
          </TBody>
        </Table>
      </div>

      <div>
        <div className="mb-1 text-xs text-zinc-500">明細（最多 500 筆，新到舊）</div>
        <Table>
          <THead>
            <Tr>
              <Th>時間</Th>
              <Th>分店</Th>
              <Th>商品</Th>
              <Th className="text-right">補入</Th>
              <Th>單號</Th>
              <Th>操作人</Th>
            </Tr>
          </THead>
          <TBody>
            {rows === null ? (
              <LoadingRow colSpan={6} />
            ) : rows.length === 0 ? (
              <EmptyRow colSpan={6}>沒有紀錄</EmptyRow>
            ) : (
              rows.map((r) => (
                <Tr key={r.movement_id}>
                  <Td className="whitespace-nowrap text-xs">
                    {new Date(r.created_at).toLocaleString("zh-TW", { hour12: false })}
                  </Td>
                  <Td className="whitespace-nowrap">{r.store_name}</Td>
                  <Td>
                    <div className="break-words">{label(r)}</div>
                    {r.sku_code && (
                      <div className="font-mono text-[11px] text-zinc-500">{r.sku_code}</div>
                    )}
                  </Td>
                  <Td className="text-right font-semibold tabular-nums text-amber-700 dark:text-amber-400">
                    +{Number(r.qty)}
                  </Td>
                  <Td className="whitespace-nowrap font-mono text-xs">{r.order_no ?? "—"}</Td>
                  <Td className="whitespace-nowrap text-xs">
                    {r.operator_id ? (staffNames.get(r.operator_id) ?? r.operator_id.slice(0, 8)) : "—"}
                  </Td>
                </Tr>
              ))
            )}
          </TBody>
        </Table>
      </div>
    </div>
  );
}
