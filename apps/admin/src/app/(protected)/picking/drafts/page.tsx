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
import {
  deleteDraftConfirmMessage,
  describeDraftDbError,
  type DraftSkuRecount,
} from "@/lib/pickingDraftView";
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

/**
 * 品項數 = 每張草稿有幾樣**商品**（明細是一格一列 SKU×分店，所以要去重 sku_id）。
 *
 * ⭐ 列表與「刪除確認框」**共用這一支**：兩處各寫一份遲早會飄移，而飄移的下場是
 *   確認框說 12 樣、cascade 實際帶走 32 樣 —— 而且救不回來。
 *
 * 只撈 draft_id / sku_id 兩欄，並依既有慣例分批 200 個 draft_id；
 * 每批走 fetchAllRows 分頁，避免 PostgREST 1000 列靜默截斷把數字算少。
 *
 * ⛔ 查詢失敗**照樣往上丟**（fetchAllRows 會 throw）：呼叫端必須分得出
 *   「真的是 0 樣」與「查不出來」—— 在這裡吞成 0 就是靜默偽裝。
 *
 * @returns key = draft_id；一列明細都沒有的草稿不會出現在 map 裡（呼叫端自己 ?? 0）
 */
async function countDraftSkus(
  sb: ReturnType<typeof getSupabase>,
  draftIds: number[],
): Promise<Map<number, number>> {
  const counts = new Map<number, Set<number>>();
  for (let i = 0; i < draftIds.length; i += 200) {
    const chunk = draftIds.slice(i, i + 200);
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
  return new Map(Array.from(counts.entries()).map(([k, v]) => [k, v.size]));
}

export default function PickingDraftsPage() {
  const [drafts, setDrafts] = useState<Draft[] | null>(null);
  const [skuCounts, setSkuCounts] = useState<Map<number, number>>(new Map());
  const [error, setError] = useState<string | null>(null);
  // 刪除成功的回饋。⛔ 刪完不可以靜默：清單少一列很容易看漏（尤其一次刪好幾張）。
  const [notice, setNotice] = useState<string | null>(null);
  const [newName, setNewName] = useState(defaultDraftName);
  const [truncated, setTruncated] = useState(false);
  // 載入本身就失敗（最常見：migration 還沒套、表根本不存在）。
  // 這種時候不可以照樣畫出「還沒有草稿，建一張吧」—— 那會讓人以為只是還沒建，
  // 按下去又失敗一次。整頁只留錯誤訊息 + 重試。
  const [loadFailed, setLoadFailed] = useState(false);

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
      if (err) throw err;
      const rows = (data ?? []) as Draft[];
      setError(null);
      setLoadFailed(false);
      setDrafts(rows);
      setTruncated(rows.length >= LIST_LIMIT);

      // 品項數（去重 sku_id）。⭐ 與刪除確認框共用 countDraftSkus，算法保證不飄移。
      setSkuCounts(await countDraftSkus(sb, rows.map((d) => d.id)));
    } catch (e) {
      setError(describeDraftDbError(e));
      setLoadFailed(true);
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
    setNotice(null); // 上一則「已刪除…」講的是別張草稿，留著會跟這次的動作對不上
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
      setError(describeDraftDbError(e));
    }
  }

  async function setStatus(id: number, status: "draft" | "done") {
    setError(null);
    setNotice(null);
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
      setError(describeDraftDbError(e));
    }
  }

  // ---- 刪除草稿（硬刪；明細由 DB 的 ON DELETE CASCADE 一起帶走）----
  //
  // 老闆 2026-08-17 拍板的規則：
  //   1. 只有「進行中」刪得掉；「已完成」＝他心裡的留底，不能直接刪。
  //   2. 真要毀掉已完成的，得先按「重新開啟」變回進行中 —— **兩個動作**才毀得掉，
  //      這是刻意的防手滑，不是漏做。
  //
  // ⛔ 只碰 picking_drafts 這一張表。明細由外鍵 CASCADE 清掉
  //    （migration 20260817000000_picking_drafts.sql:141-142），
  //    不碰任何既有表、不呼叫任何 RPC、完全不影響庫存與派貨工作台。
  async function handleDelete(d: Draft) {
    // ⭐ 畫面上那個數字是列表 load() 當下算的、**可能已經過期** —— 樓下同時在另一台
    //   iPad 上加商品正是本功能的設計前提。按下去先重查一次，確認框才不會說「12 樣」
    //   而 cascade 實際帶走 32 樣（見 deleteDraftConfirmMessage 的說明）。
    //   ⓘ 也一定要在**刪之前**查：刪完 load() 就查不到了，訊息會變成 0。
    const shown = skuCounts.get(d.id) ?? 0;
    let recount: DraftSkuRecount;
    try {
      const counts = await countDraftSkus(getSupabase(), [d.id]);
      // 一列明細都沒有的草稿不會出現在 map 裡 → 0（與列表同一套語意）
      recount = { kind: "ok", count: counts.get(d.id) ?? 0, shown };
    } catch (e) {
      // ⛔ 查不出來就明講，不可以靜默沿用 shown 照樣宣稱「會刪掉 N 樣」
      recount = { kind: "failed", shown, reason: describeDraftDbError(e) };
    }
    if (!confirm(deleteDraftConfirmMessage(d.name, recount))) return;
    setError(null);
    setNotice(null);
    try {
      const sb = getSupabase();
      // ⭐ .eq("status","draft") 不是裝飾：條件寫在 **DELETE 語句本身**，
      //   另一台 iPad 剛把它標成完成時，這裡會是「一列都刪不到」而不是照樣毀掉留底。
      //   前端「只在進行中區塊放按鈕」擋不住這種時間差（畫面是幾秒前的快照）。
      // ⭐ .select("id") 是為了知道「到底刪到幾列」：沒有它，刪 0 列與刪 1 列都算成功，
      //   按下去就沒反應 —— 老闆分不出是刪掉了還是壞了。
      const { data, error: err } = await sb
        .from("picking_drafts")
        .delete()
        .eq("id", d.id)
        .eq("status", "draft")
        .select("id");
      if (err) throw err;

      if ((data ?? []).length === 0) {
        // 刪不到任何一列 → ⛔ 一定要說出為什麼。重查一次現況才分得出
        // 「剛被別台標成完成」與「已經被別人刪掉」——這兩件事該講的話完全不同。
        const { data: now, error: probeErr } = await sb
          .from("picking_drafts")
          .select("id, status")
          .eq("id", d.id)
          .maybeSingle();
        const msg = probeErr
          ? `刪不掉草稿「${d.name}」，而且查不出原因：${describeDraftDbError(probeErr)}。請通知工程師。`
          : !now
            ? `草稿「${d.name}」已經不在了（可能是另一台 iPad 剛剛刪掉的）。清單已重新整理。`
            : (now as { status?: string }).status === "done"
              ? `草稿「${d.name}」現在是「已完成」，已完成的草稿不能直接刪除 —— 請先按「重新開啟」，再刪。`
              : `刪不掉草稿「${d.name}」：資料庫一列都沒刪到（這個帳號可能沒有刪除權限）。請通知工程師。`;
        // ⚠ 順序不能顛倒：load() 成功時會 setError(null)，訊息一定要在它**之後**才設，
        //   否則剛設好的原因會被清掉，又變成「按了沒反應」。
        await load();
        setError(msg);
        return;
      }

      await load();
      // 回報用**重查到的**數字，那才是真的被 cascade 帶走的量。
      // ⛔ 重查失敗時不掰一個數字出來（唯一有的是那個過期的 shown，講出來就是說謊）。
      setNotice(
        recount.kind === "failed"
          ? `已刪除草稿「${d.name}」。（刪除前查不到品項數，所以這裡不寫幾樣。）`
          : recount.count > 0
            ? `已刪除草稿「${d.name}」，連同裡面的 ${recount.count} 樣商品。`
            : `已刪除草稿「${d.name}」。`,
      );
    } catch (e) {
      setError(describeDraftDbError(e));
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

      {notice && (
        <div className="flex items-start justify-between gap-3 rounded-md border border-sky-300 bg-sky-50 p-3 text-sm text-sky-900 dark:border-sky-800 dark:bg-sky-950/40 dark:text-sky-200">
          <span>{notice}</span>
          <button
            type="button"
            onClick={() => setNotice(null)}
            aria-label="關閉這則訊息"
            className="shrink-0 rounded px-1.5 text-sky-700 hover:bg-sky-100 dark:text-sky-300 dark:hover:bg-sky-900"
          >
            ✕
          </button>
        </div>
      )}

      {loadFailed ? (
        // 載不到就只留「重試」。⛔ 不要照樣畫出建立草稿的框跟兩個空區塊 ——
        // 那會讓人以為只是還沒建過，按下去又失敗一次。
        <SpinButton
          onClick={load}
          className="w-fit rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          重新載入
        </SpinButton>
      ) : (
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
      )}

      {loadFailed ? null : drafts === null ? (
        <div className="text-sm text-zinc-500">載入中…</div>
      ) : (
        <>
          <Section
            title="進行中"
            rows={inProgress}
            skuCounts={skuCounts}
            emptyHint="目前沒有進行中的草稿 — 用上面的「建立草稿」開一張。"
            action={{ label: "標記完成", to: "done", onClick: setStatus }}
            onDelete={handleDelete}
          />
          <Section
            title="已完成"
            rows={done}
            skuCounts={skuCounts}
            emptyHint="還沒有已完成的草稿。"
            action={{ label: "重新開啟", to: "draft", onClick: setStatus }}
            // ⛔ 這一區刻意**沒有**刪除鈕：已完成＝留底。要毀掉得先「重新開啟」，
            //    兩個動作才刪得成 —— 不講清楚的話老闆會以為功能壞了，所以一定要有這句話。
            note="已完成的草稿不能直接刪除（那是留底）。真的要刪，先按「重新開啟」把它變回進行中，再刪。"
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
  onDelete,
  note,
}: {
  title: string;
  rows: Draft[];
  skuCounts: Map<number, number>;
  emptyHint: string;
  action: { label: string; to: "draft" | "done"; onClick: (id: number, s: "draft" | "done") => Promise<void> };
  /** 有傳才長出「刪除」鈕 —— 只有「進行中」那一區會傳（老闆：已完成的不能直接刪） */
  onDelete?: (d: Draft) => Promise<void>;
  /** 這一區要對老闆補充的一句話（例如：為什麼這裡沒有刪除鈕） */
  note?: string;
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
                  <td className="px-3 py-2">
                    <div className="flex justify-end gap-2">
                      <SpinButton
                        onClick={() => action.onClick(d.id, action.to)}
                        className="rounded border border-zinc-300 px-2 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
                      >
                        {action.label}
                      </SpinButton>
                      {onDelete && (
                        <SpinButton
                          onClick={() => onDelete(d)}
                          className="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400 dark:hover:bg-red-950"
                        >
                          刪除
                        </SpinButton>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {note && rows.length > 0 && <p className="text-xs text-zinc-500">{note}</p>}
    </section>
  );
}

function fmtTime(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("sv-SE").slice(0, 16);
}
