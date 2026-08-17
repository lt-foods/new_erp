"use client";

// 派貨草稿 — 編輯（切片 A）
//
// 矩陣：商品(SKU) × 分店。樓下可以「增商品 / 刪商品 / 改任一格數量」（老闆 2026-08-17 拍板）。
//
// ⭐ 分店欄位的來源是**另外撈 stores 全表**（含停用、帶 is_active），不是沿用派貨工作台的 allStores。
//    理由（老闆）：「有可能有庫存就會多給沒下訂單的店家內部」。
//    派貨工作台的 allStores 只收「demand 裡出現過的店」（wms/picking/page.tsx:813-826），
//    沒下訂單的店在那邊連欄位都不存在。
//    ⚠ 撈全表 **≠** 全部都變成欄位：實際顯示哪幾欄由 buildStoreColumns 決定 ——
//      「停用且這張草稿數量合計 0」的不顯示（老闆 2026-08-17：「已停用的店家就不用出現了」）。
//
// ⛔ 本檔只讀寫 picking_drafts / picking_draft_items 兩張新表，外加**唯讀** stores / skus / products。
//    不呼叫任何庫存或建單 RPC、不寫入任何既有表、完全不扣庫存。
//
// 存檔時機：每一格「離開輸入框(blur)就立刻寫 DB」。樓下是共用總部帳號 + 多台 iPad，
//    留一堆未存檔的暫存狀態最危險（換人接手就掉了）。

