"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { VideoLinkEditor } from "@/components/VideoLinkEditor";
import { finalizeVideoLink, videoLinkStatus } from "@/lib/videoLink";

/**
 * 編輯開團：設定會員商品頁的介紹影片（老闆 2026-11-22：「可以把影片的設定放到開團裡面」）。
 *
 * 影片**還是存在商品上**（products.intro_video_url，20261122000000），這裡只是多一個入口：
 *   - 同一個商品之後再開團會自動帶同一支影片，不用每開一團重設一次（跟「原價」同一個想法）。
 *   - 商品編輯頁那一格照舊，兩邊改的是同一個欄位，誰後存算誰的。
 * 會員端讀的是「這一團品項所屬的商品」的影片（liff-api getCampaignDetail，照品項順序拿第一支有影片的），
 * 所以多商品的團這裡一個商品一列；絕大多數的團只有一個商品，就只有一列。
 *
 * 自己讀、自己存（按「存」馬上生效），不併進下方表單的「儲存」—— 理由同 CampaignPromoLabelField。
 * 欄位讀不到（SQL 還沒套）→ 整塊不顯示。
 */
type ProductVideo = { id: number; name: string; saved: string; draft: string };

const inputCls =
  "w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

export function CampaignVideoField({ campaignId }: { campaignId: number }) {
  const [rows, setRows] = useState<ProductVideo[] | null>(null);   // null = 還沒讀到 / 欄位不存在
  const [busyId, setBusyId] = useState<number | null>(null);
  const [savedId, setSavedId] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("campaign_items")
        .select("sort_order, skus!inner(status, products!inner(id, name, intro_video_url))")
        .eq("campaign_id", campaignId)
        .order("sort_order");
      if (cancelled || err || !data) return;
      const seen = new Map<number, ProductVideo>();
      for (const r of data as unknown as {
        skus: { status: string; products: { id: number; name: string; intro_video_url: string | null } };
      }[]) {
        // 已下架的規格不算（編輯開團的商品明細也不顯示它們）
        if (r.skus.status === "discontinued") continue;
        const p = r.skus.products;
        if (seen.has(p.id)) continue;
        const url = p.intro_video_url ?? "";
        seen.set(p.id, { id: p.id, name: p.name, saved: url, draft: url });
      }
      setRows([...seen.values()]);
    })();
    return () => { cancelled = true; };
  }, [campaignId]);

  if (rows === null || rows.length === 0) return null;

  const setDraft = (id: number, draft: string) => {
    setRows((prev) => (prev ?? []).map((r) => (r.id === id ? { ...r, draft } : r)));
    setSavedId(null);
    setError(null);
  };

  const save = async (row: ProductVideo) => {
    if (videoLinkStatus(row.draft).kind === "invalid") {
      setError("介紹影片連結要是 https:// 開頭的網址（不需要就清空再存）");
      return;
    }
    setBusyId(row.id); setError(null); setSavedId(null);
    const finalUrl = await finalizeVideoLink(row.draft);
    const { error: err } = await getSupabase().rpc("rpc_set_product_intro_video", {
      p_product_id: row.id,
      p_url: finalUrl || null,
    });
    setBusyId(null);
    if (err) { setError(translateRpcError(err)); return; }
    setRows((prev) => (prev ?? []).map((r) => (r.id === row.id ? { ...r, saved: finalUrl, draft: finalUrl } : r)));
    setSavedId(row.id);
  };

  return (
    <div className="space-y-3 rounded-md border border-zinc-200 px-3 py-2.5 dark:border-zinc-700">
      <div>
        <span className="text-sm font-medium text-zinc-700 dark:text-zinc-200">商品頁介紹影片</span>
        <p className="mt-0.5 text-[11px] text-zinc-500 dark:text-zinc-400">
          會員點進這一團，右下角會浮出自動播放的影片小視窗。按「存」就生效（跟下方表單的「儲存」無關）。
          影片是記在商品上的：同一個商品下次再開團會自動帶，不用重設。
        </p>
      </div>
      {rows.map((row) => {
        const dirty = row.draft.trim() !== row.saved;
        return (
          <div key={row.id} className="space-y-1">
            {rows.length > 1 && (
              <div className="text-xs font-medium text-zinc-600 dark:text-zinc-300">{row.name}</div>
            )}
            <VideoLinkEditor value={row.draft} onChange={(next) => setDraft(row.id, next)} inputClassName={inputCls} />
            <div className="flex flex-wrap items-center gap-2 pt-1">
              <SpinButton
                type="button"
                onClick={() => save(row)}
                disabled={busyId !== null || !dirty}
                className="rounded-md bg-zinc-900 px-3 py-1 text-xs font-medium text-white hover:bg-zinc-800 disabled:opacity-40 dark:bg-zinc-50 dark:text-zinc-900"
              >
                {busyId === row.id ? "存檔中…" : row.draft.trim() === "" && row.saved !== "" ? "存（拿掉影片）" : "存"}
              </SpinButton>
              {row.saved !== "" && (
                <SpinButton
                  type="button"
                  onClick={() => setDraft(row.id, "")}
                  disabled={busyId !== null || row.draft === ""}
                  className="rounded-md border border-zinc-300 px-2.5 py-1 text-xs hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
                >
                  清空
                </SpinButton>
              )}
              {dirty && <span className="text-xs text-amber-700 dark:text-amber-400">還沒存</span>}
              {savedId === row.id && !dirty && (
                <span className="text-xs text-emerald-700 dark:text-emerald-400">
                  ✓ 已存{row.saved === "" ? "，影片已拿掉" : "，商城馬上看得到"}
                </span>
              )}
            </div>
          </div>
        );
      })}
      {rows.length > 1 && (
        <p className="text-[11px] text-zinc-500 dark:text-zinc-400">
          這一團有 {rows.length} 個商品。會員端只播一支：照品項順序，第一個有設影片的商品。
        </p>
      )}
      {error && <p className="text-xs text-red-600">{error}</p>}
    </div>
  );
}
