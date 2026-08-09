"use client";

// 首頁摘要：「各區最突出的偏好」—— 只給結論，細節在 /analytics/regions。
// 用同一支 rpc_region_tag_matrix，口徑不會跟分析頁不一致。

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import {
  liftWord, DEFAULT_MIN_BUYERS, HIGHLIGHT_MIN_BUYERS, HIGHLIGHT_MIN_PEN,
  type RegionMatrix,
} from "@/lib/regionPreference";

const DAYS = 90;

export default function RegionPreferenceSummary({ focusStoreId }: { focusStoreId?: number | null }) {
  const [data, setData] = useState<RegionMatrix | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data: rows, error } = await getSupabase()
        .rpc("rpc_region_tag_matrix", { p_days: DAYS });
      if (cancelled) return;
      setLoading(false);
      // 首頁的摘要壞掉不該擋住整個儀表板，靜靜不顯示就好（細節去分析頁看）
      if (!error) setData(rows as RegionMatrix);
    })();
    return () => { cancelled = true; };
  }, []);

  // 頁首選了門市 → 只看那家店的前幾名；否則跨店挑最突出的組合，每家店最多一筆
  const rows = useMemo(() => {
    if (!data) return [];
    const storeById = new Map(data.stores.map((s) => [s.id, s]));
    const tagById = new Map(data.tags.map((t) => [t.id, t]));
    const usable = data.cells
      .filter((c) => c.pen >= HIGHLIGHT_MIN_PEN && c.buyers >= HIGHLIGHT_MIN_BUYERS && c.lift_adj != null)
      .filter((c) => (storeById.get(c.store_id)?.buyers ?? 0) >= DEFAULT_MIN_BUYERS)
      .sort((a, b) => (b.lift_adj ?? 0) - (a.lift_adj ?? 0));

    const picked: typeof usable = [];
    if (focusStoreId != null) {
      picked.push(...usable.filter((c) => c.store_id === focusStoreId).slice(0, 6));
    } else {
      const seen = new Set<number>();
      for (const c of usable) {
        if (seen.has(c.store_id)) continue;
        seen.add(c.store_id);
        picked.push(c);
        if (picked.length >= 6) break;
      }
    }
    return picked.map((c) => ({
      c,
      store: storeById.get(c.store_id)!,
      tag: tagById.get(c.tag_id)!,
    })).filter((r) => r.store && r.tag);
  }, [data, focusStoreId]);

  return (
    <div className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
        <div>
          <h2 className="text-sm font-semibold">各區最突出的偏好</h2>
          <p className="text-xs text-zinc-500">
            近 {DAYS} 天 · 以「買過的人數比例」跟全店平均相比，已扣除門市大小與客單品類數的差異
          </p>
        </div>
        <Link href="/analytics/regions" className="shrink-0 text-xs text-blue-600 hover:underline dark:text-blue-400">
          完整分析 →
        </Link>
      </div>
      <div className="p-3">
        {rows.length === 0 ? (
          <p className="py-3 text-center text-xs text-zinc-500">
            {loading ? "載入中…" : "這段期間沒有足夠樣本"}
          </p>
        ) : (
          <ul className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {rows.map(({ c, store, tag }) => (
              <li key={`${c.store_id}:${c.tag_id}`}>
                <Link
                  href="/analytics/regions"
                  className="block rounded-md border border-zinc-200 px-3 py-2 transition hover:bg-zinc-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
                >
                  <div className="flex items-baseline justify-between gap-2 text-sm">
                    <span>
                      <b>{store.name}</b>
                      <span className="mx-1 text-zinc-500">{liftWord(c.lift_adj)}</span>
                      <b>{tag.name}</b>
                    </span>
                    <span className="shrink-0 rounded bg-red-100 px-1.5 py-0.5 text-[11px] font-medium text-red-700 dark:bg-red-950 dark:text-red-300">
                      ×{(c.lift_adj ?? 0).toFixed(2)}
                    </span>
                  </div>
                  <div className="mt-0.5 text-[11px] text-zinc-500">
                    {c.buyers} 人買過 · 滲透 {Math.round(c.pen * 100)}%（大盤 {Math.round(tag.base * 100)}%）
                  </div>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
}
