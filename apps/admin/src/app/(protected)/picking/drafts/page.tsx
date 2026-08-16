"use client";

// 派貨草稿 — 列表（切片 A）
//
// 這一頁在解什麼（老闆 2026-08-16）：
//   「樓下今天要撿 50 樣商品，如果包子媽突然要插商品進來、或是車子載不下不送了，
//     我就可以先在草稿上修改。確定的出貨商品其實是要等樓下撿完後才能知道。」
//   → 草稿 = 撿貨清單（可改）；派貨工作台 = 出貨清單（建了就成立、會到店）。
//
// ⛔ 草稿完全不扣庫存、不建任何撿貨單／調撥單，也不回寫任何既有表。
//    本檔只讀寫 picking_drafts / picking_draft_items 兩張新表。
//
// 狀態只有兩種（老闆拍板）：進行中(draft) / 已完成(done)，且「已完成」是**手動按**的
// —— 一張草稿可能分兩天用完，系統不自作主張關掉。

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import SpinButton from "@/components/SpinButton";

type Draft = {
  id: number;
  name: string;
  status: "draft" | "done";
  created_at: string;
  updated_at: string;
};

// 列表一次最多列幾張草稿。50 張 × 每張 ~700 列明細 ≈ 3.5 萬列，
// 還在 fetchAllRows 的 50 頁上限（5 萬列）之內，數字不會被靜默截斷算少。
const LIST_LIMIT = 50;

function defaultDraftName() {
  // 老闆的實務是「早上一批、下午一批」→ 預設帶日期，重複也沒關係（不設 unique）
  return `${new Date().toLocaleDateString("sv-SE")} 撿貨`;
}

