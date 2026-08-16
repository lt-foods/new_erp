"use client";

// 派貨草稿 — 編輯（切片 A）
//
// 矩陣：商品(SKU) × 分店。樓下可以「增商品 / 刪商品 / 改任一格數量」（老闆 2026-08-17 拍板）。
//
// ⭐ 分店欄位是**另外撈 stores 全表**（is_active），不是沿用派貨工作台的 allStores。
//    理由（老闆）：「有可能有庫存就會多給沒下訂單的店家內部」。
//    派貨工作台的 allStores 只收「demand 裡出現過的店」（wms/picking/page.tsx:813-826），
//    沒下訂單的店在那邊連欄位都不存在。
//
// ⛔ 本檔只讀寫 picking_drafts / picking_draft_items 兩張新表，外加**唯讀** stores / skus / products。
//    不呼叫任何庫存或建單 RPC、不寫入任何既有表、完全不扣庫存。
//
// 存檔時機：每一格「離開輸入框(blur)就立刻寫 DB」。樓下是共用總部帳號 + 多台 iPad，
//    留一堆未存檔的暫存狀態最危險（換人接手就掉了）。

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import {
  addOutcomeMessage,
  buildSkuRows,
  buildStoreColumns,
  classifyAddOutcome,
  describeDraftDbError,
  lateCellSnapshot,
  loadPrefill,
  rowTotal,
  type PrefillResult,
  type StoreRef,
} from "@/lib/pickingDraftView";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";

type Draft = {
  id: number;
  name: string;
  status: "draft" | "done";
  created_at: string;
  updated_at: string;
};

type DraftItem = {
  id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  snapshot_sku_code: string | null;
  snapshot_sku_label: string | null;
  snapshot_store_code: string | null;
  snapshot_store_name: string | null;
};

type Store = StoreRef;

type SkuOption = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  product_name: string;
};

const cellKey = (skuId: number, storeId: number) => `${skuId}:${storeId}`;

const STORE_STATE_LABEL = { inactive: "已停用", missing: "已刪除" } as const;

