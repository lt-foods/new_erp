"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";

export const PROMO_LABEL_MAX = 6;

/**
 * 編輯開團：會員商城的「優惠標籤」（group_buy_campaigns.promo_label，20261122000000）。
 * 例：獨家優惠、本週主推。顯示在商城卡片的圖片右上角與商品頁標題上方。
 *
 * 自己讀、自己存（按「存」馬上生效，跟上面的「量上限」同一種做法），不併進下方表單的「儲存」：
 * rpc_upsert_campaign 是整欄覆寫、參數固定，這一欄不在裡面；塞進表單反而要多管一份
 * 「表單手上的是不是舊值」（見 CLAUDE.md「rpc_upsert_campaign 是整欄覆寫」）。
 * 欄位讀不到（SQL 還沒套）→ 整塊不顯示。
 */
export function CampaignPromoLabelField({ campaignId }: { campaignId: number }) {
  const [saved, setSaved] = useState<string | null>(null);   // null = 還沒讀到 / 欄位不存在
  const [draft, setDraft] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [justSaved, setJustSaved] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("group_buy_campaigns")
        .select("promo_label")
        .eq("id", campaignId)
        .maybeSingle();
      if (cancelled || err || !data) return;
      const label = (data.promo_label as string | null) ?? "";
      setSaved(label);
      setDraft(label);
    })();
    return () => { cancelled = true; };
  }, [campaignId]);

  if (saved === null) return null;

  const trimmed = draft.trim();
  const length = [...trimmed].length;
  const tooLong = length > PROMO_LABEL_MAX;
  const dirty = trimmed !== saved;

  const save = async () => {
    if (tooLong) return;
    setBusy(true); setError(null); setJustSaved(false);
    const { error: err } = await getSupabase().rpc("rpc_set_campaign_promo_label", {
      p_id: campaignId,
      p_label: trimmed || null,
    });
    setBusy(false);
    if (err) { setError(translateRpcError(err)); return; }
    setSaved(trimmed);
    setDraft(trimmed);
    setJustSaved(true);
  };

  return (
    <div className="space-y-1.5 rounded-md border border-zinc-200 px-3 py-2.5 dark:border-zinc-700">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-medium text-zinc-700 dark:text-zinc-200">商城優惠標籤</span>
        <input
          type="text"
          value={draft}
          onChange={(e) => { setDraft(e.target.value); setJustSaved(false); setError(null); }}
          placeholder="例：獨家優惠"
          aria-label="商城優惠標籤"
          className="w-40 rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
        <span className={`text-xs tabular-nums ${tooLong ? "font-semibold text-red-600" : "text-zinc-400"}`}>
          {length}/{PROMO_LABEL_MAX}
        </span>
        <SpinButton
          type="button"
          onClick={save}
          disabled={busy || !dirty || tooLong}
          className="rounded-md border border-zinc-300 px-2.5 py-1 text-xs hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          {busy ? "存檔中…" : "存"}
        </SpinButton>
        {trimmed && !tooLong && (
          <span className="rounded-full bg-gradient-to-r from-[#ff3b30] to-[#ff7a00] px-2 py-0.5 text-[11px] font-bold text-white">
            {trimmed}
          </span>
        )}
        {justSaved && <span className="text-xs text-emerald-700 dark:text-emerald-400">✓ 已存，商城馬上看得到</span>}
      </div>
      <p className="text-[11px] text-zinc-500 dark:text-zinc-400">
        顯示在會員商城這一團卡片的圖片右上角。最多 {PROMO_LABEL_MAX} 個字，按「存」就生效（跟下方表單的「儲存」無關）；清空再按「存」＝不顯示。
      </p>
      {tooLong && <p className="text-xs text-red-600">最多 {PROMO_LABEL_MAX} 個字，現在 {length} 個字。</p>}
      {error && <p className="text-xs text-red-600">{error}</p>}
    </div>
  );
}
