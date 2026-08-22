"use client";

// 該店 OA 好友名冊的「配對選單」：從還沒對應到會員的 LINE 使用者裡挑一位，
// 綁定給指定會員（rpc_bind_store_line_follower）。
//
// 從 LineMessageModal 抽出來共用 —— 發訊息彈窗（推不到時補救）與
// 會員詳細頁的「店家 LINE 綁定」卡片都用這一份，配對的坑（排序、確認、
// 疑似本人加星）只修一處。

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";

type Follower = { line_user_id: string; display_name: string | null; picture_url: string | null };

/** 選單一次最多畫幾顆（超過的用搜尋縮小範圍，不然是一面牆的頭像） */
const FOLLOWER_RENDER_MAX = 50;

/**
 * 抓該店「還沒配對到會員」的好友名冊，**最近有動靜的排最前面**。
 *
 * 排序不能省：之前沒排序就 `limit(50)`，PostgREST 回的是最舊的 50 筆 ——
 * 名冊一超過 50 人，「剛加好友的顧客」（正是店員此刻要配對的人）反而
 * 永遠不在選單裡。2026-08-13 三峽店實際踩到：名冊 104 人，會員當天加好友
 * 加入會員，選單裡卻找不到她，變成「綁定了但不能發 LINE」的死路。
 */
async function fetchUnpairedFollowers(storeId: number) {
  return await getSupabase()
    .from("store_line_followers")
    .select("line_user_id, display_name, picture_url")
    .eq("store_id", storeId)
    .is("member_id", null)
    .eq("followed", true)
    .order("last_event_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false })
    .limit(200);
}

export function LineFollowerPicker({
  storeId,
  member,
  onBound,
}: {
  /** 要看哪一家店的 OA 名冊（= 會員的取貨店） */
  storeId: number;
  member: { id: number; name: string | null; member_no: string };
  /** 綁定成功後呼叫 —— 呼叫端自己重新載入綁定狀態 / 可達性 */
  onBound: () => void;
}) {
  const [followers, setFollowers] = useState<Follower[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [filter, setFilter] = useState("");
  const [binding, setBinding] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: fErr } = await fetchUnpairedFollowers(storeId);
      if (cancelled) return;
      // 不能吞掉錯誤：查詢失敗時清單會是空的，選單就整個不見，
      // 畫面上卻什麼都沒說 —— 店員只會覺得「這功能壞了」而無從回報。
      if (fErr) { setError(`讀取本店 LINE 名冊失敗：${fErr.message}`); return; }
      setFollowers((data as Follower[]) ?? []);
      setLoaded(true);
    })();
    return () => { cancelled = true; };
  }, [storeId]);

  // 關鍵字過濾 + 「LINE 名稱出現在會員姓名裡」的排最前。
  // 這個租戶的會員名慣例是「LINE名稱＋電話末碼-店」（例：珍珠貝（Fang Cheng)922278-三峽），
  // 所以名稱包含是很強的「疑似本人」訊號 —— 但只拿來排序加星，綁定仍要店員確認，
  // 自動綁過會綁錯人（2026-08-10 平鎮兩筆）。
  const visibleFollowers = useMemo(() => {
    const kw = filter.trim().toLowerCase();
    const memberName = (member.name ?? "").toLowerCase();
    return followers
      .filter((f) => !kw || (f.display_name ?? "").toLowerCase().includes(kw))
      .map((f) => {
        const n = (f.display_name ?? "").trim().toLowerCase();
        return { ...f, suggested: n.length >= 2 && memberName.includes(n) };
      })
      // sort 是穩定排序：同組之間維持後端給的「最近有動靜優先」順序
      .sort((a, b) => Number(b.suggested) - Number(a.suggested));
  }, [followers, filter, member.name]);

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }

  if (loaded && followers.length === 0) {
    return (
      <div className="rounded-md border border-sky-200 bg-sky-50 p-2 text-[11px] text-sky-800/80 dark:border-sky-900 dark:bg-sky-950/40 dark:text-sky-300/80">
        本店官方帳號名冊裡目前沒有「未配對」的人 —— 請先請顧客加入本店 LINE
        官方帳號並傳一則訊息（傳什麼都可以），名冊收到人之後再回來這裡挑選。
      </div>
    );
  }

  return (
    <div className="rounded-md border border-sky-200 bg-sky-50 p-2 dark:border-sky-900 dark:bg-sky-950/40">
      <div className="mb-1 text-xs font-medium text-sky-900 dark:text-sky-200">
        這位會員在本店官方帳號是哪一個？
      </div>
      <p className="mb-2 text-[11px] text-sky-800/80 dark:text-sky-300/80">
        以下是已加入本店官方帳號、但還沒對應到會員的人（最近有動靜的排前面，⭐ = LINE 名稱與會員姓名相符）。
      </p>
      {followers.length > 10 && (
        <input
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          placeholder={`搜尋 LINE 名稱（共 ${followers.length} 人）…`}
          className="mb-2 w-full rounded-md border border-sky-300 bg-white px-2 py-1 text-xs dark:border-sky-800 dark:bg-zinc-900"
        />
      )}
      <div className="flex flex-wrap gap-2">
        {visibleFollowers.slice(0, FOLLOWER_RENDER_MAX).map((f) => (
          <SpinButton
            key={f.line_user_id}
            disabled={binding}
            onClick={async () => {
              // 人工配對點錯過（2026-08-10 平鎮兩筆）— 綁定前把兩個名字並列確認
              if (!window.confirm(`把 LINE「${f.display_name ?? f.line_user_id.slice(0, 8)}」綁定為會員「${member.name ?? member.member_no}」？`)) return;
              setBinding(true);
              try {
                const { error: bErr } = await getSupabase().rpc("rpc_bind_store_line_follower", {
                  p_member_id: member.id,
                  p_line_user_id: f.line_user_id,
                });
                if (bErr) { setError(bErr.message); return; }
                onBound();
              } finally {
                setBinding(false);
              }
            }}
            className="flex items-center gap-2 rounded-md border border-sky-300 bg-white px-2 py-1 text-xs hover:bg-sky-100 disabled:opacity-50 dark:border-sky-800 dark:bg-zinc-900 dark:hover:bg-sky-950"
          >
            {f.picture_url && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={f.picture_url} alt="" className="h-5 w-5 rounded-full object-cover" />
            )}
            {f.suggested && <span title="LINE 名稱與會員姓名相符，疑似本人">⭐</span>}
            {f.display_name ?? f.line_user_id.slice(0, 8) + "…"}
          </SpinButton>
        ))}
      </div>
      {visibleFollowers.length === 0 && (
        <p className="text-[11px] text-sky-800/80 dark:text-sky-300/80">
          沒有符合「{filter.trim()}」的人 —— 顧客的 LINE 名稱可能跟會員姓名不同，清空搜尋看看全部。
        </p>
      )}
      {visibleFollowers.length > FOLLOWER_RENDER_MAX && (
        <p className="mt-2 text-[11px] text-sky-800/80 dark:text-sky-300/80">
          還有 {visibleFollowers.length - FOLLOWER_RENDER_MAX} 人未顯示，請輸入名稱縮小範圍。
        </p>
      )}
    </div>
  );
}