export default function PickingDraftsPage() {
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [skuCounts, setSkuCounts] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [newName, setNewName] = useState(defaultDraftName);
  const [truncated, setTruncated] = useState(false);

  // ⚠ 第一件事就 await，不在 effect body 同步 setState
  // （react-hooks/set-state-in-effect；錯誤訊息等查完回來再一起更新）
  const load = useCallback(async () => {
    try {
      const sb = getSupabase();
      // 只列最近 LIST_LIMIT 張。刻意**不**撈全部：下面算品項數要把這些草稿的明細
      // 整包拉回來（一張草稿 = 商品數 × 分店數，50 樣 × 十幾家店就 ~700 列），
      // 不設上限的話用久了會變成每次開頁拉好幾萬列。
      const { data, error: err } = await sb
        .from("picking_drafts")
        .select("id, name, status, created_at, updated_at")
        .order("created_at", { ascending: false })
        .order("id", { ascending: false })
        .limit(LIST_LIMIT);
      if (err) throw new Error(err.message);
      const rows = (data ?? []) as Draft[];
      setError(null);
      setDrafts(rows);
      setTruncated(rows.length >= LIST_LIMIT);

      // 品項數 = 各草稿有幾樣**商品**（明細是一格一列 SKU×分店，所以要去重 sku_id）。
      // 只撈 draft_id / sku_id 兩欄，並依既有慣例分批 200 個 draft_id；
      // 每批走 fetchAllRows 分頁，避免 PostgREST 1000 列靜默截斷把數字算少。
      const ids = rows.map((d) => d.id);
      const counts = new Map<number, Set<number>>();
      for (let i = 0; i < ids.length; i += 200) {
        const chunk = ids.slice(i, i + 200);
        const cells = await fetchAllRows<{ draft_id: number; sku_id: number }>(() =>
          sb
            .from("picking_draft_items")
            .select("draft_id, sku_id")
            .in("draft_id", chunk)
            .order("id", { ascending: true }),
        );
        for (const c of cells) {
          const set = counts.get(c.draft_id) ?? new Set<number>();
          set.add(c.sku_id);
          counts.set(c.draft_id, set);
        }
      }
      setSkuCounts(new Map(Array.from(counts.entries()).map(([k, v]) => [k, v.size])));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setDrafts([]);
    }
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function handleCreate() {
    const name = newName.trim();
    if (!name) {
      setError("請先給草稿一個名稱");
      return;
    }
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const tenantId = (sess.session?.user?.app_metadata as Record<string, unknown> | undefined)
        ?.tenant_id as string | undefined;
      if (!tenantId) throw new Error("JWT 缺 tenant_id claim、無法建立草稿");
      const uid = sess.session?.user?.id ?? null;

      const { error: err } = await sb.from("picking_drafts").insert({
        tenant_id: tenantId,
        name,
        created_by: uid,
        updated_by: uid,
      });
      if (err) throw err;
      setNewName(defaultDraftName());
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  async function setStatus(id: number, status: "draft" | "done") {
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const { error: err } = await sb
        .from("picking_drafts")
        .update({ status, updated_by: sess.session?.user?.id ?? null })
        .eq("id", id);
      if (err) throw err;
      await load();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  const inProgress = useMemo(() => (drafts ?? []).filter((d) => d.status === "draft"), [drafts]);
  const done = useMemo(() => (drafts ?? []).filter((d) => d.status === "done"), [drafts]);

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header>
        <h1 className="text-xl font-semibold">派貨草稿</h1>
        <p className="text-sm text-zinc-500">
          樓下撿貨前的清單，隨時可以加商品、刪商品、改數量。
          <strong className="text-zinc-700 dark:text-zinc-300">草稿完全不扣庫存、也不會建立任何撿貨單</strong>
          — 等樓下撿完確定了，再到「派貨工作台」建正式的單。
        </p>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex flex-wrap items-end gap-2 rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
        <label className="flex min-w-60 flex-1 flex-col gap-1 text-sm">
          <span className="text-xs font-medium text-zinc-500">新草稿名稱</span>
          <input
            value={newName}
            onChange={(e) => setNewName(e.target.value)}
            placeholder="例如：8/17 早上那批"
            className={inputCls}
          />
        </label>
        <SpinButton
          onClick={handleCreate}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
        >
          + 建立草稿
        </SpinButton>
      </div>

      {drafts === null ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : (
        <>
          <Section
            title="進行中"
            rows={inProgress}
            skuCounts={skuCounts}
            emptyHint="目前沒有進行中的草稿 — 用上面的「建立草稿」開一張。"
            action={{ label: "標記完成", to: "done", onClick: setStatus }}
          />
          <Section
            title="已完成"
            rows={done}
            skuCounts={skuCounts}
            emptyHint="還沒有已完成的草稿。"
            action={{ label: "重新開啟", to: "draft", onClick: setStatus }}
          />
          {truncated && (
            <p className="text-xs text-zinc-400">
              只列出最近 {LIST_LIMIT} 張草稿，更舊的沒有顯示。
            </p>
          )}
        </>
      )}
    </div>
  );
}

function Section({
  title,
  rows,
  skuCounts,
  emptyHint,
  action,
}: {
  title: string;
  rows: Draft[];
  skuCounts: Map<number, number>;
  emptyHint: string;
  action: { label: string; to: "draft" | "done"; onClick: (id: number, s: "draft" | "done") => Promise<void> };
}) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="text-sm font-semibold text-zinc-700 dark:text-zinc-300">
        {title} <span className="font-normal text-zinc-400">({rows.length})</span>
      </h2>
      {rows.length === 0 ? (
        <p className="rounded-md border border-dashed border-zinc-300 p-4 text-sm text-zinc-500 dark:border-zinc-700">
          {emptyHint}
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-left text-xs uppercase tracking-wide text-zinc-500">
                <th className="px-3 py-2">草稿名稱</th>
                <th className="px-3 py-2 text-right">品項數</th>
                <th className="px-3 py-2">建立時間</th>
                <th className="px-3 py-2">最後更新</th>
                <th className="px-3 py-2"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {rows.map((d) => (
                <tr key={d.id}>
                  <td className="px-3 py-2">
                    <Link
                      href={`/picking/drafts/edit?id=${d.id}`}
                      className="font-medium text-zinc-900 underline-offset-2 hover:underline dark:text-zinc-100"
                    >
                      {d.name}
                    </Link>
                  </td>
                  <td className="px-3 py-2 text-right font-mono">{skuCounts.get(d.id) ?? 0}</td>
                  <td className="px-3 py-2 text-xs text-zinc-500">{fmtTime(d.created_at)}</td>
                  <td className="px-3 py-2 text-xs text-zinc-500">{fmtTime(d.updated_at)}</td>
                  <td className="px-3 py-2 text-right">
                    <SpinButton
                      onClick={() => action.onClick(d.id, action.to)}
                      className="rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                    >
                      {action.label}
                    </SpinButton>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function fmtTime(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("sv-SE").slice(0, 16);
}
