"use client";

// 會員詳細頁的「店家 LINE 訊息綁定」卡片。
//
// 為什麼獨立成卡片：綁定原本只藏在「發送 LINE 訊息」彈窗裡（而且要推不到
// 才會出現配對選單），店員找不到；限量商品下單又以這個綁定當門檻之後，
// 「這位會員綁了沒」必須一眼看得到、當場能綁能解。
//
// 「綁定」= store_line_followers 有這位會員（該店 OA provider 的 LINE 身分）。
// 到貨通知推播（admin-line-push）與限量下單閘門（liff-api）都認這一筆。
// members.line_user_id 是**登入用**的另一個 provider，跟這裡無關。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { LineFollowerPicker } from "@/components/LineFollowerPicker";
import SpinButton from "@/components/SpinButton";

type Binding = {
  line_user_id: string;
  display_name: string | null;
  picture_url: string | null;
  followed: boolean;
  linked_at: string | null;
  last_event_at: string | null;
};

export function MemberLineBindingCard({
  member,
  homeStoreId,
  storeName,
  onChanged,
}: {
  member: { id: number; name: string | null; member_no: string };
  homeStoreId: number | null;
  storeName: string | null;
  /** 綁定 / 解除後呼叫（讓外層重抓 hasStoreLineBinding 等狀態） */
  onChanged?: () => void;
}) {
  const [binding, setBinding] = useState<Binding | null>(null);
  const [oaId, setOaId] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [unbinding, setUnbinding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    if (homeStoreId == null) { setLoaded(true); return; }
    let cancelled = false;
    setLoaded(false);
    (async () => {
      const sb = getSupabase();
      const [fol, st] = await Promise.all([
        sb.from("store_line_followers")
          .select("line_user_id, display_name, picture_url, followed, linked_at, last_event_at")
          .eq("store_id", homeStoreId)
          .eq("member_id", member.id)
          .order("linked_at", { ascending: false, nullsFirst: false })
          .limit(1)
          .maybeSingle(),
        sb.from("stores").select("line_oa_basic_id").eq("id", homeStoreId).maybeSingle(),
      ]);
      if (cancelled) return;
      if (fol.error) setError(fol.error.message);
      setBinding((fol.data as Binding | null) ?? null);
      setOaId(String(st.data?.line_oa_basic_id ?? "").trim() || null);
      setLoaded(true);
    })();
    return () => { cancelled = true; };
  }, [member.id, homeStoreId, tick]);

  const refresh = () => {
    setPickerOpen(false);
    setError(null);
    setTick((t) => t + 1);
    onChanged?.();
  };

  async function unbind() {
    if (!window.confirm(
      `解除「${binding?.display_name ?? "此 LINE 身分"}」與會員「${member.name ?? member.member_no}」的綁定？\n\n`
      + `解除後將無法對此會員推播到貨通知；下單限量商品時也會再次被要求綁定。`,
    )) return;
    setUnbinding(true);
    setError(null);
    try {
      const { error: uErr } = await getSupabase().rpc("rpc_unbind_store_line_follower", {
        p_member_id: member.id,
      });
      if (uErr) { setError(uErr.message); return; }
      refresh();
    } finally {
      setUnbinding(false);
    }
  }

  return (
    <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
      <div className="mb-2 flex items-center justify-between">
        <div className="text-xs font-medium text-zinc-500">
          店家 LINE 訊息綁定{storeName ? `（${storeName}）` : ""}
        </div>
        {oaId && <span className="font-mono text-xs text-zinc-400">{oaId}</span>}
      </div>

      {homeStoreId == null ? (
        <p className="text-sm text-zinc-500">此會員沒有取貨店 —— 請先在上方設定取貨店，才能決定要綁哪一家店的官方帳號。</p>
      ) : !loaded ? (
        <p className="text-sm text-zinc-500">載入中…</p>
      ) : binding ? (
        <div className="flex flex-wrap items-center gap-3">
          {binding.picture_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={binding.picture_url} alt="" className="h-9 w-9 rounded-full object-cover" />
          ) : (
            <div className="flex h-9 w-9 items-center justify-center rounded-full bg-zinc-200 text-xs text-zinc-500 dark:bg-zinc-800">
              {binding.display_name?.[0] ?? "?"}
            </div>
          )}
          <div className="flex-1 min-w-[180px]">
            <div className="text-sm font-medium">
              {binding.display_name ?? binding.line_user_id.slice(0, 10) + "…"}
              <span className="ml-2 rounded bg-green-100 px-1.5 py-0.5 text-[10px] font-normal text-green-700 dark:bg-green-950 dark:text-green-300">
                ✓ 已綁定
              </span>
            </div>
            <div className="text-xs text-zinc-500">
              {binding.linked_at ? `綁定於 ${new Date(binding.linked_at).toLocaleString("zh-TW")}` : "綁定時間不明"}
              {binding.last_event_at && `　最後互動 ${new Date(binding.last_event_at).toLocaleDateString("zh-TW")}`}
            </div>
            {!binding.followed && (
              <div className="mt-0.5 text-[11px] text-amber-700 dark:text-amber-400">
                ⚠ 此顧客已封鎖或移除本店官方帳號，訊息推播無法送達（綁定仍保留，重新加好友即恢復）
              </div>
            )}
          </div>
          <SpinButton
            onClick={unbind}
            disabled={unbinding}
            title="配對錯人時解除；解除後可重新從名冊挑選"
            className="rounded-md border border-red-300 px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50 disabled:opacity-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
          >
            解除綁定
          </SpinButton>
        </div>
      ) : (
        <div className="space-y-2">
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            尚未綁定 —— 無法對此會員推播到貨通知；下單<strong className="font-semibold">限量商品</strong>時會被要求先完成綁定。
          </p>
          <p className="text-[11px] text-zinc-500">
            綁定有兩條路：① 會員自己來 —— 在商城下單限量商品時照指示傳「綁定碼」訊息，或對本店官方帳號傳任意訊息後點回覆的「查看我的訂單」連結；
            ② 店員手動配對 —— 從下方名冊挑出這位顧客。
          </p>
          {pickerOpen ? (
            <LineFollowerPicker storeId={homeStoreId} member={member} onBound={refresh} />
          ) : (
            <SpinButton
              onClick={() => setPickerOpen(true)}
              className="rounded-md border border-sky-300 px-3 py-1 text-xs font-medium text-sky-700 hover:bg-sky-50 dark:border-sky-800 dark:text-sky-300 dark:hover:bg-sky-950"
            >
              🔗 從名冊挑人綁定
            </SpinButton>
          )}
        </div>
      )}

      {error && (
        <div className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}
    </div>
  );
}
