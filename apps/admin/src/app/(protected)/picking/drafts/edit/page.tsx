"use client";

// 撿貨草稿 — 編輯（切片 A）
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
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import {
  addBatchMessage,
  availableBySku,
  buildSkuRows,
  buildStoreColumns,
  checkedAtLabel,
  computeDraftPrecheck,
  computePrefillEven,
  describeDraftDbError,
  lateCellSnapshot,
  loadHqLocationId,
  loadPrecheckDemand,
  loadPrefill,
  loadSkuPreviewBatch,
  planEvenWrite,
  precheckHeadline,
  rowShortfall,
  rowTotal,
  skuPreviewCell,
  SKU_PREVIEW_ALL_FAILED,
  type AddBatchReport,
  type DraftPrecheck,
  type PrefillResult,
  type PreviewTone,
  type PrecheckSkuRef,
  type SkuExistence,
  type SkuPreviewBatch,
  type SkuPreviewCell,
  type SkuRow,
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
  /** 送到派貨工作台的時間；null = 還沒送過。⛔ 送過就永不清空（含按「重新開啟」），見 20260818000000 */
  dispatched_at: string | null;
  dispatched_by: string | null;
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

/**
 * 「已於 08/18 14:20 送出」的那個 08/18 14:20。
 *
 * ⛔ 不用 toLocaleString：各環境格式不一、測不起來（理由與 lib 的 checkedAtLabel 同一條）。
 * ⓘ 只顯示到分：這個時間是給老闆辨識「是不是我剛剛按的那次」，不是稽核用的精度。
 */
function dispatchedAtLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso; // 讀到怪值就原樣印出來，⛔ 不要印 NaN/NaN 讓人以為壞了
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getMonth() + 1)}/${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

/**
 * 【📤 送到派貨工作台】按下去、老闆還沒確定之前的那份待確認清單。
 *
 * ⭐ 與 DraftPrecheck 一樣做成 union，理由也一樣：**查詢失敗絕對不可以長得像「沒東西可送」**。
 *   兩者在畫面上都是「一樣都帶不過去」，但一個是系統壞了、一個是貨真的派完了 ——
 *   混在一起的話，老闆會以為今天的貨全被別人派走，然後去追一件根本沒發生的事。
 */
type DispatchPlan =
  | { kind: "failed"; reason: string }
  | {
      kind: "ready";
      at: string;
      /** 派貨工作台現在還有可分配量 → 帶得過去 */
      sendable: PrecheckSkuRef[];
      /** 工作台上已經沒有可分配量（被派完 / 還沒到貨）→ 帶不過去，⛔ 一定要逐項列出 */
      blocked: PrecheckSkuRef[];
    };

export default function PickingDraftEditPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const router = useRouter();
  const draftId = Number(useSearchParams().get("id"));
  const validId = Number.isFinite(draftId) && draftId > 0;
  const [draft, setDraft] = useState<Draft | null>(null);
  const [items, setItems] = useState<DraftItem[]>([]);
  const [stores, setStores] = useState<Store[]>([]);
  // 總倉的 location id，給搜尋下拉顯示「總倉庫存」用（載入時查一次，見 load()）。
  // null = 還沒載完、查不到、或根本沒有啟用中的總倉 → 那一欄顯示「查詢失敗」，⛔ 不顯示 0。
  const [hqLocationId, setHqLocationId] = useState<number | null>(null);
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
  // 「檢查」的結果。null = 這一頁還沒檢查過。
  // ⛔ 失敗與通過是 union 的兩個 kind，不可能不小心混在一起顯示（見 DraftPrecheck）。
  const [precheck, setPrecheck] = useState<DraftPrecheck | null>(null);
  // 檢查完之後草稿又被改過 → 結果已經不算數了。
  // ⛔ 不可以繼續原樣顯示那個綠色的「可以去建單」：老闆剛改完數量，
  //   畫面卻還掛著改之前的結論，等於系統對他說謊。
  //   ⚠ 也刻意**不直接清掉**：那樣結果會無聲消失，他會以為自己按到了什麼。
  const [precheckStale, setPrecheckStale] = useState(false);
  // 【📤 送到派貨工作台】按下去之後的待確認清單。null = 沒有待確認的送出。
  // ⛔ 按第一下**不會動任何資料**：先算給老闆看（帶得過去幾樣 / 哪幾樣帶不過去），
  //   他按【確定送過去】才真的標記 + 導頁。
  const [dispatchPlan, setDispatchPlan] = useState<DispatchPlan | null>(null);

  // ⚠ 第一件事就 await，不在 effect body 同步 setState（react-hooks/set-state-in-effect）
  const load = useCallback(async () => {
    if (!validId) return;
    try {
      const sb = getSupabase();
      const [{ data: head, error: headErr }, storeRes, hqLoc] = await Promise.all([
        sb
          .from("picking_drafts")
          .select("id, name, status, created_at, updated_at, dispatched_at, dispatched_by")
          .eq("id", draftId)
          .maybeSingle(),
        // ⭐ 這裡撈的是 stores **全表（含停用）**，「哪些欄位要顯示」由 buildStoreColumns 決定
        //   （停用且這張草稿數量合計為 0 的才藏起來，老闆 2026-08-17 定案）。
        //   ⛔ 不可以在查詢就 .eq("is_active", true) 先濾掉：那樣「停用但草稿裡有數量」的店
        //   會掉進 extraStores 的路徑，被標成「已刪除／無法確認」——說了一件不是事實的事。
        sb.from("stores").select("id, code, name, is_active").order("code"),
        // 總倉是哪一個 location —— 搜尋下拉那一列要顯示「總倉庫存」。
        // ⭐ 一頁只查這一次（總倉不會在使用中途換掉），搜尋時就不必再問一次：
        //   下拉每搜一次的額外查詢有 3 次的預算，這一次要省下來給那三個來源。
        // ⛔ 查不到不擋整頁 —— 草稿頁的主功能（改數量、檢查、列印）跟總倉庫存無關，
        //   所以這裡用 .catch 收成 null，讓那一欄顯示「查詢失敗」就好。
        loadHqLocationId({ db: sb }).catch(() => null),
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
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name, snapshot_at, snapshot_demand_qty, snapshot_available_qty")
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
      setHqLocationId(hqLoc);
      setExtraStores(extra);
      setSkuExistence(existence);
      setItems(cells);
      setEdits(new Map());
      // 重新載入 = 換一份現況（另一台 iPad 可能剛改過）→ 舊的檢查結論一律作廢。
      // ⛔ 不可以留著：它是對「上一份資料」下的結論。
      setPrecheck(null);
      setPrecheckStale(false);
      // 同理：待確認的送出清單是對「上一份資料」算的，重新載入就作廢，要重按一次。
      setDispatchPlan(null);
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
  // 送出過了沒 —— 判準**只有** dispatched_at，⛔ 刻意不看 status：
  //   按「重新開啟」把 status 轉回 draft 之後照樣不能再送（老闆 2026-08-18「不能重複轉」）。
  //   null = 沒送過。
  const dispatchedLabel = draft?.dispatched_at ? dispatchedAtLabel(draft.dispatched_at) : null;
  // 徽章要三態分得出來：⭐「送出過」與「只是收起來」在紙上、在流程上是完全不同的兩件事，
  //   老闆原話：「轉出跟標記完成意思太相同會讓人搞混」。
  const statusBadge = dispatchedLabel
    ? { text: `已送出 ${dispatchedLabel}`, cls: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300" }
    : readOnly
      ? { text: "已收起", cls: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200" }
      : { text: "進行中", cls: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300" };

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
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name, snapshot_at, snapshot_demand_qty, snapshot_available_qty")
          .single();
        if (err) throw err;
        setItems((arr) => [...arr, data as DraftItem]);
      }
      // 數字真的改了 → 先前那份檢查結果不算數了
      setPrecheckStale(true);
      // ⓘ 這裡刻意**不動** dispatchPlan：送出只帶商品、完全不看數量（老闆 2026-08-18），
      //   改一格數字不會讓「哪幾樣帶得過去」變成別的答案。⛔ 不要為了對稱把它加上來。
      //   （改數量也不會多出一樣商品：這一格所屬的那列本來就在草稿裡才點得到。）
      clearEdit();
    } catch (e) {
      setError(describeDraftDbError(e));
      clearEdit();
    }
  }

  // ---- 「⚖ 平均」：把這樣商品的可分配量平均分到還有需求的店 ----
  //
  // ⭐ 這是**多一個選項**，不是換掉原本的行為。老闆 2026-08-17 拍板：
  //   「加入商品」的自動預填維持「先來後到、前面吃滿後面掛 0」（貨不夠時讓一家真的能開賣，
  //   好過五家都缺貨賣不動）→ ⛔ computePrefill 一個字都沒動，這顆鈕走另一支 computePrefillEven。
  //
  // ⛔ 全程只寫 picking_draft_items 這一張表，與這一頁其他動作一樣：
  //   不碰派貨工作台、不扣庫存、不建任何單。讀的那一次（loadPrefill）也是純 SELECT。
  //
  // ⚠ 與派貨工作台那顆同名鈕最大的差別：**這裡的數字是存在資料庫的**。
  //   工作台按下去只改前端 state（送出時才寫），這一頁一按就是十幾格落地、而且沒有復原 ——
  //   所以（一）會蓋掉已填數字時要先問過，（二）分不出東西時**一格都不寫**，
  //   （三）寫失敗要逐格講出是哪幾家店。
  async function evenDistribute(row: SkuRow) {
    setError(null);
    setNotice(null);

    // ---- ⛔ 這一列還有格子正在編輯／還沒存好 → 先擋下來（阿審 2026-09-01 P1-2）----
    //
    // 情境：老闆在某一格打字，還沒點別的地方，就順手按同一列的「⚖ 平均」。
    //   滑鼠按下去會先讓輸入框 blur → `void commitCell(...)` 開始一條**沒有人在等**的寫入，
    //   而 SpinButton 只等自己的 onClick（components/SpinButton.tsx:36-42）。
    //   兩條路同時寫同一格 → 誰後到誰算數（平均寫完又被單格蓋回去），
    //   或兩邊都判斷「這格沒有列」而各插一次 → 撞 UNIQUE (draft_id, sku_id, store_id)。
    //
    // ⭐ 判斷來源用**既有的** `edits`（正在輸入、還沒 commit 的格子；commitCell 存完會清掉，
    //   成功、沒變、失敗三條路都會清），⛔ 不另外發明一套 pending 狀態，也 ⛔ 不用 setTimeout 猜時序。
    // ⓘ key 是 `${sku_id}:${store_id}`，帶冒號比對 → 商品 12 不會誤判成商品 123 的格子。
    const rowPrefix = `${row.sku_id}:`;
    const pendingStores = [...edits.keys()]
      .filter((k) => k.startsWith(rowPrefix))
      .map((k) => Number(k.slice(rowPrefix.length)));
    if (pendingStores.length > 0) {
      const names = pendingStores
        .map((sid) => storeCols.find((c) => c.id === sid)?.name ?? `分店 #${sid}`)
        .join("、");
      // ⓘ 措辭要能**指出下一步**：按鈕本身已經讓那幾格失焦、開始存檔了，
      //   所以正確的下一步就是「再按一次」，⛔ 不要叫他去點別的地方（他會不知道要點哪裡）。
      setError(
        `⚠「${row.label}」這一列有 ${pendingStores.length} 格剛改過、正在存檔（${names}）——` +
          `這次一格都沒有動到。剛才按下去的同時它們已經開始存檔了，` +
          `再按一次「⚖ 平均」就可以了。` +
          `（兩邊同時寫同一格會互相蓋掉，所以先擋下來。）`,
      );
      return;
    }

    const sb = getSupabase();
    // ⛔ loadPrefill 是刻意不 catch 的（見該函式）—— 錯誤要在這裡被接住並且**明講失敗**。
    //   ⛔ 不可以吞掉退回空需求：那會把整列平均成 0 寫進 DB，
    //   畫面跟「這樣商品真的沒人要」一模一樣，老闆分不出是壞了還是真的沒有。
    let pre: PrefillResult;
    try {
      pre = await loadPrefill({ db: sb, fetchAll: fetchAllRows }, row.sku_id);
    } catch (e) {
      // ⓘ 這段字是丟進 <div>{error}</div> 純文字渲染的，⛔ 不要寫 `**粗體**`（會原樣印出星號）。
      //   要強調就用「」—— 與 lib 的 addBatchMessage 同一條規矩。
      setError(
        `⚠ 讀取「${row.label}」各分店需求失敗，這次「沒有」改動任何數量 —— 請再按一次重試。` +
          `（這是系統讀取出錯，不是這樣商品沒有需求。原因：${describeDraftDbError(e)}）`,
      );
      return;
    }

    // ⛔ 可分配量 0 → **一格都不寫**（工作台是把鈕變灰，這一頁是按下去什麼都不做，
    //   結果一樣：什麼都不會發生）。照算的話整列會被平均成 0，
    //   等於把老闆填好的數字洗掉，而且沒有復原。
    if (pre.available === 0) {
      // ⚠ 措辭刻意**不指定原因**：可分配量 0 可能是貨還沒到、已經派完，也可能是各店需求
      //   都派掉了（那種情況 view 連列都不會回）—— 從這一次查詢分不出來是哪一種。
      //   ⛔ 挑一個講，就是替系統下了一個它沒資格下的判斷。
      setNotice(
        `⚖「${row.label}」目前在派貨工作台上沒有可以分配的量` +
          `（貨還沒到、已經派完，或各店的需求都已經派掉了）—— 這次沒有改動任何數量。`,
      );
      return;
    }

    // 這一列每一格要變成多少、以及要用新增還是改數量寫回去（純計算，見 planEvenWrite）
    // ⭐ 兩支都吃 `storeCols` 的順序 —— 那是 buildStoreColumns 用 compareStoreOrder 排的，
    //   與派貨工作台的 allStores 同一份店序（wms/picking/page.tsx:874-878）。
    //   ⛔ 不可以省掉：平手時「餘數那幾件給誰」就是靠它跟工作台對齊的（阿審 P1-1）。
    const orderedStoreIds = storeCols.map((c) => c.id);
    const even = computePrefillEven(pre, orderedStoreIds);
    const plan = planEvenWrite(
      even,
      orderedStoreIds,
      items.filter((it) => Number(it.sku_id) === row.sku_id),
    );
    const { giveTotal } = plan;
    // 各店「還缺多少」的合計 —— 成功訊息要拿它跟分出去的量對照，
    // ⛔ 不可以直接斷言「剩下的都是因為各店已經分滿了」（見下面那段）。
    const demandTotal = [...even.byStore.values()].reduce((s, v) => s + v.demandLeft, 0);

    // 可分配量有、但一家都沒有未派需求 → 一樣**一格都不寫**（否則整列被洗成 0）
    if (giveTotal === 0) {
      setNotice(
        `⚖「${row.label}」可分配 ${pre.available} 件，但目前沒有任何分店還有未派需求 ——` +
          `平均分下去每一家都會是 0，所以這次沒有改動任何數量。要多給某幾家請直接填。`,
      );
      return;
    }
    if (plan.insert.length === 0 && plan.update.length === 0) {
      setNotice(
        `⚖「${row.label}」現在的數字已經就是平均分配的結果` +
          `（可分配 ${pre.available}、分出 ${giveTotal}），沒有東西要改。`,
      );
      return;
    }

    // ---- 會蓋掉已經填好的數字 → 先問過 ----
    // ⛔ 這一頁的數字是直接落地的，蓋掉就沒有復原（同 removeSku 為什麼要 confirm 的理由）。
    //   ⓘ 只有「真的有非 0 的格子會被改成別的數字」才問；整列本來就空的不問，不要沒事多一關。
    if (
      plan.overwriting > 0 &&
      !confirm(
        `「${row.label}」這一列有 ${plan.overwriting} 格已經填了數字，按「平均」會整列改成平均分配的結果。\n\n` +
          `原本填的數字會被覆蓋掉，而且沒有復原。\n\n` +
          `（只動這張草稿：不會動到任何庫存、訂單，也不影響派貨工作台。）`,
      )
    ) {
      return;
    }

    let tenantId: string;
    let uid: string | null;
    try {
      ({ tenantId, uid } = await sessionInfo());
    } catch (e) {
      setError(`${describeDraftDbError(e)}（一格都沒有改到。）`);
      return;
    }

    // ---- 真的寫 ----
    // ⚠ 效能（數字經阿審 2026-09-01 重算）：一次按鈕 = 2 次讀（loadPrefill 內含 demand 與
    //   結單日兩次）+ 0~1 次新增 + 「每個不同目標數量各 1 次」修改。
    //   平均分配下大多數店拿到同一個數字 → **單一商品常見 3~6 次往返**；
    //   17 家店各卡在不同的上限時，理論上限是 2 讀 + 17 寫 = **19 次**。
    //   ⚠⚠ 但這是**單一商品**的數字：老闆對 10 樣商品各按一次平均是 30~60 次往返，
    //   **會高於**一次「加入選取的 10 樣」（約 30 次）。⛔ 不要拿單顆的數字去說整批也很省。
    //   ⛔ 不可以退回逐格 commitCell：那是十幾次往返，而且中途壞掉會留下半列平均、半列舊值。
    const storeLabel = (sid: number) =>
      storeCols.find((c) => c.id === sid)?.name ??
      items.find((it) => Number(it.store_id) === sid)?.snapshot_store_name ??
      `分店 #${sid}`;
    const inserted: DraftItem[] = [];
    const updated = new Map<number, number>(); // picking_draft_items.id → 新數量
    const failed: { store: string; reason: string }[] = [];

    if (plan.insert.length > 0) {
      // 這幾格還沒有列：加入這樣商品之後才啟用（或才被撈出來）的分店。
      // 快照欄位的規則**逐項比照 commitCell 的新增分支**（本檔 :407-431）：
      // 品號品名沿用同商品其他列、分店名取「現在這一欄」、數量快照當下重拍一次。
      // ⓘ 這裡不必再查一次需求：pre 就是剛剛讀回來的那一份。
      const now = new Date().toISOString();
      const sibling = items.find((it) => it.sku_id === row.sku_id);
      try {
        const { data, error: err } = await sb
          .from("picking_draft_items")
          .insert(
            plan.insert.map(({ storeId, qty }) => {
              const col = storeCols.find((c) => c.id === storeId);
              return {
                tenant_id: tenantId,
                draft_id: draftId,
                sku_id: row.sku_id,
                store_id: storeId,
                qty,
                snapshot_sku_code: sibling?.snapshot_sku_code ?? null,
                snapshot_sku_label: sibling?.snapshot_sku_label ?? null,
                snapshot_store_code: col?.code ?? null,
                snapshot_store_name: col?.name ?? null,
                ...lateCellSnapshot(pre, storeId, now),
                created_by: uid,
                updated_by: uid,
              };
            }),
          )
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name, snapshot_at, snapshot_demand_qty, snapshot_available_qty");
        if (err) throw err;
        inserted.push(...((data ?? []) as DraftItem[]));
      } catch (e) {
        const reason = describeDraftDbError(e);
        for (const { storeId } of plan.insert) failed.push({ store: storeLabel(storeId), reason });
      }
    }

    for (const { qty, rows: rowsToSet } of plan.update) {
      const ids = rowsToSet.map((it) => it.id);
      try {
        const { data, error: err } = await sb
          .from("picking_draft_items")
          .update({ qty, updated_by: uid })
          .in("id", ids)
          // ⓘ 多綁一個 draft_id：這是本檔唯一一次「一口氣依 id 改很多列」的寫入，
          //   把影響範圍鎖死在這張草稿，不靠「items 一定只裝這張草稿的列」這個信任。
          .eq("draft_id", draftId)
          // ⛔ .select() 不是裝飾：沒有它，「一列都沒改到」與「全部改好」都算成功。
          //   RLS 擋掉、或另一台 iPad 剛把這幾格刪掉時，畫面會若無其事地顯示新數字。
          .select("id");
        if (err) throw err;
        const okIds = new Set(((data ?? []) as { id: number }[]).map((r) => Number(r.id)));
        for (const it of rowsToSet) {
          if (okIds.has(Number(it.id))) updated.set(it.id, qty);
          else
            failed.push({
              store: storeLabel(Number(it.store_id)),
              reason: "這一格沒有更新到（可能剛被另一台 iPad 刪掉，或這個帳號沒有權限）",
            });
        }
      } catch (e) {
        const reason = describeDraftDbError(e);
        for (const it of rowsToSet) failed.push({ store: storeLabel(Number(it.store_id)), reason });
      }
    }

    // ---- 畫面只反映「DB 真的認了」的那些格子 ----
    // ⛔ 不做樂觀更新：寫失敗的格子要留著舊數字，老闆才看得出來哪幾家沒進去。
    if (inserted.length > 0 || updated.size > 0) {
      setItems((arr) => [
        ...arr.map((it) => (updated.has(it.id) ? { ...it, qty: updated.get(it.id) as number } : it)),
        ...inserted,
      ]);
      // 正在輸入、還沒 blur 的格子要清掉，否則畫面會蓋著老闆剛打的字、看不到新數量
      setEdits((m) => {
        const next = new Map(m);
        for (const storeId of plan.targets.keys()) next.delete(cellKey(row.sku_id, storeId));
        return next;
      });
      // 數字改了 → 先前那份檢查結果不算數了。
      // ⓘ 與 commitCell 一樣**不動** dispatchPlan：送出只帶商品、不看數量（老闆 2026-08-18）。
      setPrecheckStale(true);
    }

    const okCount = inserted.length + updated.size;
    if (failed.length > 0) {
      // ⛔ 一定要逐格講出是哪幾家店：只說「有 N 格失敗」等於沒講。
      const reasons = Array.from(new Set(failed.map((f) => f.reason)));
      const detail =
        reasons.length === 1
          ? `${failed.map((f) => f.store).join("、")}。原因：${reasons[0]}`
          : failed.map((f) => `${f.store}（${f.reason}）`).join("；");
      setError(
        `⚠「${row.label}」有 ${failed.length} 格沒有寫進去：${detail} ` +
          (okCount > 0
            ? // ⭐⭐ 這一句是本功能最重要的一行字：部分失敗＝這一列現在**半新半舊**，
              //   橫加起來不等於任何一個說得出口的數字。老闆會把草稿印給樓下去撿，
              //   不講的話他印出來的就是一張自己也不知道錯在哪的單子。
              `這幾格畫面上還是舊的數字，另外 ${okCount} 格已經改成平均分配的量 ——` +
              // ⚠ 「可能不是」不是客氣，是精確（阿審 2026-09-01 P2）：失敗那幾格的舊值
              //   有可能剛好等於目標值、或彼此抵銷，橫加仍然湊得出 giveTotal。
              //   ⛔ 話說滿就是又一個沒查證的畫面斷言。
              `這一列現在是「一半平均、一半舊值」，橫加起來可能不是 ${giveTotal} 件，` +
              `先不要印給樓下，請重試或重新整理確認。`
            : `這一列一格都沒有改到（還是原本的數字）。`) +
          `請再按一次「⚖ 平均」重試（已經改好的格子不會被重複寫）。`,
      );
    } else if (okCount > 0) {
      const short = pre.available - giveTotal;
      const unmet = demandTotal - giveTotal;
      // ⚠⚠ 這一句刻意**由實際數字判斷**，⛔ 不直接斷言「剩下的都是因為各店已經分滿了」。
      //   分不完的量通常真的是「各店加起來只缺這麼多」，但分配迴圈有一個 10 輪上限
      //   （照抄派貨工作台 autoDistribute，⛔ 不是我加的、也不該只改單邊），
      //   理論上可能在還有人缺貨時就收工。實測 50 萬組（含刻意構造的等差／幾何級數需求）
      //   一次都沒發生，但「沒找到反例」不等於「不會發生」——
      //   一旦發生，寫死那句話就是對老闆說了一件不是事實的事（本專案最忌諱的那種畫面斷言）。
      const tail =
        short <= 0
          ? ""
          : unmet <= 0
            ? `剩下的 ${short} 件沒有分出去 —— 各店加起來只缺 ${giveTotal} 件，已經分滿了。`
            : `剩下的 ${short} 件這次沒有分出去，而各店加起來還缺 ${unmet} 件 ——` +
              `這是平均分配除不盡的餘數，差額請自己填。`;
      setNotice(
        `⚖ 已把「${row.label}」的可分配 ${pre.available} 件平均分下去，共分出 ${giveTotal} 件（改了 ${okCount} 格）。` +
          `每一家都不會超過它還缺的量；沒有未派需求的店是 0。` +
          tail,
      );
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
          .select("id, sku_id, store_id, qty, snapshot_sku_code, snapshot_sku_label, snapshot_store_code, snapshot_store_name, snapshot_at, snapshot_demand_qty, snapshot_available_qty");
        if (err) throw err;
        // ⭐ 每成功一樣就立刻進畫面（functional updater，不怕批次更新交錯）——
        //   第 3 樣掛掉時，前兩樣已經看得到，不會整批一起消失。
        setItems((arr) => [...arr, ...((data ?? []) as DraftItem[])]);
        // 草稿內容變了 → 先前那份檢查結果不算數了（新加的這樣商品根本沒被檢查過）
        setPrecheckStale(true);
        // 商品清單變了 → 待確認的送出清單就是錯的（新加的這樣沒被算進去）。
        // ⛔ 這裡是**關掉**不是標 stale：那份清單是一個「要不要送」的確認步驟，不是一份結論，
        //   底下已經不是同一批商品了就沒有東西好確認，請他重按一次拿到新的。
        setDispatchPlan(null);
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
      // 少了一樣商品 → 先前那份檢查結果不算數了
      setPrecheckStale(true);
      // 同 addSkus：商品清單變了，待確認的送出清單就沒有東西好確認了
      setDispatchPlan(null);
    } catch (e) {
      setError(describeDraftDbError(e));
    }
  }

  // ---- 檢查：拿這張草稿去派貨工作台建單，會不會卡住（⛔ 純唯讀，零寫入）----
  //
  // ⛔ 這顆鈕**不做任何動作**：不導頁、不送資料、不建單、不改任何數字，
  //   只回答一個問題，答完就結束。老闆 2026-08-17 裁示的流程是
  //   「檢查 → 列印 → 拿紙去派貨工作台人工建單」，兩邊不互相伸手。
  async function runPrecheck() {
    const at = checkedAtLabel(new Date());
    try {
      // ⛔ loadPrecheckDemand 是刻意不 catch 的（見該函式），錯誤要在這裡被接住
      //   並且**明講失敗**。⛔ 不可以 catch 成空陣列 —— 那會算出一份漂亮的「全部通過」。
      const demandRows = await loadPrecheckDemand({ db: getSupabase(), fetchAll: fetchAllRows });
      setPrecheck(
        computeDraftPrecheck({ skuRows, cells: items, storeCols, demandRows, at }),
      );
    } catch (e) {
      setPrecheck({ kind: "failed", at, reason: describeDraftDbError(e) });
    }
    // ⚠ 成功或失敗都要把 stale 清掉：這份結果（含「失敗」）就是對「現在」講的。
    setPrecheckStale(false);
  }

  // ---- 送到派貨工作台 ①：算給老闆看（⛔ 純唯讀，這一步不動任何資料、不導頁）----
  //
  // 老闆 2026-08-18 原話：
  //   「草稿只需要帶商品過去，**所有的數字店家通通不用帶**啊…派貨工作台的第一步是選擇商品，
  //     那我只要草稿選的商品帶過去，派貨工作台裡的商品應該是什麼數字就什麼數字」
  //
  // ⛔⛔ 因此這裡**完全不看 qty**：草稿上出現過的商品一律帶，包含整列都是 0 的。
  //   CEO 曾提案「整列都是 0 就不帶」，老闆當場駁回 —— 他本來就會在派貨工作台的
  //   步驟 2 逐格看過才建單，數量不是步驟 1 的判斷依據。⛔ 不要把那條加回來。
  //   （skuRows 來自 buildSkuRows(items)，本來就是「草稿裡的每一樣商品」，沒有任何數量條件。）
  //
  // ⭐ 唯一會少帶的情況不是選擇、是物理限制：那樣商品在派貨工作台上已經沒有可分配量，
  //   整列根本不存在（skuRows 的 .filter(totalAvailable > 0)）→ 勾不到，所以逐項列出來。
  //
  // ⚠ 一定要**當場重撈**，⛔ 不可以吃畫面上那份可能已經 stale 的「🔍 檢查」結果：
  //   老闆可能十分鐘前按過檢查，中間別人已經把貨派掉了。
  async function prepareDispatch() {
    const at = checkedAtLabel(new Date());
    try {
      // ⛔ 與 runPrecheck 同一支查詢、同一組條件（都是 loadPrecheckDemand），
      //   兩顆鈕對「工作台上還有什麼」的答案保證一致。
      //   ⛔ 刻意不 catch 成空陣列 —— 那會算出「一樣都帶不過去」這種最像真的假訊息。
      const demandRows = await loadPrecheckDemand({ db: getSupabase(), fetchAll: fetchAllRows });
      // ⛔ 不准自己重寫這個判定：availableBySku 是逐行照抄派貨工作台 skuRows 的
      //   （含 store_id === null 要跳過、id 要 Number() 正規化兩個坑），見該函式的註解。
      const avail = availableBySku(demandRows);
      const sendable = skuRows.filter((r) => avail.has(r.sku_id));
      const blocked = skuRows.filter((r) => !avail.has(r.sku_id));
      setDispatchPlan({ kind: "ready", at, sendable, blocked });
    } catch (e) {
      setDispatchPlan({ kind: "failed", reason: describeDraftDbError(e) });
    }
  }

  // ---- 送到派貨工作台 ②：老闆按了【確定送過去】才走到這裡 ----
  //
  // ⛔ 這一頁**不碰派貨工作台的任何狀態**：只標記自己 + 導頁，
  //   已挑清單由工作台自己讀 ?fromDraft= 再撈一次草稿明細去設定。
  //   理由：已挑清單是工作台的 module store，setPickedSkuIds 有「身分世代」防線
  //   （換帳號就整批拒絕），從外面直接寫 localStorage 等於繞過跨使用者污染的防線。
  async function confirmDispatch(sendable: PrecheckSkuRef[]) {
    // UI 上帶得過去 0 樣時根本不給按，這裡再擋一次：0 樣還導頁的話，工作台會變成
    // 「有 ?fromDraft= 但一樣都沒挑中」，而沒挑中的建單範圍是「篩選範圍內全部」。
    if (sendable.length === 0) return;
    setError(null);
    try {
      const sb = getSupabase();
      const { uid } = await sessionInfo();
      const { data, error: err } = await sb
        .from("picking_drafts")
        .update({
          status: "done",
          // ⓘ 用前端時鐘：本案紅線是「不新增任何 RPC」，PostgREST 直寫的 payload
          //   沒辦法叫 DB 算 NOW()。這個值只拿來顯示「已於 X 送出」與判斷 NULL/NOT NULL，
          //   擋重送的條件是 `.is("dispatched_at", null)`（DB 端），不受時鐘誤差影響。
          dispatched_at: new Date().toISOString(),
          dispatched_by: uid,
          updated_by: uid,
        })
        .eq("id", draftId)
        // ⭐⭐ 這兩行是「不能送第二次」的**全部**防線，⛔ 不可以拿掉任何一行：
        //   .is(...)     → 條件寫在 UPDATE 語句本身。另一台 iPad 幾秒前剛送出時，
        //                  這裡會是「一列都更新不到」而不是照樣再送一次
        //                  （前端的 disabled 擋不住，畫面是幾秒前的快照）。
        //                  作法抄草稿列表頁刪除鈕的 .eq("status","draft")。
        //   .select("id")→ 為了知道「到底更新到幾列」。沒有它，0 列與 1 列都算成功，
        //                  老闆會看到系統若無其事地把同一張草稿送第二次。
        .is("dispatched_at", null)
        .select("id");
      if (err) throw err;
      if (!data || data.length === 0) {
        setDispatchPlan(null);
        setError(
          "這張草稿已經送過了，不能再送一次 —— 可能是另一台 iPad 剛剛送出的。" +
            "下面重新載入後會顯示送出時間；要再挑一次貨請另開一張新草稿。",
        );
        // 重新載入才看得到真正的送出時間與送出人，⛔ 不要讓畫面停在「還沒送過」的樣子
        await load();
        return;
      }
      // ⚠ 一定要用 router.push（或 <Link>）：它們會自動補上 basePath（線上是 /new_erp）。
      //   ⛔ 不可以用 window.open —— 那個不補，線上會開成 /wms/picking 直接 404（PR #752 踩過）。
      router.push(`/wms/picking?fromDraft=${draftId}`);
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
          <span className={`rounded-full px-2.5 py-1 text-xs ${statusBadge.cls}`}>
            {statusBadge.text}
          </span>
          <SpinButton
            onClick={() => setStatus(readOnly ? "draft" : "done")}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            {/* ⚠ 原本叫「標記完成」，與新的【📤 送到派貨工作台】太像 ——
                老闆 2026-08-18：「轉出跟標記完成意思太相同會讓人搞混」。
                ⛔ 兩顆鈕的字不可以再互相打架：這顆的重點是「不送工作台」。 */}
            {readOnly ? "重新開啟" : "🔒 收起草稿（不送工作台）"}
          </SpinButton>
          <SpinButton
            onClick={runPrecheck}
            className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            🔍 檢查
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
          {/* ⭐ 這一頁的主要動作（藍色實心），位置刻意排在「列印」後面 ——
              實際流程就是這個順序：改數量 → 檢查 → 印給樓下 → 樓下撿完 → 送到工作台。
              ⓘ 沿用這一列既有的 px-3 py-2 尺寸，⛔ 不特別加大：整列高度一致才不會看起來歪掉
                （這一列是總部在桌機/平板上按的，樓下 iPad 逐格改數量的是下面的矩陣）。
              ⚠ disabled 只看 dispatched_at：草稿被「收起」（status=done）時照樣可以送，
                老闆可能先收起來、隔天才決定要不要送。 */}
          <SpinButton
            onClick={prepareDispatch}
            disabled={!!dispatchedLabel}
            className="rounded-md bg-blue-600 px-3 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-40"
          >
            📤 送到派貨工作台
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
        {dispatchedLabel && (
          // ⛔ 這句一定要**看得見**，不可以只放在按鈕的 title：iPad 上根本沒有 tooltip
          //   （見機制索引七之五）。按鈕變灰而畫面上沒有任何說明＝老闆只會覺得系統壞了。
          <p className="rounded-md border border-blue-200 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-900 dark:bg-blue-950/40 dark:text-blue-200">
            📤 這張草稿已於 <strong>{dispatchedLabel}</strong> 送到派貨工作台，
            <strong>不能再送一次</strong>（就算按「重新開啟」繼續改也一樣）。
            要再帶一批商品過去，請另外開一張新草稿。
          </p>
        )}
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

      {precheck && (
        <PrecheckPanel
          result={precheck}
          stale={precheckStale}
          onClose={() => {
            setPrecheck(null);
            setPrecheckStale(false);
          }}
        />
      )}

      {dispatchPlan && (
        <DispatchPanel
          plan={dispatchPlan}
          draftName={draft.name}
          onConfirm={confirmDispatch}
          onCancel={() => setDispatchPlan(null)}
        />
      )}

      {readOnly ? (
        <p className="rounded-md border border-zinc-300 bg-zinc-50 p-3 text-sm text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-400">
          這張草稿已標記完成，先按「重新開啟」才能繼續改。
        </p>
      ) : (
        <AddSkuBox
          onAdd={addSkus}
          inDraft={inDraftSkuIds}
          inputCls={inputCls}
          hqLocationId={hqLocationId}
        />
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
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <div className="text-sm font-medium text-zinc-900 dark:text-zinc-100">{row.label}</div>
                        <div className="font-mono text-xs text-zinc-400">{row.code}</div>
                      </div>
                      {!readOnly && (
                        // 位置比照派貨工作台：跟商品名同一格（wms/picking/page.tsx:2494-2502）。
                        // ⭐ 這一格是 sticky left-0 —— 17 家店的表格要橫捲，鈕放在這裡才一直按得到。
                        // ⓘ 措辭刻意只講它真的會做的事。⛔ 不寫「公平分配」「自動最佳化」：
                        //   它就是平均分、cap 在各店還缺的量，沒有別的智慧（承諾做不到的事＝騙人）。
                        <SpinButton
                          type="button"
                          onClick={() => evenDistribute(row)}
                          title="把這樣商品目前的可分配量平均分到還有需求的店（每家不超過它還缺的量）。會覆蓋這一列已經填的數字。"
                          className="shrink-0 self-center rounded-md border border-blue-300 bg-blue-50 px-2 py-1.5 text-[11px] font-medium text-blue-700 hover:bg-blue-100 disabled:opacity-40 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300 dark:hover:bg-blue-900"
                        >
                          ⚖ 平均
                        </SpinButton>
                      )}
                    </div>
                    {/* 20260902：客人要的比貨多時講出來。
                        ⛔ 措辭三個地方不可以改鬆：
                        ①「加入時」—— 這是快照，不是現在的數字（要現在的得重打 loadPrefill，
                           一張草稿三五十樣＝60~100 次往返，見 evenDistribute 的效能註解）
                        ②「未派需求」不是「訂單量」—— 快照存的是 demand − wave，
                           已經派掉的那部分不在裡面（用詞與 addOutcomeMessage 的 clamped 一致）
                        ③ 只講事實，⛔ 不寫「請改小」之類的指示：老闆 2026-08-17 明確
                           不要這一頁挑他填的數字的毛病（見 pickingDraftView.ts 檢查段的註解）。
                           這一條講的是「貨不夠」不是「你給太多」，兩件事。 */}
                    {(() => {
                      const sf = rowShortfall(items, row.sku_id);
                      return sf ? (
                        <div
                          className="mt-0.5 text-xs font-medium text-red-600 dark:text-red-400"
                          title="加入這樣商品那一刻的數字（快照）。之後貨可能又到了，以派貨工作台的現況為準。"
                        >
                          ⚠ 加入時：未派需求 {sf.demandLeft}／可分配 {sf.available}，缺 {sf.short}
                        </div>
                      ) : null;
                    })()}
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
        {/* ⚠⚠ 這一段被改過兩次，兩次都是因為**它變成了假路標**：
            第一版寫「送到派貨工作台是後續切片」；第二版寫「老闆 2026-08-17 已裁示不做」、
            「這一頁不會自動把草稿送過去」—— 老闆 2026-08-18 改了主意，那句今天起就是錯的
            （只帶商品、不帶數量，把當初放棄的理由整個消掉了）。
            ⛔ 以後再改這顆鈕的行為，這一段要跟著改：過期的說明比沒有說明更害人。 */}
        數字改好之後按「檢查」，看拿去派貨工作台會不會卡住；接著「列印 / 匯出」印出來給樓下撿。
        撿完按「📤 送到派貨工作台」，<strong className="text-zinc-700 dark:text-zinc-300">
        會把這張草稿的商品帶到派貨工作台的步驟 1（挑選商品）</strong>，
        數量由派貨工作台自己算、跟草稿無關；建單一律還是在派貨工作台上手動完成。
        每張草稿只能送一次。
      </p>
    </div>
  );
}

// 「檢查」的結果面板。
//
// ⛔⛔ 這個元件唯一不可以做錯的事：**查詢失敗絕對不能長得像通過**。
//   所以 failed 走一條完全獨立的分支（紅框 + 「檢查失敗」標題），
//   ⛔ 連一個綠色的字都不會出現 —— 型別上也拿不到 ready / over 那些欄位。
//
// ⛔ 面板裡沒有任何會動到資料的按鈕：只有一顆關閉、一條到補貨申請的連結。
//   老闆 2026-08-17 裁示「只給連結，不自動建」。
function PrecheckPanel({
  result,
  stale,
  onClose,
}: {
  result: DraftPrecheck;
  /** 檢查完之後草稿又被改過 */
  stale: boolean;
  onClose: () => void;
}) {
  const headline = precheckHeadline(result);
  const closeBtn = (
    <button
      type="button"
      onClick={onClose}
      aria-label="關閉檢查結果"
      className="shrink-0 rounded px-1.5 text-current opacity-60 hover:opacity-100"
    >
      ✕
    </button>
  );

  if (result.kind === "failed") {
    return (
      <div className="rounded-md border-2 border-red-400 bg-red-50 p-3 text-red-900 dark:border-red-700 dark:bg-red-950 dark:text-red-200">
        <div className="flex items-start justify-between gap-3">
          {/* ⛔ 整句都用粗體大字，而且**只有這一句** —— 不另外加一行標題：
              標題與內文都寫「檢查失敗」會變成同一句話講兩次，而且措辭一旦分成兩處
              就會有一天只改到其中一邊。措辭的唯一出處是 precheckHeadline。 */}
          <p className="text-base font-bold leading-relaxed">{headline}</p>
          {closeBtn}
        </div>
      </div>
    );
  }

  const blockers = result.over.length + result.noDemand.length;
  // 底色只由「有沒有會卡住建單的問題」決定；⚠ 找不到的商品是黃的、全部沒事才是綠的
  const tone =
    blockers > 0
      ? "border-red-300 bg-red-50 text-red-900 dark:border-red-800 dark:bg-red-950/50 dark:text-red-200"
      : result.gone.length > 0
        ? "border-amber-300 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
        : "border-emerald-300 bg-emerald-50 text-emerald-900 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-200";

  return (
    <div className={`flex flex-col gap-3 rounded-md border p-3 text-sm ${tone}`}>
      {stale && (
        // ⛔ 不可以讓一份過期的結論繼續看起來有效 —— 尤其是綠色那個「可以去建單」。
        <div className="rounded-md border border-amber-400 bg-amber-100 p-2 text-sm font-semibold text-amber-900 dark:border-amber-600 dark:bg-amber-900/60 dark:text-amber-100">
          ⚠ 檢查完之後草稿又被改過了 —— 下面這份結果已經不算數，請再按一次「檢查」。
        </div>
      )}

      <div className="flex items-start justify-between gap-3">
        <p className="font-semibold">{headline}</p>
        {closeBtn}
      </div>

      {result.over.length > 0 && (
        <section>
          <h3 className="font-semibold">
            ❌ 這 {result.over.length} 樣超過派貨工作台現在能分配的量
          </h3>
          <ul className="mt-1 flex flex-col gap-0.5">
            {result.over.map((o) => (
              <li key={o.sku_id}>
                「{o.label}」<span className="font-mono text-xs opacity-70">{o.code}</span>：
                草稿填了 {o.planned} 件，現在只剩 <strong>{o.available}</strong> 件可以分配
                → 要減 {o.planned - o.available} 件。
              </li>
            ))}
          </ul>
        </section>
      )}

      {result.noDemand.length > 0 && (
        <section>
          <h3 className="font-semibold">
            ❌ 這 {result.noDemand.length} 格的分店，目前沒有這樣商品的需求
          </h3>
          <ul className="mt-1 flex flex-col gap-0.5">
            {result.noDemand.map((n) => (
              <li key={`${n.sku_id}:${n.store_id}`}>
                「{n.label}」<span className="font-mono text-xs opacity-70">{n.code}</span>
                {" → "}
                <strong>{n.store_name}</strong> {n.qty} 件
              </li>
            ))}
          </ul>
          <p className="mt-1.5">
            派貨工作台的分店欄位是照「需求」長出來的，這幾家店目前沒有這樣商品的需求。
            要給這些店，正規做法是先開一張補貨申請：{" "}
            {/* ⛔ 只給連結，系統絕不自動建（老闆 2026-08-17 裁示）。
                ⓘ <Link> 會自己補 basePath，不需要 withBasePath（那是給 window.open 用的）。
                另開分頁，才不會把這份檢查結果沖掉。 */}
            <Link
              href="/restock/new"
              target="_blank"
              rel="noopener noreferrer"
              className="font-semibold underline underline-offset-2"
            >
              開補貨申請（另開分頁）
            </Link>
            。這一頁<strong>不會</strong>替你開，也不會改上面任何數字。
          </p>
        </section>
      )}

      {result.gone.length > 0 && (
        <section>
          <h3 className="font-semibold">
            ⚠ 這 {result.gone.length} 樣目前在派貨工作台找不到
          </h3>
          <p className="mt-0.5">可能已經被派掉了、或是這批貨還沒到。</p>
          <ul className="mt-1 flex flex-col gap-0.5">
            {result.gone.map((g) => (
              <li key={g.sku_id}>
                「{g.label}」<span className="font-mono text-xs opacity-70">{g.code}</span>：
                草稿填了 {g.planned} 件
              </li>
            ))}
          </ul>
        </section>
      )}

      {result.ready.length > 0 && blockers + result.gone.length > 0 && (
        // 有問題時也要講清楚「其餘這些是好的」，⛔ 不要讓老闆以為整張都不能用
        <p>✅ 其餘 {result.ready.length} 樣、共 {result.readyQty} 件沒有問題，可以照著建單。</p>
      )}

      <p className="text-xs opacity-80">
        檢查於 {result.at}
        {result.emptySkuCount > 0 &&
          `　·　另有 ${result.emptySkuCount} 樣整列都沒有數量，不用撿，這次沒有檢查`}
        。現況隨時會變（樓下、別人都可能同時在動）—— 真的要去派貨工作台建單之前，最好再按一次「檢查」。
      </p>
    </div>
  );
}

// 【📤 送到派貨工作台】按下去之後的確認面板。
//
// ⛔⛔ 與 PrecheckPanel 同一條不可以做錯的事：**查詢失敗絕對不能長得像「沒東西可送」**。
//   所以 failed 走一條完全獨立的分支，型別上根本拿不到 sendable / blocked。
//
// ⭐ 為什麼要「先看再確定」而不是按一下就送：送出是**不可逆的**（dispatched_at 永不清空）。
//   老闆按下去之前一定要先看到「帶得過去幾樣、哪幾樣帶不過去」——
//   尤其是隔夜的草稿，中間別人可能已經把貨派掉了。
function DispatchPanel({
  plan,
  draftName,
  onConfirm,
  onCancel,
}: {
  plan: DispatchPlan;
  draftName: string;
  onConfirm: (sendable: PrecheckSkuRef[]) => Promise<void>;
  onCancel: () => void;
}) {
  const cancelBtn = (
    <button
      type="button"
      onClick={onCancel}
      className="min-h-[44px] shrink-0 rounded-md border border-current px-3 text-sm opacity-70 hover:opacity-100"
    >
      取消
    </button>
  );

  if (plan.kind === "failed") {
    return (
      <div className="flex items-start justify-between gap-3 rounded-md border-2 border-red-400 bg-red-50 p-3 text-red-900 dark:border-red-700 dark:bg-red-950 dark:text-red-200">
        {/* ⛔ 一個字都不可以讓人以為「是貨派完了」：那會害老闆去追一件根本沒發生的事 */}
        <p className="text-base font-bold leading-relaxed">
          問不到派貨工作台現在有什麼貨，所以這次沒有送出（草稿完全沒有被動到，可以再按一次）：{plan.reason}
        </p>
        {cancelBtn}
      </div>
    );
  }

  const { sendable, blocked } = plan;

  // 一樣都帶不過去 → ⛔ 不給【確定送過去】、不導頁、不標記。
  //   （導過去的話，工作台會是「有 ?fromDraft= 但一樣都沒挑中」，
  //     而沒挑中的建單範圍是「篩選範圍內全部」—— 會靜默多派整個工作台。）
  if (sendable.length === 0) {
    return (
      <div className="flex flex-col gap-3 rounded-md border-2 border-amber-400 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-950/50 dark:text-amber-200">
        <p className="text-base font-bold">
          這張草稿的 {blocked.length} 樣商品，派貨工作台現在<strong>一樣都沒有可分配量</strong>，
          所以沒有送出（草稿沒有被動到，等貨到了再按一次）。
        </p>
        <p>可能是已經被別人派掉了，或是這批貨還沒到。</p>
        <SkuRefList items={blocked} />
        <div className="flex flex-wrap gap-2">{cancelBtn}</div>
        <p className="text-xs opacity-80">查於 {plan.at}</p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3 rounded-md border-2 border-blue-400 bg-blue-50 p-3 text-sm text-blue-900 dark:border-blue-700 dark:bg-blue-950/50 dark:text-blue-200">
      <p className="text-base font-bold">
        要把「{draftName}」的 {sendable.length} 樣商品帶到派貨工作台的步驟 1 嗎？
      </p>

      {blocked.length > 0 && (
        // ⛔ 逐項列出品號 + 品名，不可以只說「有 N 樣沒帶過去」：
        //   同一系列常常只差規格名（花蓮阿咘 7 個口味），沒有品號品名等於沒講。
        <section>
          <h3 className="font-semibold">
            ⚠ 以下 {blocked.length} 樣在派貨工作台已經沒有可分配量，<strong>不會</strong>帶過去
          </h3>
          <p className="mt-0.5">可能已經被派掉了，或是這批貨還沒到。</p>
          <SkuRefList items={blocked} />
        </section>
      )}

      {/* ⭐ 一句就好，⛔ 不要寫成大塊警告 —— 老闆的模型本來就是這樣（他原話：
          「派貨工作台的商品拉出來的數量是多少就多少，跟草稿無關」），警告只是噪音。 */}
      <p>
        只帶<strong>商品</strong>過去，數量由派貨工作台自己算，跟草稿上的數字無關。
        帶過去之後還是要自己在步驟 2 確認數量、按「建立撿貨單」。
      </p>
      <p className="font-semibold">⚠ 送出之後這張草稿就不能再送第二次了。</p>

      <div className="flex flex-wrap gap-2">
        <SpinButton
          onClick={() => onConfirm(sendable)}
          className="min-h-[44px] rounded-md bg-blue-600 px-4 text-sm font-semibold text-white hover:bg-blue-700"
        >
          確定送過去（{sendable.length} 樣）
        </SpinButton>
        {cancelBtn}
      </div>
      {/* ⚠ 原本寫「真正帶過去的是按下『確定』當下工作台上還有的那些」——**不成立**（阿審複審 P2）。
          confirmDispatch 只標記草稿並導頁，⛔ 沒有重撈工作台現況；真正的比對是在派貨工作台
          載入時做的。面板停在畫面上幾分鐘再按確定，中間商品被別人派掉，那句話就在騙人。
          ⛔ 不要讓使用者以為「確定」這個動作本身有重新檢查。 */}
      <p className="text-xs opacity-80">
        查於 {plan.at}　·　現況隨時會變（樓下、別人都可能同時在動）——
        真正帶過去的是<strong>派貨工作台載入時</strong>還有可分配量的那些，上面這份是現在的快照。
      </p>
    </div>
  );
}

/** 品號 + 品名的清單。措辭與排版只有這一支，⛔ 不要在兩個分支各寫一份（會有一天只改到一邊） */
function SkuRefList({ items }: { items: PrecheckSkuRef[] }) {
  return (
    <ul className="mt-1 flex flex-col gap-0.5">
      {items.map((s) => (
        <li key={s.sku_id}>
          「{s.label}」<span className="font-mono text-xs opacity-70">{s.code}</span>
        </li>
      ))}
    </ul>
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
  hqLocationId,
}: {
  /** 回傳「沒加成功、要留在勾選裡」的 sku_id（見 addSkus） */
  onAdd: (opts: SkuOption[]) => Promise<number[]>;
  /** 已經在這張草稿裡的 sku_id，用來標示、並停掉勾選框 */
  inDraft: Set<number>;
  inputCls: string;
  /** 總倉 location id（頁面載入時查一次）。null ⇒ 總倉庫存那一欄顯示「查詢失敗」 */
  hqLocationId: number | null;
}) {
  const [term, setTerm] = useState("");
  const [opts, setOpts] = useState<SkuOption[]>([]);
  const [searching, setSearching] = useState(false);
  const [open, setOpen] = useState(false);
  // 搜尋查詢失敗的原因。null = 沒失敗。
  // ⛔ 一定要跟「查詢正常、但真的沒有這樣商品」分開：兩者都是「下拉沒東西可挑」，
  //   混在一起的話，老闆打「花蓮阿咘」剛好查詢壞掉，他會直接以為系統裡沒有這個商品。
  //   —— 這是本專案反覆踩過的「系統異常偽裝成資料狀態」。
  const [searchError, setSearchError] = useState<string | null>(null);
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
        // ⛔ error 一定要接住。舊版只取 data，查詢失敗時 data 是 null →
        //   下拉變成空的 → 跟「這個關鍵字真的沒有商品」長得一模一樣。
        const { data, error } = await q;
        // 已經換字 / 關掉下拉了就丟掉這批結果，避免慢的舊查詢蓋掉新的。
        // ⚠ 這一關要擋在錯誤處理**前面**：使用者早就換字了的那批舊錯誤不該跳出來嚇人。
        if (cancelled) return;
        if (error) throw error;
        setSearchError(null);
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
      } catch (e) {
        // 舊版只有 try/finally 沒有 catch：連線層丟出來的錯（例如整個 fetch 失敗）
        // 會變成 unhandled rejection，而且畫面**留著上一次的搜尋結果** ——
        // 老闆會對著一批跟目前關鍵字無關的商品打勾。
        if (cancelled) return;
        setSearchError(describeDraftDbError(e));
        // 清掉結果：留著舊的比空的更危險（那些是別的關鍵字查出來的東西）。
        // ⓘ 這不會動到已經勾選的東西 —— 勾選存在獨立的 selected 裡，
        //   正是為了「搜尋出什麼事都不影響先前勾好的」。
        setOpts([]);
      } finally {
        setSearching(false);
      }
    }, 200);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [term, open]);

  // ---- 每一列的「結單日 / 總倉庫存 / 可分配量」（老闆 2026-08-17：0 庫存也拉得下去，浪費時間）----
  //
  // ⭐ 刻意是**獨立於搜尋的另一個 effect**：商品列先出來、數字後到再補上。
  //   ⛔ 不可以等數字回來才渲染下拉 —— 老闆要的是「哪幾樣可以挑」，
  //     為了三個附加數字讓下拉空白幾百毫秒是本末倒置。
  // ⚠ 結果**綁在「這一批 sku_id」上**（previewKey）：慢的舊批次回來時 key 對不上，
  //   算出來的東西就永遠不會被畫出來 —— ⛔ 不可能發生「A 商品那一列掛著 B 那批的數字」。
  //   這比 cancelled 旗標更強：連「已經 setState 完、下一次 render 才用到」的縫都關掉了。
  const [preview, setPreview] = useState<{ key: string; batch: SkuPreviewBatch } | null>(null);
  const previewKey = opts.map((o) => o.id).join(",");

  useEffect(() => {
    let cancelled = false;
    const ids = previewKey ? previewKey.split(",").map(Number) : [];
    void (async () => {
      // ⛔ loadSkuPreviewBatch 自己會把三個來源的失敗各自記成 null（＝「查詢失敗」），
      //   這裡的 try 只擋最外層那種錯（例如連 supabase client 都取不到）。
      //   ⛔ 一樣不可以吞成「沒有資料」—— 全 null ＝ 三欄都印「查詢失敗」，不是印 0。
      let batch: SkuPreviewBatch;
      try {
        batch = await loadSkuPreviewBatch(
          { db: getSupabase(), fetchAll: fetchAllRows },
          ids,
          hqLocationId,
        );
      } catch {
        batch = SKU_PREVIEW_ALL_FAILED;
      }
      if (cancelled) return;
      setPreview({ key: previewKey, batch });
    })();
    return () => {
      cancelled = true;
    };
  }, [previewKey, hqLocationId]);

  // key 對不上 = 這一批的數字還沒回來 → 顯示「查詢中…」，⛔ 不顯示上一批的數字
  const previewBatch = preview?.key === previewKey ? preview.batch : null;

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
        {/* ⭐ 查詢失敗要長得跟「真的沒有這樣商品」完全不一樣：
            這裡是紅框、明講「不是沒有這樣商品」；真的沒有時維持原本的行為（不跳下拉）。
            ⛔ 不可以兩種都靜靜地不顯示東西 —— 老闆會把系統壞掉當成商品不存在。 */}
        {open && searchError && (
          <div className="absolute left-0 top-full z-20 mt-1 w-full rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 shadow-lg dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            ⚠ 搜尋商品失敗：{searchError}
            <div className="mt-1 text-xs">
              這是系統查詢出錯，<strong>不代表沒有這樣商品</strong> —— 請改一下關鍵字或稍後再打一次。
              （已經勾選的商品都還在，不受影響。）
            </div>
          </div>
        )}
        {open && !searchError && opts.length > 0 && (
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
              {/* ⭐ 這兩個數字**不是同一件事**，不寫清楚老闆會把它們當成同一個（正是本功能的重點）：
                  總倉 ＝ 樓下撿得到的貨；可派 ＝ 派貨工作台准你派的量（進貨 − 已派）。
                  ⛔ 也要講明「標紅還是可以勾」，不然他會以為系統把那幾樣鎖住了。 */}
              <p className="w-full text-xs text-zinc-500 dark:text-zinc-400">
                <span className="font-medium">總倉</span>＝樓下撿得到的量、
                <span className="font-medium">可派</span>＝派貨工作台准你派的量（進貨 − 已派）。
                任一為 <span className="font-semibold text-red-600 dark:text-red-400">0</span> 會標紅
                —— 只是提醒，<strong>照樣可以勾選加入</strong>。
              </p>
            </div>
            <ul className="divide-y divide-zinc-100 overflow-y-auto dark:divide-zinc-700">
              {opts.map((o) => {
                const already = inDraft.has(o.id);
                const checked = selected.has(o.id);
                // ⭐ 紅字判準提到這一層算（原本只有底下那行小字知道）：老闆掃下拉時
                //    **視線是在商品名稱上**的，警示只放在下面那行小字會被整行跳過。
                //    純函式、無 I/O，一列算一次（一次搜尋最多 15 列）。
                const cell = previewBatch ? skuPreviewCell(previewBatch, o.id) : null;
                return (
                  <li
                    key={o.id}
                    // ⛔ 勾起來的藍底**優先於**警示紅底：紅的東西照樣可以勾（老闆選 A：標示但不擋），
                    //    勾了卻沒有變色會讓人以為系統擋掉了。警示不會因此消失 —— 商品名旁邊那顆
                    //    紅標籤是常駐的，勾選前後都在。
                    className={`flex items-center gap-2 px-2 ${
                      checked && !already
                        ? "bg-blue-50/60 dark:bg-blue-950/20"
                        : cell?.zero
                          ? "bg-red-50/60 dark:bg-red-950/20"
                          : ""
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
                      {/* 標籤放在商品名**前面**：15 列一起看時所有標籤會對齊成一直排，
                          掃起來比接在長短不一的商品名後面快得多。 */}
                      {cell?.zero && <SkuZeroBadge cell={cell} />}
                      <span className="font-medium">{o.product_name}</span>
                      {o.variant_name && <span className="ml-1 text-zinc-500">/ {o.variant_name}</span>}
                      <span className="ml-2 font-mono text-xs text-zinc-400">{o.sku_code}</span>
                      <SkuPreviewLine cell={cell} />
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

// 搜尋下拉每一列底下那一行小字：`結單 8/19　總倉 24 / 可派 0`
//
// ⭐⭐ 為什麼是**兩個**數字（老闆 2026-08-17，辣椒醬 G01159-01 是活例）：
//   總倉 24 ＝ 樓下撿得到的貨；可派 0 ＝ 派貨工作台准你派的量（進貨 − 已派）。
//   只看一個都會白跑 —— 只看庫存會撿得到卻建不了單，只看可分配量會以為沒貨其實總倉還有。
//
// ⛔ 任一為 0 只**標紅**，⛔ 不擋勾選（老闆選 A：標示但不擋）。
// ⛔⛔ 查詢失敗印「查詢失敗」，⛔ 絕對不可以印 0 —— 老闆看到 0 會直接跳過這一樣，
//   而系統其實根本不知道有沒有貨。#757 才剛踩過同一個病（搜尋失敗偽裝成「沒這商品」）。
const PREVIEW_TONE_CLS: Record<PreviewTone, string> = {
  ok: "",
  muted: "text-zinc-400 dark:text-zinc-500",
  zero: "font-semibold text-red-600 dark:text-red-400",
  // 「無法確認」沿用本頁其他地方的琥珀色（分店已停用／商品查不到都是這個色）
  failed: "font-semibold text-amber-700 dark:text-amber-400",
};

// 商品名稱**那一行**的紅色小標籤（阿審 2026-08-17 P1：警示原本只出現在底下那行小字）。
//
// ⭐ 老闆的原始痛點是「選品項時 0 庫存也可以拉，浪費我的時間」——
//    他快速掃下拉時眼睛落在商品名上，警示必須出現在他真的在看的那一行。
//
// ⛔⛔ 刻意只加「標籤」＋「整列淡紅底」，⛔ **不**把商品名改成紅字／灰字／降透明度：
//    那三種都是這套 UI 用來表示「不能選」的長相（同列 `已在草稿中` 的灰底就是），
//    做下去會變成反效果 —— 老闆會以為系統擋他，而不是提醒他。他選的是 A：標示但不擋。
//
// 措辭是底下那行小字的短版（同一組判準、同一份用詞），⛔ 不另外發明一套說法。
function SkuZeroBadge({ cell }: { cell: SkuPreviewCell }) {
  return (
    <span className="mr-1 whitespace-nowrap rounded bg-red-100 px-1 align-middle text-[10px] font-semibold text-red-700 dark:bg-red-900/70 dark:text-red-200">
      {cell.hq.tone === "zero" && cell.avail.tone === "zero"
        ? "⚠ 總倉／可派 0"
        : cell.hq.tone === "zero"
          ? "⚠ 總倉 0"
          : "⚠ 可派 0"}
    </span>
  );
}

// cell ＝ null 代表三個數字還沒回來（⛔ 不是「查詢失敗」，失敗是 tone: "failed"）
function SkuPreviewLine({ cell: c }: { cell: SkuPreviewCell | null }) {
  // 還沒回來 → 佔一行同樣高度的淡字，⛔ 不要讓那一列在數字到達時上下跳動
  if (!c) {
    return <div className="mt-0.5 text-xs text-zinc-300 dark:text-zinc-600">結單 · 總倉 / 可派　查詢中…</div>;
  }
  return (
    <div className={`mt-0.5 text-xs ${c.zero ? "text-red-600 dark:text-red-400" : "text-zinc-500 dark:text-zinc-400"}`}>
      結單 <span className={PREVIEW_TONE_CLS[c.close.tone]}>{c.close.text}</span>
      <span className="mx-1.5 text-zinc-300 dark:text-zinc-600">·</span>
      總倉 <span className={PREVIEW_TONE_CLS[c.hq.tone]}>{c.hq.text}</span>
      {" / "}
      可派 <span className={PREVIEW_TONE_CLS[c.avail.tone]}>{c.avail.text}</span>
      {c.zero && (
        // ⭐ 顏色以外一定要有字：這一頁有深色模式、老闆也可能用平板在強光下看，
        //   只靠紅色的話「這一樣有問題」就傳達不到（同列印頁那條「顏色以外要另有文字標示」）。
        <span className="ml-1.5 font-semibold">
          {c.hq.tone === "zero" && c.avail.tone === "zero"
            ? "⚠ 總倉沒貨、也派不出去"
            : c.hq.tone === "zero"
              ? "⚠ 總倉沒貨（撿不到）"
              : "⚠ 派不出去（工作台可分配量 0）"}
        </span>
      )}
    </div>
  );
}