import Link from "next/link";
import { Suspense, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import {
  addBatchMessage,
  buildSkuRows,
  buildStoreColumns,
  describeDraftDbError,
  lateCellSnapshot,
  loadPrefill,
  rowTotal,
  type AddBatchReport,
  type PrefillResult,
  type SkuExistence,
  type StoreRow,
} from "@/lib/pickingDraftView";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { withBasePath } from "@/lib/basePath";

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

type Store = StoreRow;

type SkuOption = {
  id: number;
  sku_code: string;
  variant_name: string | null;
  product_name: string;
};

const cellKey = (skuId: number, storeId: number) => `${skuId}:${storeId}`;

/**
 * 訊息裡要怎麼稱呼一樣商品。
 *
 * ⚠⚠ **一定要帶上規格名**，不可以只用 product_name —— 這正是老闆這次的情境：
 *   搜「花蓮阿咘」跳出的 7 列，product_name 全都是「花蓮阿咘吉手作泡菜系列」，
 *   差別只在 variant_name（A：韓式辣味泡菜 … G：蔭鳳梨）。
 *   只印 product_name 的話，「這 2 樣沒有加入草稿」會印出兩個一模一樣的名字，
 *   老闆根本看不出是哪兩個 —— 等於沒講（本專案最忌諱的那種「講了等於沒講」）。
 * ⓘ 分隔符與下拉、勾選清單上看到的一致（「品名 / 規格」），才對得起來。
 */
const skuDisplayName = (o: SkuOption) =>
  `${o.product_name}${o.variant_name ? ` / ${o.variant_name}` : ""}`;

const STORE_STATE_LABEL = { inactive: "已停用", missing: "已刪除", unknown: "無法確認" } as const;

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
  const [extraStores, setExtraStores] = useState<Map<number, Store> | null>(new Map());
  // 目前 skus 還查得到的 id；null = 這次查不出來 → 一律不標「商品已不存在」
  // 商品存在性：三態（見 SkuExistence）。⛔ 不要用 null 同時表達「異常」與「不標記」
  const [skuExistence, setSkuExistence] = useState<SkuExistence>({ kind: "unknown", confirmedIds: new Set() });
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
        // ⭐ 這裡撈的是 stores **全表（含停用）**，「哪些欄位要顯示」由 buildStoreColumns 決定
        //   （停用且這張草稿數量合計為 0 的才藏起來，老闆 2026-08-17 定案）。
        //   ⛔ 不可以在查詢就 .eq("is_active", true) 先濾掉：那樣「停用但草稿裡有數量」的店
        //   會掉進 extraStores 的路徑，被標成「已刪除／無法確認」——說了一件不是事實的事。
        sb.from("stores").select("id, code, name, is_active").order("code"),
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

      const allStores = (storeRes.data ?? []) as Store[];

      // ---- 孤兒列的解析（sku_id / store_id 沒有外鍵，草稿可能引用到已刪除的東西）----
      // ⛔ 目的不是「濾掉」，是「查出來好標示」。查失敗一律退化成「不標記」，
      //    絕不因為一次查詢失敗就把資料藏起來或對老闆說東西不見了。
      const listedIds = new Set(allStores.map((s) => Number(s.id)));
      const missingStoreIds = Array.from(new Set(cells.map((c) => c.store_id))).filter(
        (id) => !listedIds.has(Number(id)),
      );
      // ⛔ 查詢失敗要跟「查得到、但這幾家真的被刪了」分開：
      //   舊版沒有檢查 error，也在 catch 裡 extra.clear()，等於把「查不出來」
      //   直接說成「這些店都被刪了」。null = 無法確認（欄位標「無法確認」而不是「已刪除」）。
      let extra: Map<number, Store> | null = new Map<number, Store>();
      if (missingStoreIds.length > 0) {
        try {
          for (let i = 0; i < missingStoreIds.length; i += 200) {
            const { data: rows, error: e } = await sb
              .from("stores")
              .select("id, code, name")
              .in("id", missingStoreIds.slice(i, i + 200));
            if (e) throw e;
            for (const s of (rows ?? []) as Store[]) extra.set(Number(s.id), s);
          }
        } catch {
          extra = null;
        }
      }

      const skuIds = Array.from(new Set(cells.map((c) => Number(c.sku_id))));
      // 空草稿 = 沒有東西要查，結果就是「確實空集合」——那是事實，不是異常（阿審 P2-1）。
      // 這樣之後首次加入商品才補得進集合。
      let existence: SkuExistence = { kind: "known", ids: new Set<number>() };
      let skuCheckWarning: string | null = null;
      if (skuIds.length > 0) {
        try {
          const found = new Set<number>();
          for (let i = 0; i < skuIds.length; i += 200) {
            const { data: rows, error: e } = await sb
              .from("skus")
              .select("id")
              .in("id", skuIds.slice(i, i + 200));
            if (e) throw e;
            for (const s of (rows ?? []) as { id: number }[]) found.add(Number(s.id));
          }
          // ⭐⭐ 一樣都沒對上 ≠「這張草稿的商品全部被刪了」。
          //   草稿裡的商品都是從 skus 搜出來加進去的，整批對不上遠比「整批被刪」更可能是
          //   查詢異常（權限、型別、篩選）。這種時候寧可**不標記**，也不要嚇使用者說資料壞了。
          //   —— 與上一輪修掉的 P1-1 是同一個病：系統異常偽裝成資料狀態。
          // ⭐ 一樣都沒對上：可能是查詢異常，也可能真的整批被刪了 —— 從前端分不出來。
          //   ⛔ 不可以靜靜放過（那會讓「真的全被刪」看起來一切正常，阿審 P1），
          //   也不該武斷說「都被刪了」→ 一律標「無法確認」，並在畫面上說清楚。
          if (found.size === 0) {
            existence = { kind: "unknown", confirmedIds: new Set() };
            skuCheckWarning =
              `無法確認這張草稿裡 ${skuIds.length} 樣商品是否還在商品主檔（查詢回傳空的）—— ` +
              `表格內會標「無法確認」。可能是查詢異常，也可能這些商品真的都被刪了，請通知工程師確認。`;
          } else {
            existence = { kind: "known", ids: found };
          }
        } catch {
          existence = { kind: "unknown", confirmedIds: new Set() };
          skuCheckWarning = `無法確認這張草稿裡的商品是否還在商品主檔（查詢失敗）—— 表格內會標「無法確認」。`;
        }
      }

      setError(null);
      // 重新整理 = 重新看現況；若商品存在性查不出來，這裡會帶出可讀提示
      setNotice(skuCheckWarning);
      setDraft(head as Draft);
      setNameDraft((head as Draft).name);
      setStores(allStores);
      setExtraStores(extra);
      setSkuExistence(existence);
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
  // 「已停用」的分店只有在這張草稿還有數量時才留欄位（並標「已停用」），零數量的不顯示；
  // 「已刪除 / 無法確認」一律照樣顯示並標示。判準與理由見 lib/pickingDraftView.ts。
  const skuRows = useMemo(() => buildSkuRows(items, skuExistence), [items, skuExistence]);
  const storeCols = useMemo(
    () => buildStoreColumns(stores, items, extraStores),
    [stores, items, extraStores],
  );
  // 搜尋下拉要標得出「這樣我已經加過了」，才不會重複加（也不會白按一次才被擋）
  const inDraftSkuIds = useMemo(() => new Set(skuRows.map((r) => r.sku_id)), [skuRows]);
  const missingSkuCount = useMemo(() => skuRows.filter((r) => r.state === "missing").length, [skuRows]);
  const unknownSkuCount = useMemo(() => skuRows.filter((r) => r.state === "unknown").length, [skuRows]);
  const orphanSkuCount = missingSkuCount + unknownSkuCount;
  const orphanStoreCount = useMemo(
    () => storeCols.filter((c) => c.state !== "active").length,
    [storeCols],
  );
  // 被藏起來的停用分店有幾家。⛔ 不能完全不提：把某一格改成 0 之後，那一欄會**當場消失**
  //   （storeCols 是跟著 items 重算的），老闆會以為自己按壞了什麼。
  //   一行小字說明「藏起來了，因為數量都是 0」就夠 —— 老闆要的是紙上不要有那些欄，
  //   不是連「有這回事」都不知道。
  const hiddenInactiveCount = useMemo(() => {
    const shown = new Set(storeCols.map((c) => c.id));
    return stores.filter((s) => s.is_active === false && !shown.has(Number(s.id))).length;
  }, [stores, storeCols]);

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

  // ---- 加入商品：替 stores **全表（含停用）** 各建一列，數量帶出「各店還沒派的需求」----
  //
  // ⚠ 是「全表」不是「啟用分店」—— stores 就是上面撈回來的全表。停用分店照樣建一列，
  //   但它幾乎不會有未派需求 → qty = 0 → buildStoreColumns 會把那一欄藏起來，畫面與紙上都看不到。
  //   萬一它真的還有未派需求，那一列就有量、欄位會照樣顯示並標「已停用」——
  //   正是「有量的一定要留」那條規則要保住的東西（見 lib/pickingDraftView.ts）。
  // ⭐ 一次可以加一整批（老闆 2026-08-17：搜「花蓮阿咘」跳出同系列 7 個口味，
  //   本來就會一起撿，不該一個一個點）。
  //
  //   做法是**逐樣跑完整的單樣流程**，⛔ 不是把 N 樣合併成一次大查詢：
  //     - 每一樣各自 loadPrefill、各自 insert → 某一樣壞掉，其他樣照樣進得去
  //     - 語意與「一次加一樣」逐字相同（同一支 loadPrefill、同一份 insert 欄位），
  //       不可能因為改走批次而漂移
  //   代價是 N 次往返。但這正是「哪幾樣沒進去」講得出來的原因 —— 值得。
  //
  // ⛔ 回傳「失敗的 sku_id」而不是 void：呼叫端要拿它**留住勾選**讓老闆直接重試。
  //   回 void 就等於逼他把那幾樣重挑一次，而且訊息一關就再也不知道是哪幾樣 ——
  //   那正是本專案最痛的那種靜默丟失。
  async function addSkus(opts: SkuOption[]): Promise<number[]> {
    if (opts.length === 0) return [];
    if (stores.length === 0) {
      setError("撈不到任何啟用中的分店，無法加入商品");
      return opts.map((o) => o.id); // 全部留在勾選裡
    }
    setError(null);
    setNotice(null);

    // 身分只取一次：整批共用，而且拿不到就**一樣都加不了** ——
    // 這是批次層級的失敗，不是「某幾樣」的失敗，訊息要講成整批沒進去。
    let tenantId: string;
    let uid: string | null;
    try {
      ({ tenantId, uid } = await sessionInfo());
    } catch (e) {
      setError(`${describeDraftDbError(e)}（一樣都沒有加進去，勾選都還留著。）`);
      return opts.map((o) => o.id);
    }

    // 已經在草稿裡的：略過但**明講**，不重複插入、也不算失敗。
    // ⚠ 這個集合在迴圈開始前算一次就好：opts 每一樣的 id 都不同（來源是以 id 為 key 的 Map），
    //   而 skuRows 是 items 的 memo、迴圈中本來就不會同步更新。
    const inDraft = new Set(skuRows.map((r) => r.sku_id));
    const report: AddBatchReport = { added: [], skipped: [], failed: [] };
    const failedIds: number[] = [];

    for (const opt of opts) {
      if (inDraft.has(opt.id)) {
        report.skipped.push(skuDisplayName(opt));
        continue;
      }
      try {
        // ⛔ 先把需求讀起來。讀不到就**這一樣不加**（不是整批中止，更不是退回空需求）。
        //   退回「空需求」照樣建一排 0 的列，畫面跟「真的沒人要」長得一模一樣，
        //   老闆分不出是壞掉還是真的沒有，然後把錯的清單印給樓下去撿。
        //   ⚠ loadPrefill 是**刻意不 catch** 的，就是要在這裡被擋下來 ——
        //     ⛔ 不可以為了讓批次「順利跑完」而放寬成 try/空值。
        const sb = getSupabase();
        const pre: PrefillResult = await loadPrefill({ db: sb, fetchAll: fetchAllRows }, opt.id);
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
        // ⭐ 每成功一樣就立刻進畫面（functional updater，不怕批次更新交錯）——
        //   第 3 樣掛掉時，前兩樣已經看得到，不會整批一起消失。
        setItems((arr) => [...arr, ...((data ?? []) as DraftItem[])]);
        // ⭐⭐ existingSkuIds 原本只在 load() 算一次，加完商品只更新了 items、沒更新它
        //   → 新加的商品必然不在那個舊集合裡，於是每一樣剛加進去的都被標成
        //   「⚠ 此商品已不存在」。這樣商品是剛從 skus 搜出來的，存在性無庸置疑
        //   → 直接補進集合（PR #751）。
        // ⭐ 不論先前是 known 還是 unknown，剛加進來的商品都是**確定存在**的
        //   → 兩種狀態都要記住，否則整批查詢異常之後新加的商品也會被標
        //   「無法確認」（阿審 #751 複審 P2）。
        setSkuExistence((prev) =>
          prev.kind === "known"
            ? { kind: "known", ids: new Set(prev.ids).add(Number(opt.id)) }
            : { kind: "unknown", confirmedIds: new Set(prev.confirmedIds).add(Number(opt.id)) },
        );

        // 帶出來的量與實際需求對不上時一定要講出來。
        // ⚠ 「查詢正常但沒需求」與「讀取失敗」的畫面都是一排空格，只能靠訊息分辨
        //   → 措辭由 addBatchMessage / addOutcomeMessage 統一維護。
        let demandTotal = 0;
        let giveTotal = 0;
        for (const st of stores) {
          const p = pre.byStore.get(st.id);
          demandTotal += p?.demandLeft ?? 0;
          giveTotal += p?.give ?? 0;
        }
        report.added.push({
          name: skuDisplayName(opt),
          demandTotal,
          giveTotal,
          available: pre.available,
        });
      } catch (e) {
        // ⛔ 這一樣沒進去就是沒進去 —— 記下名字與原因，繼續跑下一樣。
        //   不 rethrow（會害後面幾樣連試都沒試），也不靜默（那是本專案的老毛病）。
        report.failed.push({ name: skuDisplayName(opt), reason: describeDraftDbError(e) });
        failedIds.push(opt.id);
      }
    }

    const msg = addBatchMessage(report);
    setNotice(msg.notice);
    setError(msg.error);
    return failedIds;
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
            // ⚠ 路徑一定要包 withBasePath，不可以直接寫裸路徑：
            //    本站是 output:"export" + basePath（next.config.ts，線上是 /new_erp）。
            //    <Link> / router.push 會自動補上 basePath，但 window.open **不會** ——
            //    裸路徑會開成 /picking/drafts/print 而不是 /new_erp/picking/drafts/print → 404。
            //    （本機沒設 NEXT_PUBLIC_BASE_PATH 時 withBasePath 原樣回傳，開發不受影響，
            //      所以這種錯在本機測不出來，只有線上會炸。）
            onClick={() =>
              window.open(withBasePath(`/picking/drafts/print?id=${draftId}`), "_blank")
            }
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            🖨 列印 / 匯出
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
          這張草稿裡有東西跟系統現況對不上：
          {missingSkuCount > 0 && <> <strong>{missingSkuCount} 樣商品</strong>在商品主檔已查不到</>}
          {missingSkuCount > 0 && unknownSkuCount > 0 && "、"}
          {unknownSkuCount > 0 && <> <strong>{unknownSkuCount} 樣商品</strong>無法確認是否還在商品主檔</>}
          {orphanSkuCount > 0 && orphanStoreCount > 0 && "、"}
          {orphanStoreCount > 0 && <> <strong>{orphanStoreCount} 個分店</strong>已停用／已刪除／無法確認</>}
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
        <AddSkuBox onAdd={addSkus} inDraft={inDraftSkuIds} inputCls={inputCls} />
      )}

      {skuRows.length === 0 ? (
        <p className="rounded-md border border-dashed border-zinc-300 p-6 text-sm text-zinc-500 dark:border-zinc-700">
          還沒加任何商品 — 用上面的搜尋框打商品名稱或品號，把要加的勾起來，再按「加入選取的 N 樣」。
          同一系列的多個口味可以一次勾完；換關鍵字再搜，先前勾的不會不見。
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
                    {row.state !== "active" && (
                      // 商品在 skus 裡查不到（草稿不綁外鍵，見 migration 檔頭）。
                      // 照樣顯示快照名稱＋明講狀況，⛔ 不靜默跳過這一列。
                      // ⭐ 「查不到」與「查不出來」是兩件事，字要不一樣。
                      <div className="mt-0.5 text-xs font-medium text-amber-700 dark:text-amber-400">
                        {row.state === "missing"
                          ? "⚠ 此商品已不存在（顯示的是加入當下的名稱）"
                          : "⚠ 無法確認此商品是否還在商品主檔（顯示的是加入當下的名稱）"}
                      </div>
                    )}
                  </th>
                  {storeCols.map((st) => {
                    const key = cellKey(row.sku_id, st.id);
                    const stored = itemsByKey.get(key)?.qty;
                    // 沒量的格子**留白**（placeholder 一個淡「－」），⛔ 不要顯示 0。
                    // 老闆原話：14 家店 × 一堆商品，滿畫面的 0 會把「真的要撿的數字」蓋掉。
                    // 「沒這一列」與「這一列是 0」在紙上、畫面上都是同一件事（都不用撿），
                    // 所以兩種都留白 —— 列印頁 drafts/print 早就是這樣印的（`q === 0 ? "－" : q`）。
                    //
                    // ⛔ 這只是**顯示**：存檔那條路一行都沒動。
                    //   - 老闆正在打字時 edits 有值 → 一律以 edits 為準，絕不蓋掉他打的東西
                    //   - 清空一格 → commitCell 的 `raw.trim() === "" ? 0` 照樣存成 0（本檔 :274）
                    //   - 從沒動過的格子 → commitCell 的 `raw === undefined` 直接 return，不寫 DB（本檔 :265）
                    //   合計走 rowTotal(items)、不看這個字串，所以改前改後完全一樣。
                    const edited = edits.get(key);
                    const value =
                      edited ?? (stored === undefined || Number(stored) === 0 ? "" : String(Number(stored)));
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
                          placeholder="－"
                          disabled={readOnly}
                          aria-label={`${row.label} / ${st.name} 數量`}
                          onChange={(e) => {
                            const v = e.target.value;
                            setEdits((m) => new Map(m).set(key, v));
                          }}
                          onBlur={() => void commitCell(row.sku_id, st.id)}
                          className="w-16 rounded border border-zinc-300 bg-white px-1 py-1 text-center text-sm placeholder:text-zinc-300 disabled:opacity-60 dark:border-zinc-700 dark:bg-zinc-800 dark:placeholder:text-zinc-600"
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
        {orphanStoreCount > 0 && `（其中 ${orphanStoreCount} 個已停用／已刪除／無法確認）`}。
        {hiddenInactiveCount > 0 &&
          `另有 ${hiddenInactiveCount} 家已停用的分店沒有顯示（這張草稿裡它們的數量都是 0，已經收掉的店不用再撿）。`}
        「對照現況」「列印」「送到派貨工作台」是後續切片，這一版還沒有。
      </p>
    </div>
  );
}

// 商品搜尋（名稱 / 品號）。查的是 skus 主檔而不是派貨工作台的需求清單 ——
// 老闆要的正是「包子媽突然要插商品進來」，那種商品在需求清單裡根本不會出現。
// 查法沿用 restock/new 的既有寫法（active + 非虛擬商品）。
//
// 老闆 2026-08-17 的實際情境：搜「花蓮阿咘」跳出同一系列 7 個口味（G01414-01…-07），
//   這種同商品多規格本來就會一起撿 → 每列勾選框 + 全選 + 「加入選取的 N 樣」。
//
// ⚠⚠ 勾選集合**獨立於目前的搜尋結果**，這是本元件最重要的一條：
//   PR #744 的根因就是「選取 ∩ 目前清單」—— 一改篩選條件就靜默丟掉勾選，畫面零提示。
//   所以這裡：
//     ① 勾選存的是**整個 SkuOption**（不只是 id），換搜尋字也補得出品名品號
//     ② 「加入」送出的是**全部勾選**，不是「目前看得到的勾選」
//     ③ 已勾選幾樣**隨時看得到**（在搜尋框上方，下拉蓋不到），可以逐樣檢視／移除
//   老闆可以搜「花蓮阿咘」勾 7 樣、再搜別的字勾更多，先前勾的一樣都不會消失。
function AddSkuBox({
  onAdd,
  inDraft,
  inputCls,
}: {
  /** 回傳「沒加成功、要留在勾選裡」的 sku_id（見 addSkus） */
  onAdd: (opts: SkuOption[]) => Promise<number[]>;
  /** 已經在這張草稿裡的 sku_id，用來標示、並停掉勾選框 */
  inDraft: Set<number>;
  inputCls: string;
}) {
  const [term, setTerm] = useState("");
  const [opts, setOpts] = useState<SkuOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [open, setOpen] = useState(false);
  // ⭐⭐ 存「整個 SkuOption」而不是只存 id —— 這是「換搜尋字不會弄丟勾選」能成立的關鍵：
  //   加入商品要寫 sku_code / 品名進快照欄位，只留 id 的話，不在目前搜尋結果裡的那幾樣
  //   根本補不出這些值 → 最後只好「只加看得到的」，就又變回 PR #744 那個靜默丟失。
  const [selected, setSelected] = useState<Map<number, SkuOption>>(new Map());
  const wrapRef = useRef<HTMLDivElement | null>(null);

  // 點外面才收起下拉。⛔ 不可以用 onMouseLeave（原本的寫法）：
  //   現在列上有勾選框，滑鼠一滑出去就關掉的話根本勾不完。寫法同 restock/new 的 MemberField。
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    return () => document.removeEventListener("mousedown", onDown);
  }, [open]);

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

  // 目前搜尋結果裡「還可以勾」的（已在草稿的不給勾，避免重複加）
  const selectable = opts.filter((o) => !inDraft.has(o.id));
  const chips = Array.from(selected.values());

  function toggle(o: SkuOption) {
    setSelected((prev) => {
      const next = new Map(prev);
      if (next.has(o.id)) next.delete(o.id);
      else next.set(o.id, o);
      return next;
    });
  }
  // 「全選」= 把目前搜尋結果**聯集**進勾選清單。
  // ⛔ 不是「取代」—— 取代會把先前搜別的關鍵字勾的那些洗掉。
  //   （語意刻意對齊派貨工作台的 addAllVisiblePicks，wms/picking/page.tsx。）
  function selectAllVisible() {
    setSelected((prev) => {
      const next = new Map(prev);
      for (const o of selectable) next.set(o.id, o);
      return next;
    });
  }
  // 「取消全選」只取消**目前搜尋結果**這幾筆（與「全選」對稱）。
  // 要全部清掉有下面那顆「清空勾選」—— 兩件事分開，才不會一鍵把 30 樣勾選誤清光。
  function clearVisible() {
    setSelected((prev) => {
      const next = new Map(prev);
      for (const o of opts) next.delete(o.id);
      return next;
    });
  }

  async function addSelected() {
    const submitted = chips.map((o) => o.id);
    const keep = await onAdd(chips);
    // ⭐ 只把「這次送出去、而且真的處理完了」的那幾樣拿掉（成功 or 本來就在草稿裡）。
    // ⛔ 不可以無條件 setSelected(new Map())：失敗的被清掉，老闆就得重挑一次，
    //   而且訊息一關就再也不知道是哪幾樣 —— 那是靜默丟失的另一種長相。
    // ⛔ 也不可以「從 keep 重建一個新 Map」：加入 7 樣要跑好幾秒，
    //   老闆在等的時候完全可以再勾第 8 樣。重建會把那一樣一起洗掉 ——
    //   同樣是「畫面零提示地弄丟勾選」，只是換個時間點發生。
    //   所以這裡是**減法**（只刪這次處理掉的），不是重建。
    const failedSet = new Set(keep);
    setSelected((prev) => {
      const next = new Map(prev);
      for (const id of submitted) if (!failedSet.has(id)) next.delete(id);
      return next;
    });
    setOpen(false);
    // 全部都進去了才清搜尋字；還有失敗的就留著，讓他看得到原本在找什麼
    if (keep.length === 0) setTerm("");
  }

  const toolBtnCls =
    "min-h-[44px] rounded-md border border-zinc-300 px-3 text-sm hover:bg-zinc-50 disabled:opacity-40 dark:border-zinc-700 dark:hover:bg-zinc-800";

  return (
    <div ref={wrapRef} className="flex flex-col gap-2 sm:max-w-xl">
      {/* ⭐ 已勾選清單放在搜尋框**上面**：下拉是絕對定位、會蓋住下方的東西，
          放下面就等於「打開下拉時看不到自己勾了什麼」。放上面才真的「隨時看得到」。 */}
      {chips.length > 0 && (
        <div className="flex flex-col gap-2 rounded-md border border-blue-300 bg-blue-50 p-2 dark:border-blue-900 dark:bg-blue-950/30">
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-blue-900 dark:text-blue-200">
              已勾選 {chips.length} 樣
            </span>
            <SpinButton
              type="button"
              onClick={addSelected}
              className="min-h-[44px] rounded-md bg-blue-600 px-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-40"
            >
              ＋ 加入選取的 {chips.length} 樣
            </SpinButton>
            <button type="button" onClick={() => setSelected(new Map())} className={toolBtnCls}>
              清空勾選
            </button>
          </div>
          <ul className="flex flex-wrap gap-1">
            {chips.map((o) => {
              const already = inDraft.has(o.id);
              return (
                <li
                  key={o.id}
                  className="flex items-center gap-1 rounded-full border border-blue-300 bg-white py-0.5 pl-2 pr-0.5 text-xs dark:border-blue-800 dark:bg-zinc-900"
                >
                  <span className="max-w-[16rem] truncate">
                    {o.product_name}
                    {o.variant_name && <span className="text-zinc-500"> / {o.variant_name}</span>}
                  </span>
                  <span className="font-mono text-[10px] text-zinc-400">{o.sku_code}</span>
                  {already && (
                    <span className="rounded bg-zinc-200 px-1 text-[10px] text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">
                      已在草稿
                    </span>
                  )}
                  <button
                    type="button"
                    onClick={() =>
                      setSelected((prev) => {
                        const next = new Map(prev);
                        next.delete(o.id);
                        return next;
                      })
                    }
                    aria-label={`取消勾選 ${o.product_name}`}
                    className="flex min-h-[32px] min-w-[32px] items-center justify-center rounded-full text-zinc-400 hover:bg-zinc-100 hover:text-zinc-700 dark:hover:bg-zinc-800 dark:hover:text-zinc-200"
                  >
                    ✕
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      )}

      <div className="relative flex flex-col gap-1">
        <span className="text-xs font-medium text-zinc-500">加入商品（搜尋名稱 / 品號）</span>
        <div className="relative">
          <input
            value={term}
            onFocus={() => setOpen(true)}
            onChange={(e) => {
              setTerm(e.target.value);
              setOpen(true);
            }}
            placeholder="打商品名稱或品號…（同系列多個口味可以勾起來一次加）"
            aria-label="搜尋商品名稱或品號"
            className={`${inputCls} w-full pr-8`}
          />
          <SearchSpinner active={searching} />
        </div>
        {open && opts.length > 0 && (
          <div className="absolute left-0 top-full z-20 mt-1 flex max-h-[70vh] w-full flex-col overflow-hidden rounded-md border border-zinc-200 bg-white shadow-lg dark:border-zinc-700 dark:bg-zinc-800">
            <div className="flex flex-wrap items-center gap-2 border-b border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-700 dark:bg-zinc-900">
              <button
                type="button"
                onClick={selectAllVisible}
                disabled={selectable.length === 0}
                className={toolBtnCls}
              >
                全選（這 {selectable.length} 筆）
              </button>
              <button
                type="button"
                onClick={clearVisible}
                disabled={!opts.some((o) => selected.has(o.id))}
                className={toolBtnCls}
              >
                取消全選
              </button>
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="ml-auto min-h-[44px] px-3 text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200"
              >
                收起
              </button>
            </div>
            <ul className="divide-y divide-zinc-100 overflow-y-auto dark:divide-zinc-700">
              {opts.map((o) => {
                const already = inDraft.has(o.id);
                const checked = selected.has(o.id);
                return (
                  <li
                    key={o.id}
                    className={`flex items-center gap-2 px-2 ${
                      checked && !already ? "bg-blue-50/60 dark:bg-blue-950/20" : ""
                    }`}
                  >
                    {/* 觸控目標 ≥ 44px：樓下是用 iPad 單手點的 */}
                    <label
                      className={`flex min-h-[44px] min-w-[44px] items-center justify-center ${
                        already ? "cursor-not-allowed" : "cursor-pointer"
                      }`}
                    >
                      <input
                        type="checkbox"
                        className="h-5 w-5 accent-blue-600"
                        checked={checked && !already}
                        disabled={already}
                        onChange={() => toggle(o)}
                        aria-label={`勾選 ${o.product_name}`}
                      />
                    </label>
                    <div className="min-w-0 flex-1 py-2 text-sm">
                      <span className="font-medium">{o.product_name}</span>
                      {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
                      <span className="ml-2 font-mono text-xs text-zinc-400">{o.sku_code}</span>
                    </div>
                    {already && (
                      // 已經加過的照樣列出來、但標明白 —— ⛔ 不從搜尋結果裡藏掉，
                      // 不然老闆會以為「怎麼搜不到這一樣」。
                      <span className="shrink-0 rounded bg-zinc-200 px-2 py-1 text-xs text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">
                        ✓ 已在草稿中
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          </div>
        )}
      </div>
    </div>
  );
}