export default function PickingDraftEditPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const draftId = Number(useSearchParams().get("id"));
  const validId = Number.isFinite(draftId) && draftId > 0;
  const [draft, setDraft] = useState<Draft | null>(null);
  const [items, setItems] = useState<DraftItem[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  // 草稿引用到、但已經不在啟用清單裡的分店（停用或被刪）。key = store_id，查不到就是被刪了。
  const [extraStores, setExtraStores] = useState<Map<number, Store>>(new Map());
  // 目前 skus 還查得到的 id；null = 這次查不出來 → 一律不標「商品已不存在」
  const [existingSkuIds, setExistingSkuIds] = useState<Set<number> | null>(null);
  // 網址沒帶 ?id= 就沒有東西要載 → 一開始就不是 loading，直接落到下面的錯誤畫面
  const [loading, setLoading] = useState(validId);
  const [error, setError] = useState<string | null>(null);
  // 加入商品後的說明（帶出來的量被可分配量夾住、或整個沒有需求）。
  // ⛔ 不能靜默：老闆看到 105 卻不知道那家店其實要 108，會照著印給樓下。
  const [notice, setNotice] = useState<string | null>(null);
  // 正在輸入、還沒 blur 的格子（key → 使用者打的字）。commit 成功後清掉。
  const [edits, setEdits] = useState<Map<string, string>>(new Map());
  const [nameDraft, setNameDraft] = useState("");

  // ⚠ 第一件事就 await，不在 effect body 同步 setState（react-hooks/set-state-in-effect）
  const load = useCallback(async () => {
    if (!validId) return;
    try {
      const sb = getSupabase();
      const [{ data: head, error: headErr }, storeRes] = await Promise.all([
        sb
          .from("picking_drafts")
          .select("id, name, status, created_at, updated_at")
          .eq("id", draftId)
          .maybeSingle(),
        // 所有啟用中的分店（含這次沒下訂單的），排序沿用 restock/new 的 code 排法
        sb.from("stores").select("id, code, name").eq("is_active", true).order("code"),
      ]);
      if (headErr) throw headErr;
      if (!head) throw new Error(`找不到草稿 #${draftId}（可能已被刪除，或這個帳號看不到）`);
      // 分店撈失敗一定要吭聲：靜靜當成 0 家店的話，矩陣會變成沒有任何欄位、
      // 「加入商品」也會失敗，畫面上看起來像是草稿壞掉。
      if (storeRes.error) throw new Error(`撈分店清單失敗：${describeDraftDbError(storeRes.error)}`);

      // 明細是 SKU×分店 一格一列，50 樣 × 十幾家店就破千 →
      // 一定要走 fetchAllRows 分頁，否則 PostgREST 會靜默截在 1000 列、後面的商品整個消失。
      const cells = await fetchAllRows<DraftItem>(() =>
        sb
          .from("picking_draft_items")
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name")
          .eq("draft_id", draftId)
          .order("id", { ascending: true }),
      );

      const activeStores = (storeRes.data ?? []) as Store[];

      // ---- 孤兒列的解析（sku_id / store_id 沒有外鍵，草稿可能引用到已刪除的東西）----
      // ⛔ 目的不是「濾掉」，是「查出來好標示」。查失敗一律退化成「不標記」，
      //    絕不因為一次查詢失敗就把資料藏起來或對老闆說東西不見了。
      const activeIds = new Set(activeStores.map((s) => s.id));
      const missingStoreIds = Array.from(new Set(cells.map((c) => c.store_id))).filter(
        (id) => !activeIds.has(id),
      );
      const extra = new Map<number, Store>();
      if (missingStoreIds.length > 0) {
        try {
          for (let i = 0; i < missingStoreIds.length; i += 200) {
            const { data: rows } = await sb
              .from("stores")
              .select("id, code, name")
              .in("id", missingStoreIds.slice(i, i + 200));
            for (const s of (rows ?? []) as Store[]) extra.set(s.id, s);
          }
        } catch {
          extra.clear(); // 查不到就當成「已刪除」標示，欄位照樣會出現
        }
      }

      const skuIds = Array.from(new Set(cells.map((c) => c.sku_id)));
      let alive: Set<number> | null = null;
      if (skuIds.length > 0) {
        try {
          const found = new Set<number>();
          for (let i = 0; i < skuIds.length; i += 200) {
            const { data: rows, error: e } = await sb
              .from("skus")
              .select("id")
              .in("id", skuIds.slice(i, i + 200));
            if (e) throw new Error(e.message);
            for (const s of (rows ?? []) as { id: number }[]) found.add(s.id);
          }
          alive = found;
        } catch {
          alive = null; // 查不出來 → 不標記（見 buildSkuRows 的說明）
        }
      }

      setError(null);
      setNotice(null); // 重新整理 = 重新看現況，舊訊息不留著
      setDraft(head as Draft);
      setNameDraft((head as Draft).name);
      setStores(activeStores);
      setExtraStores(extra);
      setExistingSkuIds(alive);
      setItems(cells);
      setEdits(new Map());
    } catch (e) {
      setError(describeDraftDbError(e));
    } finally {
      setLoading(false);
    }
  }, [draftId, validId]);

  useEffect(() => {
    void load();
  }, [load]);

  const itemsByKey = useMemo(() => {
    const m = new Map<string, DraftItem>();
    for (const it of items) m.set(cellKey(it.sku_id, it.store_id), it);
    return m;
  }, [items]);

  // 一列 = 一樣商品；欄位 = 啟用中的分店 ∪ 這張草稿用到的分店。
  // 兩者都可能含「已停用 / 已刪除」的東西，一律照樣顯示並標示（見 lib/pickingDraftView.ts）。
  const skuRows = useMemo(() => buildSkuRows(items, existingSkuIds), [items, existingSkuIds]);
  const storeCols = useMemo(
    () => buildStoreColumns(stores, items, extraStores),
    [stores, items, extraStores],
  );
  const orphanSkuCount = useMemo(() => skuRows.filter((r) => r.missing).length, [skuRows]);
  const orphanStoreCount = useMemo(
    () => storeCols.filter((c) => c.state !== "active").length,
    [storeCols],
  );

  const readOnly = draft?.status === "done";

  async function sessionInfo() {
    const { data } = await getSupabase().auth.getSession();
    const tenantId = (data.session?.user?.app_metadata as Record<string, unknown> | undefined)
      ?.tenant_id as string | undefined;
    if (!tenantId) throw new Error("JWT 缺 tenant_id claim、無法存檔");
    return { tenantId, uid: data.session?.user?.id ?? null };
  }

  // ---- 改數量（blur 才寫 DB）----
  async function commitCell(skuId: number, storeId: number) {
    const key = cellKey(skuId, storeId);
    const raw = edits.get(key);
    if (raw === undefined) return;

    const clearEdit = () =>
      setEdits((m) => {
        const next = new Map(m);
        next.delete(key);
        return next;
      });

    const n = raw.trim() === "" ? 0 : Number(raw);
    if (!Number.isFinite(n) || n < 0) {
      setError("數量要是 0 或正數");
      clearEdit(); // 回復成 DB 裡的值，不留一個看起來已改、其實沒存的格子
      return;
    }

    const existing = itemsByKey.get(key);
    if (existing && Number(existing.qty) === n) {
      clearEdit();
      return;
    }

    setError(null);
    try {
      const sb = getSupabase();
      const { tenantId, uid } = await sessionInfo();
      if (existing) {
        const { error: err } = await sb
          .from("picking_draft_items")
          .update({ qty: n, updated_by: uid })
          .eq("id", existing.id);
        if (err) throw err;
        setItems((arr) => arr.map((it) => (it.id === existing.id ? { ...it, qty: n } : it)));
      } else {
        // 這格還沒有列：加入這樣商品之後才啟用（或才被撈出來）的分店。
        // 品號/品名沿用同商品其他列的快照值；分店名稱取「現在這一欄」的值
        // （這一欄可能來自 stores 現況，也可能來自別列的分店快照，兩者都對）。
        //
        // ⭐ 數量快照**當下重拍一次**，不留一堆 NULL：
        //   切片 B 的「對照現況」要拿快照當基準算落差，同一張草稿裡有些格子有基準、
        //   有些沒有，落差就算不出來。所以這裡照樣去讀一次需求。
        //   讀失敗**不擋這次改數量**（使用者的意圖是填數字，快照只是附帶的中繼資料），
        //   但一定要在 snapshot_extra 標記原因 —— ⛔ 不可以讓切片 B 面對裸 NULL 去猜。
        const sibling = items.find((it) => it.sku_id === skuId);
        const col = storeCols.find((c) => c.id === storeId);
        let pre: PrefillResult | null = null;
        try {
          pre = await loadPrefill({ db: sb, fetchAll: fetchAllRows }, skuId);
        } catch {
          pre = null; // lateCellSnapshot 會標 demand_lookup: "failed"
        }
        const { data, error: err } = await sb
          .from("picking_draft_items")
          .insert({
            tenant_id: tenantId,
            draft_id: draftId,
            sku_id: skuId,
            store_id: storeId,
            qty: n,
            snapshot_sku_code: sibling?.snapshot_sku_code ?? null,
            snapshot_sku_label: sibling?.snapshot_sku_label ?? null,
            snapshot_store_code: col?.code ?? null,
            snapshot_store_name: col?.name ?? null,
            ...lateCellSnapshot(pre, storeId, new Date().toISOString()),
            created_by: uid,
            updated_by: uid,
          })
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name")
          .single();
        if (err) throw err;
        setItems((arr) => [...arr, data as DraftItem]);
      }
      clearEdit();
    } catch (e) {
      setError(describeDraftDbError(e));
      clearEdit();
    }
  }

  // ---- 加入商品：替**所有啟用分店**各建一列，數量帶出「各店還沒派的需求」----
  async function addSku(opt: SkuOption) {
    if (skuRows.some((r) => r.sku_id === opt.id)) {
      setError(`「${opt.product_name}」已經在這張草稿裡了`);
      return;
    }
    if (stores.length === 0) {
      setError("撈不到任何啟用中的分店，無法加入商品");
      return;
    }
    setError(null);
    setNotice(null);

    // ⛔ 先把需求讀起來。讀不到就**整個中止、商品不加進去**。
    //   不可以退回「空需求」照樣建 14 個 0 的列 —— 那跟「真的沒人要」長得一模一樣，
    //   老闆會分不出是壞掉還是真的沒有，然後把錯的清單印給樓下去撿。
    let pre: PrefillResult;
    try {
      pre = await loadPrefill({ db: getSupabase(), fetchAll: fetchAllRows }, opt.id);
    } catch (e) {
      setError(
        addOutcomeMessage({
          kind: "failed",
          productName: opt.product_name,
          reason: describeDraftDbError(e),
        }),
      );
      return; // ⛔ 這個 return 就是 P1-1 的修法：下面那段 insert 根本不會跑到
    }

    try {
      const sb = getSupabase();
      const { tenantId, uid } = await sessionInfo();
      const label = `${opt.product_name}${opt.variant_name ? ` ${opt.variant_name}` : ""}`;
      const now = new Date().toISOString();
      const { data, error: err } = await sb
        .from("picking_draft_items")
        .insert(
          stores.map((st) => {
            const p = pre.byStore.get(st.id);
            return {
              tenant_id: tenantId,
              draft_id: draftId,
              sku_id: opt.id,
              store_id: st.id,
              // 帶出「這家店還沒派的需求」，已夾在可分配量之內（見 computePrefill）
              qty: p?.give ?? 0,
              snapshot_at: now,
              snapshot_sku_code: opt.sku_code,
              snapshot_sku_label: label,
              // 分店名稱也拍下來：store_id 沒有外鍵，分店被硬刪之後
              // 畫面與列印都還要說得出「原本要給哪一家」，不能只剩一個 #id
              snapshot_store_code: st.code,
              snapshot_store_name: st.name,
              // 快照：加入當下的「未派需求」與「可分配量」，切片 B 對照現況要用
              snapshot_demand_qty: p?.demandLeft ?? 0,
              snapshot_available_qty: pre.available,
              snapshot_close_date: pre.closeDate,
              // 標明這一格的快照是「加入商品那一刻」拍的。後來才補的格子會標
              // cell_created_later —— 切片 B 要分得出來，不能靠欄位是不是 NULL 去猜。
              snapshot_extra: { ...pre.extra, snapshot_source: "add_sku" },
              created_by: uid,
              updated_by: uid,
            };
          }),
        )
        .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name");
      if (err) throw err;
      setItems((arr) => [...arr, ...((data ?? []) as DraftItem[])]);

      // 帶出來的量與實際需求對不上時一定要講出來。
      // ⚠ 「查詢正常但沒需求」與上面「讀取失敗」的畫面都是一排 0，只能靠訊息分辨
      //   → 措辭由 addOutcomeMessage 統一維護，避免哪天改了一句忘了另一句。
      let demandTotal = 0;
      let giveTotal = 0;
      for (const st of stores) {
        const p = pre.byStore.get(st.id);
        demandTotal += p?.demandLeft ?? 0;
        giveTotal += p?.give ?? 0;
      }
      setNotice(
        addOutcomeMessage({
          kind: classifyAddOutcome(demandTotal, giveTotal),
          productName: opt.product_name,
          demandTotal,
          giveTotal,
          available: pre.available,
        }),
      );
    } catch (e) {
      setError(describeDraftDbError(e));
    }
  }

  // ---- 刪商品：整列（該 SKU 的所有分店格子）一起刪 ----
  async function removeSku(skuId: number, label: string) {
    if (!confirm(`把「${label}」從這張草稿移除？（只動草稿，不影響任何庫存或訂單）`)) return;
    setError(null);
    setNotice(null); // 剛才那則「已加入 …」講的可能就是這一樣，留著會對不上
    try {
      const { error: err } = await getSupabase()
        .from("picking_draft_items")
        .delete()
        .eq("draft_id", draftId)
        .eq("sku_id", skuId);
      if (err) throw err;
      setItems((arr) => arr.filter((it) => it.sku_id !== skuId));
    } catch (e) {
      setError(describeDraftDbError(e));
    }
  }

  async function saveName() {
    if (!draft) return;
    const name = nameDraft.trim();
    if (!name) {
      // 名字被清空 → 不存空字串，把畫面回復成 DB 裡的名字（不要留一個「看起來改了、其實沒存」的框）
      setNameDraft(draft.name);
      return;
    }
    if (name === draft.name) return;
    setError(null);
    try {
      const sb = getSupabase();
      const { uid } = await sessionInfo();
      const { error: err } = await sb
        .from("picking_drafts")
        .update({ name, updated_by: uid })
        .eq("id", draftId);
      if (err) throw err;
      setDraft({ ...draft, name });
    } catch (e) {
      setError(describeDraftDbError(e));
    }
  }

  async function setStatus(status: "draft" | "done") {
    setError(null);
    try {
      const sb = getSupabase();
      const { uid } = await sessionInfo();
      const { error: err } = await sb
        .from("picking_drafts")
        .update({ status, updated_by: uid })
        .eq("id", draftId);
      if (err) throw err;
      setDraft((d) => (d ? { ...d, status } : d));
    } catch (e) {
      setError(describeDraftDbError(e));
    }
  }

  const inputCls =
    "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  if (!draft) {
    return (
      <div className="flex flex-col gap-3 p-6">
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error ?? (validId ? "找不到這張草稿" : "網址缺少草稿編號（?id=）")}
        </div>
        <Link href="/picking/drafts" className="text-sm underline">
          ← 回草稿列表
        </Link>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-col gap-2">
        <Link href="/picking/drafts" className="w-fit text-xs text-zinc-500 underline-offset-2 hover:underline">
          ← 回草稿列表
        </Link>
        <div className="flex flex-wrap items-center gap-2">
          <input
            value={nameDraft}
            onChange={(e) => setNameDraft(e.target.value)}
            onBlur={() => void saveName()}
            disabled={readOnly}
            aria-label="草稿名稱"
            className={`${inputCls} min-w-60 flex-1 text-base font-semibold disabled:opacity-60`}
          />
          <span
            className={
              readOnly
                ? "rounded-full bg-zinc-200 px-2.5 py-1 text-xs text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200"
                : "rounded-full bg-emerald-100 px-2.5 py-1 text-xs text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
            }
          >
            {readOnly ? "已完成" : "進行中"}
          </span>
          <SpinButton
            onClick={() => setStatus(readOnly ? "draft" : "done")}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            {readOnly ? "重新開啟" : "標記完成"}
          </SpinButton>
          <SpinButton
            onClick={load}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            重新整理
          </SpinButton>
        </div>
        <p className="text-sm text-zinc-500">
          改這裡<strong className="text-zinc-700 dark:text-zinc-300">不會動到派貨工作台的數字、也不會扣任何庫存</strong>。
          每一格離開輸入框就自動存檔；另一台 iPad 按「重新整理」看得到。
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

      {(orphanSkuCount > 0 || orphanStoreCount > 0) && (
        // 草稿不綁外鍵 → 可能引用到已刪除的商品／分店。這裡先總結一句，
        // 表格裡再逐列 / 逐欄標黃，⛔ 不靜默把它們藏起來。
        <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          這張草稿裡有東西在系統中已經不存在了：
          {orphanSkuCount > 0 && <> <strong>{orphanSkuCount} 樣商品</strong>已被刪除</>}
          {orphanSkuCount > 0 && orphanStoreCount > 0 && "、"}
          {orphanStoreCount > 0 && <> <strong>{orphanStoreCount} 個分店</strong>已停用或被刪除</>}
          。
          數量都還在（下面標黃色的就是），顯示的是<strong>加入當下的名稱</strong>；
          要移除請按該列的「移除」。
        </div>
      )}

      {readOnly ? (
        <p className="rounded-md border border-zinc-300 bg-zinc-50 p-3 text-sm text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400">
          這張草稿已標記完成，先按「重新開啟」才能繼續改。
        </p>
      ) : (
        <AddSkuBox onPick={addSku} inputCls={inputCls} />
      )}

      {skuRows.length === 0 ? (
        <p className="rounded-md border border-dashed border-zinc-300 p-6 text-sm text-zinc-500 dark:border-zinc-700">
          還沒加任何商品 — 用上面的搜尋框打商品名稱或品號，找到就按下去加進來。
        </p>
      ) : (
        <div className="overflow-x-auto rounded-md border border-zinc-200 dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 dark:bg-zinc-900">
              <tr className="text-xs uppercase tracking-wide text-zinc-500">
                <th className="sticky left-0 z-10 min-w-56 border-r border-zinc-200 bg-zinc-50 px-3 py-2 text-left dark:border-zinc-800 dark:bg-zinc-900">
                  商品
                </th>
                {storeCols.map((st) => (
                  <th
                    key={st.id}
                    className={`whitespace-nowrap px-2 py-2 text-center ${
                      st.state === "active" ? "" : "bg-amber-50 dark:bg-amber-950/40"
                    }`}
                    title={st.state === "active" ? st.name : `${st.name}（${STORE_STATE_LABEL[st.state]}）`}
                  >
                    {st.name}
                    {st.state !== "active" && (
                      <div className="font-normal normal-case text-amber-700 dark:text-amber-400">
                        {STORE_STATE_LABEL[st.state]}
                      </div>
                    )}
                  </th>
                ))}
                <th className="whitespace-nowrap px-3 py-2 text-right">合計</th>
                <th className="px-2 py-2"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {skuRows.map((row) => (
                <tr key={row.sku_id}>
                  <th className="sticky left-0 z-10 border-r border-zinc-200 bg-white px-3 py-2 text-left font-normal dark:border-zinc-800 dark:bg-zinc-950">
                    <div className="text-sm font-medium text-zinc-900 dark:text-zinc-100">{row.label}</div>
                    <div className="font-mono text-xs text-zinc-400">{row.code}</div>
                    {row.missing && (
                      // 商品在 skus 裡查不到了（草稿不綁外鍵，見 migration 檔頭）。
                      // 照樣顯示快照名稱＋明講狀況，⛔ 不靜默跳過這一列。
                      <div className="mt-0.5 text-xs font-medium text-amber-700 dark:text-amber-400">
                        ⚠ 此商品已不存在（顯示的是加入當下的名稱）
                      </div>
                    )}
                  </th>
                  {storeCols.map((st) => {
                    const key = cellKey(row.sku_id, st.id);
                    const stored = itemsByKey.get(key)?.qty;
                    const value = edits.get(key) ?? (stored === undefined ? "0" : String(Number(stored)));
                    return (
                      <td
                        key={st.id}
                        className={`px-1 py-1 text-center ${
                          st.state === "active" ? "" : "bg-amber-50 dark:bg-amber-950/40"
                        }`}
                      >
                        <input
                          type="number"
                          inputMode="numeric"
                          min="0"
                          step="1"
                          value={value}
                          disabled={readOnly}
                          aria-label={`${row.label} / ${st.name} 數量`}
                          onChange={(e) => {
                            const v = e.target.value;
                            setEdits((m) => new Map(m).set(key, v));
                          }}
                          onBlur={() => void commitCell(row.sku_id, st.id)}
                          className="w-16 rounded border border-zinc-300 bg-white px-1 py-1 text-center text-sm disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800"
                        />
                      </td>
                    );
                  })}
                  {/* 合計直接從明細加總，不是加總畫面上的欄位 —— 少一欄也不會跟著算少 */}
                  <td className="px-3 py-2 text-right font-mono font-medium">{rowTotal(items, row.sku_id)}</td>
                  <td className="px-2 py-2 text-right">
                    {!readOnly && (
                      <SpinButton
                        onClick={() => removeSku(row.sku_id, row.label)}
                        className="rounded border border-red-300 px-2 py-1 text-xs text-red-700 hover:bg-red-50 dark:border-red-900 dark:text-red-400"
                      >
                        移除
                      </SpinButton>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p className="text-xs text-zinc-400">
        共 {skuRows.length} 樣商品 × {storeCols.length} 個分店欄位
        {orphanStoreCount > 0 && `（其中 ${orphanStoreCount} 個已停用／已刪除）`}。
        「對照現況」「列印」「送到派貨工作台」是後續切片，這一版還沒有。
      </p>
    </div>
  );
}

// 商品搜尋（名稱 / 品號）。查的是 skus 主檔而不是派貨工作台的需求清單 ——
// 老闆要的正是「包子媽突然要插商品進來」，那種商品在需求清單裡根本不會出現。
// 查法沿用 restock/new 的既有寫法（active + 非虛擬商品）。
function AddSkuBox({ onPick, inputCls }: { onPick: (o: SkuOption) => Promise<void>; inputCls: string }) {
  const [term, setTerm] = useState("");
  const [opts, setOpts] = useState<SkuOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [open, setOpen] = useState(false);

  // 與 restock/new 的搜尋幾乎相同，只有一處刻意不一樣：spinner 改在 debounce 之後才打開，
  // 讓 effect body 沒有同步 setState（react-hooks/set-state-in-effect）。
  // 行為差別只有「spinner 晚 200ms 出現」；下拉關掉時 timer 被 clear，不會留下轉不停的 spinner。
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      setSearching(true);
      try {
        const sb = getSupabase();
        let q = sb
          .from("skus")
          .select("id, sku_code, variant_name, products!inner(name, is_virtual)")
          .eq("status", "active")
          .eq("products.is_virtual", false)
          .limit(15);
        const safe = term.replace(/[%,()]/g, " ").trim();
        if (safe) q = q.or(`sku_code.ilike.%${safe}%,product_name.ilike.%${safe}%,variant_name.ilike.%${safe}%`);
        const { data } = await q;
        // 已經換字 / 關掉下拉了就丟掉這批結果，避免慢的舊查詢蓋掉新的
        if (cancelled) return;
        setOpts(
          ((data ?? []) as unknown as Array<{
            id: number;
            sku_code: string;
            variant_name: string | null;
            products: { name: string; is_virtual: boolean };
          }>).map((s) => ({
            id: s.id,
            sku_code: s.sku_code,
            variant_name: s.variant_name,
            product_name: s.products.name,
          })),
        );
      } finally {
        setSearching(false);
      }
    }, 200);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [term, open]);

  return (
    <div className="relative flex flex-col gap-1 sm:max-w-lg">
      <span className="text-xs font-medium text-zinc-500">加入商品（搜尋名稱 / 品號）</span>
      <div className="relative">
        <input
          value={term}
          onFocus={() => setOpen(true)}
          onChange={(e) => {
            setTerm(e.target.value);
            setOpen(true);
          }}
          placeholder="打商品名稱或品號…"
          aria-label="搜尋商品名稱或品號"
          className={`${inputCls} w-full pr-8`}
        />
        <SearchSpinner active={searching} />
      </div>
      {open && opts.length > 0 && (
        <div
          className="absolute left-0 top-full z-20 mt-1 max-h-72 w-full overflow-y-auto rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800"
          onMouseLeave={() => setOpen(false)}
        >
          {opts.map((o) => (
            <SpinButton
              key={o.id}
              type="button"
              onClick={async () => {
                await onPick(o);
                setTerm("");
                setOpen(false);
              }}
              className="block w-full px-3 py-2 text-left text-sm hover:bg-zinc-100 dark:hover:bg-zinc-700"
            >
              <span className="font-medium">{o.product_name}</span>
              {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
              <span className="ml-2 font-mono text-xs text-zinc-400">{o.sku_code}</span>
            </SpinButton>
          ))}
        </div>
      )}
    </div>
  );
}
