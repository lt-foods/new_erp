"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { useRole, canSeeBranch } from "@/lib/role";
import { useUserBranchStoreId } from "@/lib/useDefaultStoreFromUser";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";

type Store = { id: number; code: string; name: string };

type MemberHit = {
  id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  home_store_name: string | null;
};

type SkuOption = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  product_id: number;
  product_name: string;
  retail_price: number | null;
  branch_price: number | null;
};

type Line = {
  sku_id: number | null;
  product_name: string;
  variant_name: string | null;
  sku_code: string;
  qty: string;
  unit_price: string;
  notes: string;
};

const emptyLine = (): Line => ({
  sku_id: null,
  product_name: "",
  variant_name: null,
  sku_code: "",
  qty: "1",
  unit_price: "0",
  notes: "",
});

export default function RestockNewPage() {
  const router = useRouter();
  const role = useRole();
  const showBranch = canSeeBranch(role);

  const [stores, setStores] = useState<Store[]>([]);
  const [storeId, setStoreId] = useState<number | null>(null);
  const [lines, setLines] = useState<Line[]>([emptyLine()]);
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 訂購會員：null = 預設掛店內部會員(【內部】xx店)；指定真會員則貨到即該會員可取貨
  const [member, setMember] = useState<MemberHit | null>(null);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const { data: storeData } = await sb
        .from("stores").select("id, code, name").eq("is_active", true).order("code");
      setStores((storeData ?? []) as Store[]);
    })();
  }, []);

  // 分店 role 未手動選店時自動帶自己店（app_metadata.stores 店名比對；JWT 沒有 store_id claim）
  const branchStoreId = useUserBranchStoreId(stores);
  const effectiveStoreId = storeId ?? branchStoreId;

  const setLine = <K extends keyof Line>(idx: number, key: K, value: Line[K]) => {
    setLines((arr) => arr.map((l, i) => (i === idx ? { ...l, [key]: value } : l)));
  };
  const addLine = () => setLines((arr) => [...arr, emptyLine()]);
  const removeLine = (idx: number) => setLines((arr) => arr.filter((_, i) => i !== idx));

  const valid =
    effectiveStoreId !== null &&
    lines.length > 0 &&
    lines.every((l) => l.sku_id !== null && Number(l.qty) > 0 && Number(l.unit_price) >= 0);

  async function handleSubmit() {
    setError(null);
    if (!valid || effectiveStoreId === null) {
      setError("請選分店、每行需挑商品 + 填數量");
      return;
    }
    setBusy(true);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_create_restock_request", {
        p_store_id: effectiveStoreId,
        p_lines: lines.map((l) => ({
          sku_id: l.sku_id,
          qty: Number(l.qty),
          unit_price: Number(l.unit_price),
          notes: l.notes.trim() || null,
        })),
        p_notes: notes.trim() || null,
        p_member_id: member?.id ?? null,
      });
      if (err) throw err;
      router.push(`/restock?id=${Number(data)}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">補貨申請</h1>
        {/* ⚠ 原本寫「HQ 會選擇派庫存或進貨」，會讓分店以為 HQ 一按就出貨。
            2026-06-12 起「派」那條只是排進派貨工作台（rpc_approve_restock_to_transfer
            最新版 20260714000040:260-270 只改狀態、貨不動），所以要講明核可 ≠ 已出貨。 */}
        <p className="text-sm text-zinc-500">針對既有上架商品向 HQ 叫貨；HQ 核可後，會用總倉庫存派貨或另外向供應商訂貨 —— 核可不等於已出貨</p>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <label className="flex flex-col gap-1 text-sm sm:max-w-md">
        <span className="text-zinc-600 dark:text-zinc-400">收貨分店 *</span>
        <select value={effectiveStoreId ?? ""} onChange={(e) => setStoreId(Number(e.target.value) || null)} className={inputCls}>
          <option value="">— 請選 —</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>{s.code} {s.name}</option>
          ))}
        </select>
      </label>

      <MemberField
        member={member}
        onChange={setMember}
        inputCls={inputCls}
        storeName={stores.find((s) => s.id === effectiveStoreId)?.name ?? null}
      />


      <div className="rounded-md border border-zinc-200 dark:border-zinc-800">
        <table className="w-full text-sm">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
              <th className="px-3 py-2">商品 / 規格 *</th>
              <th className="px-3 py-2 text-right">數量 *</th>
              <th className="px-3 py-2 text-right">單價</th>
              <th className="px-3 py-2">備註</th>
              <th className="px-3 py-2"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
            {lines.map((l, i) => (
              <LineRow
                key={i}
                line={l}
                storeId={effectiveStoreId}
                showBranch={showBranch}
                onChange={(patch) => setLines((arr) => arr.map((x, j) => (j === i ? { ...x, ...patch } : x)))}
                onRemove={lines.length > 1 ? () => removeLine(i) : null}
              />
            ))}
          </tbody>
        </table>
        <div className="border-t border-zinc-200 p-2 dark:border-zinc-800">
          <SpinButton onClick={addLine} className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800">
            + 新增一行
          </SpinButton>
        </div>
      </div>

      <label className="flex flex-col gap-1 text-sm">
        <span className="text-zinc-600 dark:text-zinc-400">整單備註 / 用途說明</span>
        <textarea value={notes} onChange={(e) => setNotes(e.target.value)} className={`${inputCls} min-h-16`} placeholder="（選填，例如：週末活動需求 / 庫存不足等）" />
      </label>

      <div className="flex gap-2">
        <SpinButton onClick={handleSubmit} disabled={busy || !valid} className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900">
          {busy ? "送出中…" : "送出申請"}
        </SpinButton>
        <SpinButton onClick={() => router.back()} disabled={busy} className="rounded-md border border-zinc-300 px-4 py-2 text-sm dark:border-zinc-700">取消</SpinButton>
      </div>
    </div>
  );
}

// 訂購會員欄：預設已選【內部】該店（送出 p_member_id=null、RPC 端解析內部會員）；
// 點「指定會員」切到搜尋，指定真會員＝貨到即該會員的可取貨訂單（單價鎖現售價）
function MemberField({
  member,
  onChange,
  inputCls,
  storeName,
}: {
  member: MemberHit | null;
  onChange: (m: MemberHit | null) => void;
  inputCls: string;
  storeName: string | null;
}) {
  const [picking, setPicking] = useState(false);
  const [term, setTerm] = useState("");
  const [hits, setHits] = useState<MemberHit[]>([]);
  const [searching, setSearching] = useState(false);
  const wrapRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!picking) return;
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setPicking(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [picking]);

  useEffect(() => {
    if (!picking) {
      setSearching(false);
      return;
    }
    setSearching(true);
    const t = setTimeout(async () => {
      try {
        const { data } = await getSupabase().rpc("rpc_search_members", {
          p_term: term,
          p_limit: 10,
        });
        setHits((data as MemberHit[] | null) ?? []);
      } finally {
        setSearching(false);
      }
    }, 200);
    return () => clearTimeout(t);
  }, [term, picking]);

  const chipCls =
    "flex items-center justify-between gap-2 rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800";
  const btnCls =
    "shrink-0 rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-700";

  return (
    <div ref={wrapRef} className="relative flex flex-col gap-1 text-sm sm:max-w-md">
      <span className="text-zinc-600 dark:text-zinc-400">訂購會員</span>
      {member ? (
        // 已指定真會員
        <div className={chipCls}>
          <div className="min-w-0 flex-1 text-sm">
            <span className="font-medium">{member.name ?? "—"}</span>
            <span className="ml-2 font-mono text-xs text-zinc-500">{member.member_no}</span>
          </div>
          <SpinButton type="button" onClick={() => { onChange(null); setTerm(""); setPicking(false); }} className={btnCls}>
            改回內部
          </SpinButton>
        </div>
      ) : picking ? (
        // 搜尋模式
        <div className="relative">
          <input
            autoFocus
            value={term}
            onChange={(e) => setTerm(e.target.value)}
            placeholder="搜尋 會員編號 / 姓名 / 手機"
            className={`${inputCls} w-full pr-8`}
          />
          <SearchSpinner active={searching} />
        </div>
      ) : (
        // 預設：已選內部該店（送出 p_member_id=null，RPC 端解析/自動建立內部會員）
        <div className={chipCls}>
          <div className="min-w-0 flex-1 text-sm">
            <span className="font-medium">【內部】{storeName ?? "該店"}</span>
            <span className="ml-2 text-xs text-zinc-500">店庫存</span>
          </div>
          <SpinButton type="button" onClick={() => { setPicking(true); setTerm(""); }} className={btnCls}>
            指定會員
          </SpinButton>
        </div>
      )}
      {!member && (
        <p className="text-xs text-zinc-400">
          內部＝貨到掛店庫存，之後再轉單給客人；指定會員＝貨到即為該會員的可取貨訂單（單價鎖現售價）
        </p>
      )}
      {picking && !member && hits.length > 0 && (
        <div className="absolute left-0 top-full z-10 mt-1 max-h-60 w-full overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800">
          {hits.map((h) => (
            <SpinButton
              key={h.id}
              type="button"
              onClick={() => { onChange(h); setPicking(false); setTerm(""); }}
              className="block w-full px-3 py-1.5 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
            >
              <span className="font-medium">{h.name ?? "—"}</span>
              <span className="ml-2 font-mono text-zinc-400">{h.member_no}</span>
              {h.home_store_name && <span className="ml-2 text-zinc-500">{h.home_store_name}</span>}
            </SpinButton>
          ))}
        </div>
      )}
    </div>
  );
}

function LineRow({
  line,
  storeId,
  showBranch,
  onChange,
  onRemove,
}: {
  line: Line;
  storeId: number | null;
  showBranch: boolean;
  onChange: (patch: Partial<Line>) => void;
  onRemove: (() => void) | null;
}) {
  const [open, setOpen] = useState(false);
  const [term, setTerm] = useState("");
  const [opts, setOpts] = useState<SkuOption[]>([]);
  const [searching, setSearching] = useState(false);
  // 選完 SKU 顯示「在途（已派未收）/ 店內現有」— 在途 > 0 提示可能重複申請
  // （2026-08-10 松山案例：貨已在途又叫一次，HQ 重複派貨造成短收亂帳）
  // 記住查的是哪個 SKU：換商品時舊資料自然失效，不用同步 reset
  const [incoming, setIncoming] = useState<{ skuId: number; in_transit: number; on_hand: number } | null>(null);
  const shownIncoming = incoming && incoming.skuId === line.sku_id ? incoming : null;

  useEffect(() => {
    if (!line.sku_id || !storeId) return;
    const skuId = line.sku_id;
    let cancelled = false;
    (async () => {
      try {
        const { data } = await getSupabase().rpc("rpc_store_incoming_skus", {
          p_store_id: storeId,
          p_sku_ids: [skuId],
        });
        const row = (data as Array<{ sku_id: number; in_transit: number; on_hand: number }> | null)?.[0];
        if (!cancelled && row) setIncoming({ skuId, in_transit: Number(row.in_transit), on_hand: Number(row.on_hand) });
      } catch {
        // 查不到就不顯示（純提示功能，不擋建單）
      }
    })();
    return () => { cancelled = true; };
  }, [line.sku_id, storeId]);

  useEffect(() => {
    if (!open) {
      setSearching(false);
      return;
    }
    setSearching(true);
    const t = setTimeout(async () => {
      try {
        const sb = getSupabase();
        let q = sb
          .from("skus")
          .select("id, sku_code, variant_name, product_id, products!inner(id, name, is_virtual)")
          .eq("status", "active")
          .eq("products.is_virtual", false)
          .limit(15);
        const safe = term.replace(/[%,()]/g, " ").trim();
        if (safe) q = q.or(`sku_code.ilike.%${safe}%,product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%`);
        const { data } = await q;
        const ids = (data ?? []).map((r) => r.id);
        let priceMap = new Map<number, { retail?: number; branch?: number }>();
        if (ids.length > 0) {
          const { data: priceRows } = await sb
            .from("prices")
            .select("sku_id, scope, price")
            .in("sku_id", ids)
            .in("scope", ["retail", "branch"])
            .is("effective_to", null);
          for (const p of (priceRows ?? []) as { sku_id: number; scope: string; price: number }[]) {
            const slot = priceMap.get(p.sku_id) ?? {};
            if (p.scope === "retail" && slot.retail === undefined) slot.retail = Number(p.price);
            if (p.scope === "branch" && slot.branch === undefined) slot.branch = Number(p.price);
            priceMap.set(p.sku_id, slot);
          }
        }
        setOpts(
          ((data ?? []) as unknown as Array<{
            id: number; sku_code: string; variant_name: string | null; product_id: number;
            products: { id: number; name: string; is_virtual: boolean };
          }>).map((s) => ({
            id: s.id, sku_code: s.sku_code, variant_name: s.variant_name,
            product_id: s.product_id, product_name: s.products.name,
            retail_price: priceMap.get(s.id)?.retail ?? null,
            branch_price: priceMap.get(s.id)?.branch ?? null,
          }))
        );
      } finally {
        setSearching(false);
      }
    }, 200);
    return () => clearTimeout(t);
  }, [term, open]);

  return (
    <tr>
      <td className="relative px-3 py-2 align-top">
        {line.sku_id ? (
          <div className="flex items-start justify-between gap-2 rounded border border-zinc-300 bg-white px-2 py-1.5 dark:border-zinc-700 dark:bg-zinc-800">
            <div className="min-w-0 flex-1">
              <div className="break-words text-sm font-medium text-zinc-900 dark:text-zinc-100">{line.product_name}</div>
              <div className="break-words text-xs text-zinc-500">
                {line.variant_name && <span>{line.variant_name}</span>}
                <span className={line.variant_name ? "ml-1 font-mono text-zinc-400" : "font-mono text-zinc-400"}>{line.sku_code}</span>
              </div>
            </div>
            <SpinButton
              type="button"
              onClick={() => {
                onChange({ sku_id: null, product_name: "", variant_name: null, sku_code: "", unit_price: "0" });
                setTerm("");
                setOpen(true);
              }}
              className="shrink-0 rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-700"
            >
              更改
            </SpinButton>
          </div>
        ) : null}
        {line.sku_id && shownIncoming && (
          shownIncoming.in_transit > 0 ? (
            <div className="mt-1 rounded border border-amber-300 bg-amber-50 px-2 py-1 text-[11px] text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-300">
              ⚠ 已有 <span className="font-mono font-semibold">{shownIncoming.in_transit}</span> 件在途（已派未收）
              ・店內現有 <span className="font-mono">{shownIncoming.on_hand}</span> — 確認不是重複申請
            </div>
          ) : (
            <div className="mt-1 text-[11px] text-zinc-400">
              在途 0・店內現有 <span className="font-mono">{shownIncoming.on_hand}</span>
            </div>
          )
        )}
        {!line.sku_id && (
          <>
            <input
              value={term}
              onFocus={() => setOpen(true)}
              onChange={(e) => {
                setTerm(e.target.value);
                setOpen(true);
              }}
              placeholder="搜尋商品 / 品項"
              className="w-full rounded border border-zinc-300 bg-white px-2 py-1 pr-8 text-sm dark:border-zinc-700 dark:bg-zinc-800"
            />
            <SearchSpinner active={searching} />
          </>
        )}
        {open && !line.sku_id && opts.length > 0 && (
          <div className="absolute left-0 top-full z-10 mt-1 max-h-60 w-96 overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800" onMouseLeave={() => setOpen(false)}>
            {opts.map((o) => {
              const price = showBranch && o.branch_price !== null ? o.branch_price : o.retail_price ?? 0;
              return (
                <SpinButton
                  key={o.id}
                  type="button"
                  onClick={() => {
                    onChange({
                      sku_id: o.id,
                      product_name: o.product_name,
                      variant_name: o.variant_name,
                      sku_code: o.sku_code,
                      unit_price: String(price),
                    });
                    setOpen(false); setTerm("");
                  }}
                  className="block w-full px-2 py-1 text-left text-xs hover:bg-zinc-100 dark:hover:bg-zinc-700"
                >
                  <span className="font-medium">{o.product_name}</span>
                  {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
                  <span className="ml-2 font-mono text-zinc-400">{o.sku_code}</span>
                  <span className="ml-2 text-zinc-600 dark:text-zinc-300">${price}</span>
                </SpinButton>
              );
            })}
          </div>
        )}
      </td>
      <td className="px-3 py-2 align-top"><input type="number" min="0" step="1" value={line.qty} onChange={(e) => onChange({ qty: e.target.value })} className="w-24 rounded border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800" /></td>
      <td className="px-3 py-2 text-right align-top font-mono text-sm text-zinc-700 dark:text-zinc-300"><span className="inline-block py-1">${line.unit_price}</span></td>
      <td className="px-3 py-2 align-top"><input value={line.notes} onChange={(e) => onChange({ notes: e.target.value })} placeholder="（選填）" className="w-full rounded border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800" /></td>
      <td className="px-3 py-2 align-top">
        {onRemove && (
          <SpinButton onClick={onRemove} className="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400">移除</SpinButton>
        )}
      </td>
    </tr>
  );
}
