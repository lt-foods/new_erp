"use client";

// 總倉收件匣「✎ 修正數量」彈窗（商品 × 分店矩陣）。
//
// ⭐ 2026-08-17 兩件事（老闆原話）：
//   ①「修正數量如果 1 改 2 會出現要增加數量，有辦法在旁邊幫我加一個鈕 就是增加庫存嗎」
//     → 商品那一欄多一顆「＋ 補庫存」，開既有的 AddStockModal（後端零改動）。
//   ②「還有修正數量，要一次把所有分店都秀出來，因為我入庫的會是原本沒叫貨的店家」
//     → 分店欄位改撈 stores 全表；空格子可以直接填，填了就用 rpc_add_wave_item 補一列。
//
// ⭐ 分店欄位的規則**不是新發明的**，逐條沿用撿貨草稿頁兩天前才定案的那一套
//   （lib/pickingDraftView.ts buildStoreColumns 的檔頭，老闆 2026-08-17 親口拍板）：
//     啟用中                    → 一律有欄位（就算這張撿貨單一格都沒有）
//     已停用 ＋ 本單沒有任何一列 → ⛔ 不顯示（「已停用的店家就不用出現了」）
//     已停用 ＋ 本單有列         → ✅ 照樣顯示，標「已停用」
//   排序也沿用共用的 lib/storeOrder（老闆指定的撿貨動線順序），
//   與派貨工作台矩陣／列印撿貨單／撿貨草稿同一份 —— ⛔ 不要各自再排一套。
import { Fragment, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { fetchAllRows } from "@/lib/fetchAllRows";
import { translateRpcError } from "@/lib/rpcError";
import { compareStoreOrder } from "@/lib/storeOrder";
import SpinButton from "@/components/SpinButton";
import { AddStockModal } from "@/components/AddStockModal";
import { DatePicker } from "@/components/DatePicker";

export type PickWave = {
  id: number;
  wave_code: string;
  wave_date: string;
  status: string;
  store_count: number;
  item_count: number;
  total_qty: number;
  note: string | null;
  created_at: string;
  expected_total: number;
  actual_total: number;
  source_po_id: number | null;
  source_po_no: string | null;
};

export type PickWaveItem = {
  id: number;
  sku_id: number;
  store_id: number;
  qty: number;
  picked_qty: number | null;
  generated_transfer_id: number | null;
};

/** stores 全表的一列（含停用）。`is_active === false` ＝ 已經收掉的店 */
type Store = { id: number; code: string | null; name: string; is_active: boolean | null };
type Sku = {
  id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
};

/** 「這次新加的那一格」的 key。⛔ 只有這一支會組，不要在別處手拼字串 */
const cellKey = (skuId: number, storeId: number) => `${skuId}:${storeId}`;

export const WAVE_STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  picking: "撿貨中",
  picked: "撿貨完成",
  shipped: "已派貨",
  cancelled: "已取消",
};

export const WAVE_STATUS_COLOR: Record<string, string> = {
  draft: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  picking: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  picked: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipped: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
};

export function PickModal({
  wave,
  onClose,
  onSubmitted,
}: {
  wave: PickWave;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [items, setItems] = useState<PickWaveItem[] | null>(null);
  const [allStores, setAllStores] = useState<Store[]>([]);
  const [skus, setSkus] = useState<Sku[]>([]);
  const [edits, setEdits] = useState<Map<number, string>>(new Map());
  /** 原本沒有那一列、這次要新加的格子。key = cellKey(sku, store)，value = 輸入框的原始字串 */
  const [newCells, setNewCells] = useState<Map<string, string>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [shipping, setShipping] = useState(false);
  const [hqLocId, setHqLocId] = useState<number | null>(null);
  /**
   * 總倉目前可用量（on_hand − reserved，與 rpc_outbound 的判準同一條算式）。
   * ⛔ null ＝ **沒讀到**（有些角色讀不到 stock_balances），不是「庫存 0」——
   *   這兩件事在畫面上必須講不同的話，否則系統異常會偽裝成真的缺貨。
   */
  const [hqAvail, setHqAvail] = useState<Map<number, number> | null>(null);
  /** 開著「＋ 補庫存」的是哪一樣商品、預設補多少 */
  const [addStock, setAddStock] = useState<{ sku: Sku; qty: number } | null>(null);
  /** 補完庫存要就地重載（彈窗不關），讓老闆接著按派貨 */
  const [reloadTick, setReloadTick] = useState(0);
  const [effectiveStatus] = useState<string>(wave.status);
  // 配送日在收件匣設定；shipped/cancelled 唯讀（RPC 也擋）
  const [waveDate, setWaveDate] = useState(wave.wave_date);
  const [savingDate, setSavingDate] = useState(false);

  /** 已派貨／已取消 → 整張唯讀（rpc_add_wave_item 與 rpc_update_picked_qty 後端也都擋） */
  const locked = effectiveStatus === "shipped" || effectiveStatus === "cancelled";

  const shortageCount = useMemo(() => {
    if (!items) return 0;
    let n = 0;
    for (const it of items) {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      if (!Number.isNaN(v) && v < Number(it.qty)) n += 1;
    }
    return n;
  }, [items, edits]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        // ⚠ 一定要走 fetchAllRows：一張 wave = 一張採購單 × 全部分店，
        //   180 品項 × 17 店 = 3060 列，PostgREST 預設 1000 列會**靜默**截斷。
        //   被截掉的列在畫面上就是「空格子」—— 而空格子現在是可以填的，
        //   老闆會往一個其實已經有列的格子填數字，然後撞 UNIQUE 錯誤。
        //   （切片 B 把空格子變成入口之後，這條就不再只是顯示問題。）
        const itemsData = await fetchAllRows<PickWaveItem>(() =>
          sb
            .from("picking_wave_items")
            .select("id, sku_id, store_id, qty, picked_qty, generated_transfer_id")
            .eq("wave_id", wave.id)
            .order("id", { ascending: true }),
        );
        if (cancelled) return;
        // ⚠⚠ id 一律在**載入邊界**正規化成數字。BIGINT 經過 PostgREST 可能是數字、
        //   也可能是字串，而 TypeScript 的 `{ id: number }` 宣告在執行期完全不檢查。
        //   矩陣是 Map.get() 查的：一邊 "1630"、另一邊 1630 就必定查不到 ——
        //   而「查不到」在切片 B 之後不再只是顯示成「·」，它會變成一個**可以填的新增格**，
        //   老闆會往一個其實已經有列的格子填數字。本專案已經因為相信宣告的型別踩過一次（#751）。
        const arr = itemsData.map((r) => ({
          ...r,
          id: Number(r.id),
          sku_id: Number(r.sku_id),
          store_id: Number(r.store_id),
          qty: Number(r.qty),
          picked_qty: r.picked_qty === null ? null : Number(r.picked_qty),
        }));
        setItems(arr);

        const skuIds = Array.from(new Set(arr.map((r) => r.sku_id)));

        if (skuIds.length) {
          const { data: skuData } = await sb
            .from("skus")
            .select("id, sku_code, product_name, variant_name")
            .in("id", skuIds);
          if (!cancelled) {
            setSkus(((skuData as Sku[] | null) ?? []).map((s) => ({ ...s, id: Number(s.id) })));
          }
        }

        // ⭐ 切片 B：分店改撈**全表**（含停用，帶 is_active），不再只撈本單有列的那幾家。
        //   老闆：「我入庫的會是原本沒叫貨的店家」——沒叫貨的店在舊寫法裡連欄位都不存在。
        //   撈全表 ≠ 全部都變成欄位：實際顯示哪幾欄由下面的 storeCols 決定。
        const { data: storeData, error: eStore } = await sb
          .from("stores")
          .select("id, code, name, is_active")
          .order("code");
        if (eStore) throw new Error(eStore.message);
        if (!cancelled) setAllStores((storeData as Store[] | null) ?? []);

        const { data: loc } = await sb
          .from("locations")
          .select("id")
          .eq("type", "central_warehouse")
          .eq("is_active", true)
          .limit(1);
        const hq = ((loc as { id: number }[] | null) ?? [])[0]?.id ?? null;
        if (!cancelled) setHqLocId(hq);

        // 總倉即時可用量（切片 A 的「差額」要用）。
        // ⚠ 分批 200 筆：對齊派貨工作台既有寫法（wms/picking/page.tsx:582），避免 URL 過長。
        // ⛔ 讀失敗一律留 null（＝「不知道」），不要退回空 Map 讓畫面顯示「可用 0」——
        //   那會長得跟真的缺貨一模一樣，是本專案反覆踩過的靜默偽裝。
        if (hq != null && skuIds.length) {
          try {
            const m = new Map<number, number>();
            for (let i = 0; i < skuIds.length; i += 200) {
              const { data, error: eb } = await sb
                .from("stock_balances")
                .select("sku_id, on_hand, reserved")
                .eq("location_id", hq)
                .in("sku_id", skuIds.slice(i, i + 200));
              if (eb) throw new Error(eb.message);
              for (const r of (data ?? []) as { sku_id: number; on_hand: number; reserved: number }[]) {
                // 與 rpc_outbound（20260705000000:144）同一條算式：on_hand − reserved
                m.set(Number(r.sku_id), Number(r.on_hand) - Number(r.reserved));
              }
            }
            // 沒有結存列 = 這樣商品在總倉沒有庫存 → 0（這是「查得到、就是 0」，不是查不到）
            for (const id of skuIds) if (!m.has(id)) m.set(id, 0);
            if (!cancelled) setHqAvail(m);
          } catch {
            if (!cancelled) setHqAvail(null);
          }
        }
      } catch (e) {
        if (!cancelled) setError(translateRpcError(e));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [wave.id, reloadTick]);

  // ⚠ key 一定是數字（items 在載入時就正規化過了，見上面那段說明）。
  //   ⛔ 不要把那段正規化拿掉：這張 Map 查不到 = 那一格會被當成「可以新增」。
  const matrix: Map<number, Map<number, PickWaveItem>> = useMemo(() => {
    const m = new Map<number, Map<number, PickWaveItem>>();
    for (const it of items ?? []) {
      if (!m.has(it.sku_id)) m.set(it.sku_id, new Map());
      m.get(it.sku_id)!.set(it.store_id, it);
    }
    return m;
  }, [items]);

  const skuList = useMemo(
    () => skus.sort((a, b) => (a.sku_code ?? "").localeCompare(b.sku_code ?? "")),
    [skus],
  );

  /**
   * 矩陣要有哪些分店欄位。
   *
   * 規則與撿貨草稿頁**逐條相同**（老闆 2026-08-17 拍板，見 lib/pickingDraftView.ts:149-174）：
   *   啟用中                    → 一律有欄位
   *   已停用 ＋ 本單一列都沒有  → ⛔ 不顯示
   *   已停用 ＋ 本單有列        → ✅ 照樣顯示，標「已停用」
   *
   * ⭐ 判準是「本單有沒有那一列」而不是「數量大不大」：撿貨單的 qty 表上是
   *   CHECK (qty > 0)（20260423120002:68），有列就一定有量 —— 這一點跟草稿不一樣
   *   （草稿會替每家店建 qty = 0 的列，所以那邊必須看合計）。
   * ⛔ 有列的一定要留：合計是把該商品所有 items 加總、不看畫面上有沒有那一欄，
   *   藏掉一個有量的欄，橫的加起來就 ≠ 合計。
   */
  const stores = useMemo(() => {
    const hasRow = new Set((items ?? []).map((it) => Number(it.store_id)));
    return allStores
      .filter((s) => s.is_active !== false || hasRow.has(Number(s.id)))
      .map((s) => ({ ...s, id: Number(s.id) }))
      .sort((a, b) => compareStoreOrder(a.code, a.name, b.code, b.name));
  }, [allStores, items]);

  function setEdit(itemId: number, val: string) {
    setEdits((cur) => {
      const next = new Map(cur);
      next.set(itemId, val);
      return next;
    });
  }

  function setNewCell(skuId: number, storeId: number, val: string) {
    setNewCells((cur) => {
      const next = new Map(cur);
      const k = cellKey(skuId, storeId);
      // 清空 ＝ 這一格不新增。⛔ 不可以留一個空字串在 Map 裡：
      //   Number("") === 0，會變成「送出 0」然後被後端擋掉，
      //   老闆只是把打錯的字刪掉而已（同一個空字串陷阱在本檔 saveEdits 也存在，
      //   那是既有缺口、不在本案範圍）。
      if (val.trim() === "") next.delete(k);
      else next.set(k, val);
      return next;
    });
  }

  /** 這一格新填的數量；不是有效正數就回 null（畫面用它判斷要不要標成錯的） */
  function newCellQty(skuId: number, storeId: number): number | null {
    const raw = newCells.get(cellKey(skuId, storeId));
    if (raw === undefined) return null;
    const n = Number(raw);
    return Number.isFinite(n) && n > 0 ? n : null;
  }

  /** 有填但填得不對（負數、0、亂碼）的格子數 —— ⛔ 不可以靜默略過，要擋下存檔 */
  const badNewCells = useMemo(() => {
    let n = 0;
    for (const raw of newCells.values()) {
      const v = Number(raw);
      if (!Number.isFinite(v) || v <= 0) n += 1;
    }
    return n;
  }, [newCells]);

  /** 「儲存修正 (N)」的 N ＝ 改過的既有格 ＋ 新加的格 */
  const pendingCount = edits.size + newCells.size;

  async function changeDate(newDate: string) {
    if (newDate === waveDate) return;
    setSavingDate(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");
      const { error: e } = await sb.rpc("rpc_update_wave_date", {
        p_wave_id: wave.id,
        p_new_date: newDate,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      setWaveDate(newDate);
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSavingDate(false);
    }
  }

  /**
   * 把畫面上的暫存改動寫回 DB。存修正與派貨兩條路都走這一支，⛔ 不要各寫一份
   * （原本那兩份就是逐字複製的，改一份忘了另一份是遲早的事）。
   *
   * 順序：先改既有格、再補新格。兩者互不影響（新格的 qty 與 picked_qty
   * 在新增當下就一起寫定），所以順序只影響「先落地哪一種」，不影響結果。
   */
  async function applyPending(
    sb: ReturnType<typeof getSupabase>,
    operator: string,
    note: string,
  ) {
    for (const [itemId, val] of edits) {
      const newQty = Number(val);
      if (Number.isNaN(newQty) || newQty < 0) continue;
      const { error: e } = await sb.rpc("rpc_update_picked_qty", {
        p_wave_item_id: itemId,
        p_new_qty: newQty,
        p_operator: operator,
        p_note: note,
      });
      if (e) throw new Error(`item ${itemId}: ${e.message}`);
    }
    for (const [k, raw] of newCells) {
      const [skuIdStr, storeIdStr] = k.split(":");
      const qty = Number(raw);
      // 這裡不會發生（存檔前已被 badNewCells 擋下），留著是最後一道防線：
      // ⛔ 絕不把不合法的數字送進去撞後端的 CHECK。
      if (!Number.isFinite(qty) || qty <= 0) continue;
      // ⛔ 不加前綴：後端回的已經是完整中文句子，加上 "item N:" 會讓
      //   rpcError.ts 那條 ^wrong_store: 的規則比對不到。
      const { error: e } = await sb.rpc("rpc_add_wave_item", {
        p_wave_id: wave.id,
        p_sku_id: Number(skuIdStr),
        p_store_id: Number(storeIdStr),
        p_qty: qty,
        p_operator: operator,
        p_note: note,
      });
      if (e) throw new Error(e.message);
    }
  }

  /** 有填但填得不對的格子 → 擋下整次存檔並講清楚是哪裡不對 */
  function assertNewCellsValid() {
    if (badNewCells > 0) {
      throw new Error(
        `有 ${badNewCells} 個新增的格子填的不是大於 0 的數字。` +
          `請改成正確的數量，或把該格清空（清空＝這家店不加）。`,
      );
    }
  }

  async function saveEdits() {
    if (pendingCount === 0) {
      onSubmitted();
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      assertNewCellsValid();
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      await applyPending(sb, operator, "manual fix in /hq/inbox (picking tab)");
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setSubmitting(false);
    }
  }

  async function ship() {
    if (!hqLocId) {
      setError("找不到總倉 location，請確認倉庫設定");
      return;
    }

    // 這次新加的格子也算「有量」——否則整張本來都是 0、只靠新加的那幾格出貨時會被誤擋
    const hasNewQty = Array.from(newCells.values()).some((v) => {
      const n = Number(v);
      return Number.isFinite(n) && n > 0;
    });
    const allZero = !hasNewQty && items != null && items.length > 0 && items.every((it) => {
      const e = edits.get(it.id);
      const v = e !== undefined ? Number(e) : Number(it.picked_qty ?? it.qty);
      return !Number.isNaN(v) && v === 0;
    });
    if (allZero) {
      setError("所有品項撿貨數量均為 0，請先在上方輸入實際撿貨量再派貨");
      return;
    }

    if (badNewCells > 0) {
      setError(
        `有 ${badNewCells} 個新增的格子填的不是大於 0 的數字，先處理完才能派貨。` +
          `請改成正確的數量，或把該格清空（清空＝這家店不加）。`,
      );
      return;
    }

    const needsConfirm = effectiveStatus !== "picked";
    const shortMsg = shortageCount > 0
      ? `\n\n⚠ 有 ${shortageCount} 行短缺（撿到的數量少於應撿量），派貨後該店家會拿不到應有量。是否仍要繼續？`
      : "";
    // ⛔ 新增的分店一定要在確認框講出來：wave.store_count 是這一頁載入當下的數字，
    //   新加的店還沒算進去，只看那個數字會以為沒有多派給誰。
    const newStoreCount = new Set(
      Array.from(newCells.keys()).map((k) => k.split(":")[1]),
    ).size;
    const addMsg = newCells.size > 0
      ? `\n\n本次還會新增 ${newCells.size} 個品項給 ${newStoreCount} 間原本沒有叫貨的分店（會一起出貨）。`
      : "";
    const stepMsg = needsConfirm
      ? `\n\n目前狀態為「${WAVE_STATUS_LABEL[effectiveStatus] ?? effectiveStatus}」,將自動 確認撿貨完成 + 派貨出倉。`
      : "";
    if (!confirm(`確認派貨？將為 ${wave.store_count} 間分店產生 transfer 並從總倉出庫。${addMsg}${stepMsg}${shortMsg}`)) return;
    setShipping(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: userRes } = await sb.auth.getUser();
      const operator = userRes?.user?.id;
      if (!operator) throw new Error("未登入");

      if (pendingCount > 0) {
        await applyPending(sb, operator, "manual fix before dispatch");
      }
      if (needsConfirm) {
        const { error: ec } = await sb.rpc("rpc_confirm_picked", {
          p_wave_id: wave.id,
          p_operator: operator,
        });
        if (ec) throw new Error(ec.message);
      }
      const { error: e } = await sb.rpc("generate_transfer_from_wave", {
        p_wave_id: wave.id,
        p_hq_location_id: hqLocId,
        p_operator: operator,
      });
      if (e) throw new Error(e.message);
      alert(`派貨完成！${wave.store_count} 張 transfer 已建立`);
      onSubmitted();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setShipping(false);
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
      <div className="flex max-h-[90vh] w-full max-w-[90vw] flex-col overflow-hidden rounded-md bg-white shadow-xl dark:bg-zinc-900">
        <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="font-semibold">
              修正數量：<span className="font-mono">{wave.wave_code}</span>{" "}
              <span className="text-xs text-zinc-500">
                · 狀態 {WAVE_STATUS_LABEL[effectiveStatus] ?? effectiveStatus}
              </span>
              {shortageCount > 0 && (
                <span className="ml-2 inline-block rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  ⚠ {shortageCount} 行短缺（可派貨，部分店家拿不到應有量）
                </span>
              )}
            </h2>
            {/* DatePicker 根節點是 div，不能塞進 h2（heading 只能含 phrasing content）→ 做成 h2 的 sibling chip */}
            {effectiveStatus !== "shipped" && effectiveStatus !== "cancelled" ? (
              <div
                className="inline-flex items-center gap-1 rounded bg-blue-100 px-1.5 py-0.5 text-xs font-semibold text-blue-800 dark:bg-blue-950 dark:text-blue-300"
                title="點日期修改配送日"
              >
                📅 配送日
                <DatePicker
                  value={waveDate}
                  onChange={changeDate}
                  popover="fixed"
                  disabled={savingDate}
                  className="rounded border border-dashed border-blue-400 px-1 font-mono text-xs font-semibold text-blue-800 hover:bg-blue-200 disabled:opacity-50 dark:border-blue-600 dark:text-blue-300 dark:hover:bg-blue-900"
                />
              </div>
            ) : (
              <span className="text-xs text-zinc-500">📅 配送日 {waveDate}</span>
            )}
          </div>
          <div className="flex gap-2">
            {effectiveStatus !== "shipped" && pendingCount > 0 && (
              <SpinButton
                onClick={saveEdits}
                disabled={submitting}
                className="rounded-md border border-zinc-300 bg-white px-3 py-1.5 text-xs font-semibold text-zinc-700 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-200 dark:hover:bg-zinc-800"
                title="僅儲存修正不派貨"
              >
                {submitting ? "儲存中…" : `儲存修正 (${pendingCount})`}
              </SpinButton>
            )}
            {effectiveStatus !== "shipped" && effectiveStatus !== "cancelled" && (
              <SpinButton
                onClick={ship}
                disabled={shipping || submitting}
                className="rounded-md bg-emerald-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
                title={
                  effectiveStatus === "picked"
                    ? "建立 transfer 並從總倉出庫"
                    : "自動 儲存修正 + 確認撿貨完成 + 派貨出倉"
                }
              >
                {shipping ? "派貨中…" : "🚚 派貨出倉"}
              </SpinButton>
            )}
            <SpinButton
              onClick={onClose}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-xs hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              關閉
            </SpinButton>
          </div>
        </div>

        {error && (
          <div className="border-b border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {/* 這一行是必要的說明，不是裝飾：矩陣現在會列出**全部**分店，
            虛線格子代表「這家店原本沒叫貨」。不講的話老闆會以為系統多跑出一堆店。 */}
        {!locked && (
          <div className="border-b border-zinc-200 bg-zinc-50 px-3 py-1.5 text-[11px] text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400">
            這裡列出所有分店。<span className="font-semibold text-sky-700 dark:text-sky-300">虛線</span>
            的格子代表那家店原本沒有叫貨 —— 直接填數量就會幫它新增一列，一起出貨。
            已停用而且本單沒有東西的店不會出現。
            {/* ⚠ 這一句是 tooltip 塞不下、但一定要看得到的事：兩條路徑擋人的東西不一樣。
                不寫在畫面上的話，老闆被「可分配量」擋下時第一個反應一定是去按「＋ 補庫存」，
                補完再試還是進不來 —— 而他不會知道為什麼。 */}
            <span className="mt-0.5 block">
              ⚠「＋ 補庫存」只補<span className="font-semibold">總倉庫存</span>
              （影響的是改既有格子後派不派得出去），
              <span className="font-semibold">不會</span>增加這張採購單的可分配量。
              新增給沒叫貨的店若被可分配量擋下，正解是走「補貨申請」。
            </span>
          </div>
        )}

        <div className="overflow-auto p-3">
          {items === null ? (
            <div className="p-6 text-center text-sm text-zinc-500">載入中…</div>
          ) : (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="sticky top-0 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <th className="sticky left-0 z-10 bg-zinc-50 px-3 py-2 text-left text-xs uppercase text-zinc-500 dark:bg-zinc-900">
                    品名
                  </th>
                  <th className="px-2 py-2 text-left text-xs uppercase text-zinc-500">項目</th>
                  {stores.map((s) => (
                    <th
                      key={s.id}
                      className="px-2 py-2 text-right text-xs uppercase text-zinc-500"
                    >
                      {s.name}
                      {/* 已停用但本單有列 → 一定要標出來，⛔ 不可以長得跟正常的店一樣
                          （藏起來或不標，都是拿異常狀態冒充一切正常） */}
                      {s.is_active === false && (
                        <span className="ml-1 inline-block rounded bg-amber-100 px-1 py-0.5 text-[10px] font-medium normal-case text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                          已停用
                        </span>
                      )}
                    </th>
                  ))}
                  <th className="px-3 py-2 text-right text-xs uppercase text-zinc-500">合計</th>
                </tr>
              </thead>
              <tbody className="divide-y-2 divide-zinc-300 dark:divide-zinc-700">
                {skuList.map((sku) => {
                  const row = matrix.get(sku.id);
                  // 這次新加的量。新列的 qty 與 picked_qty 一樣（rpc_add_wave_item 兩個都寫 p_qty），
                  // 所以應發與實分都要加同一個數 → 對 totalDiff 的貢獻是 0，不會假裝成超賣。
                  const newForSku = stores.reduce(
                    (s, st) => s + (row?.get(st.id) ? 0 : (newCellQty(sku.id, st.id) ?? 0)),
                    0,
                  );
                  const expectedTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    return it ? s + Number(it.qty) : s;
                  }, 0) + newForSku;
                  const actualTotal = stores.reduce((s, st) => {
                    const it = row?.get(st.id);
                    if (!it) return s;
                    const edit = edits.get(it.id);
                    const v = edit !== undefined ? Number(edit) : Number(it.picked_qty ?? it.qty);
                    return s + (Number.isNaN(v) ? 0 : v);
                  }, 0) + newForSku;
                  const totalDiff = actualTotal - expectedTotal;
                  // 總倉可用量 vs 這次要出的量。⛔ avail === null ＝「沒讀到」，
                  //   絕對不可以當成 0 顯示成缺貨（見 hqAvail 的說明）。
                  const avail = hqAvail?.get(sku.id) ?? null;
                  const shortStock = avail !== null ? Math.max(0, actualTotal - avail) : 0;
                  let skuShortStores = 0;
                  let skuShortQty = 0;
                  if (row) {
                    for (const st of stores) {
                      const it = row.get(st.id);
                      if (!it) continue;
                      const e = edits.get(it.id);
                      const v = Number(e !== undefined ? e : (it.picked_qty ?? it.qty));
                      if (!Number.isNaN(v) && v < Number(it.qty)) {
                        skuShortStores += 1;
                        skuShortQty += Number(it.qty) - v;
                      }
                    }
                  }
                  const skuHasShortage = skuShortStores > 0;
                  return (
                    <Fragment key={sku.id}>
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td
                          rowSpan={3}
                          className={`sticky left-0 px-3 py-2 align-top ${skuHasShortage ? "bg-red-50 dark:bg-red-950/30" : "bg-white dark:bg-zinc-900"}`}
                        >
                          <div className="font-medium">{sku.product_name ?? "—"}</div>
                          <div className="text-xs text-zinc-500">
                            {sku.sku_code}{sku.variant_name ? ` / ${sku.variant_name}` : ""}
                          </div>
                          {skuHasShortage && (
                            <div className="mt-1 inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-medium text-red-700 dark:bg-red-950 dark:text-red-300">
                              ⚠ 短缺 {skuShortStores} 店 / {skuShortQty} 件
                            </div>
                          )}
                          {/* 切片 A：總倉庫存不夠時，就地把庫存補上（老闆：「有辦法在旁邊幫我加一個鈕
                              就是增加庫存嗎」）。後端零改動，用的是庫存總覽那支 rpc_add_stock_by_product。 */}
                          {!locked && (
                            <div className="mt-1 flex flex-wrap items-center gap-1">
                              <span
                                className={`inline-block rounded px-1.5 py-0.5 text-[10px] font-medium ${
                                  avail === null
                                    ? "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                                    : shortStock > 0
                                    ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                                    : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                                }`}
                                title={
                                  "總倉可用量 ＝ 在庫 − 已保留。" +
                                  "改既有格子的數量時，派貨出倉扣的就是這個數字。\n" +
                                  "⚠ 但「新增給沒叫貨的店」不看這個數字 —— 那一條受這張採購單的" +
                                  "可分配量（進貨 − 已派）限制，補庫存不會讓它變大。"
                                }
                              >
                                {/* ⛔ 讀不到就要講「讀不到」，不可以顯示 0 —— 那跟真的沒貨長得一模一樣 */}
                                {avail === null
                                  ? "總倉庫存讀不到"
                                  : shortStock > 0
                                  ? `總倉可用 ${avail}，短少 ${shortStock}`
                                  : `總倉可用 ${avail}`}
                              </span>
                              {/* P2（阿審 #762）：沒短缺就不給按 —— 這顆鈕寫的是不可逆的手動調整，
                                  不需要的時候擺在那裡只會被誤按。
                                  ⛔ 但 avail === null（庫存讀不到）**照樣給按**：那是「不知道有沒有短缺」，
                                    把它當成「沒短缺」而擋住，就是拿系統異常替老闆做決定。 */}
                              <SpinButton
                                onClick={() =>
                                  setAddStock({ sku, qty: Math.max(1, Math.ceil(shortStock)) })
                                }
                                disabled={hqLocId === null || (avail !== null && shortStock <= 0)}
                                title={
                                  hqLocId === null
                                    ? "找不到總倉 location，請先確認倉庫設定"
                                    : avail !== null && shortStock <= 0
                                    ? "總倉庫存夠，不需要補"
                                    : "對總倉補一筆手動庫存（不可刪除、不可修改）。\n" +
                                      "⚠ 只會增加總倉庫存，不會增加這張採購單的可分配量 ——" +
                                      "要多給沒叫貨的店，請走「補貨申請」。"
                                }
                                className="rounded border border-emerald-300 px-1.5 py-0.5 text-[10px] font-semibold text-emerald-700 hover:bg-emerald-50 disabled:opacity-40 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
                              >
                                ＋ 補庫存
                              </SpinButton>
                            </div>
                          )}
                        </td>
                        <td className="px-2 py-1 text-xs text-zinc-500">應發</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (it) {
                            return (
                              <td key={st.id} className="px-2 py-1 text-right font-mono text-zinc-500">
                                {Number(it.qty)}
                              </td>
                            );
                          }
                          // 這一格原本沒有人叫貨。填了數字之後，新列的應發＝填的數字
                          // （rpc_add_wave_item 把 qty 與 picked_qty 都設成同一個值）。
                          const nq = newCellQty(sku.id, st.id);
                          return (
                            <td key={st.id} className="px-2 py-1 text-right font-mono">
                              {nq !== null ? (
                                <span className="text-sky-700 dark:text-sky-300">{nq}</span>
                              ) : (
                                <span className="text-zinc-300">·</span>
                              )}
                            </td>
                          );
                        })}
                        <td className="px-3 py-1 text-right font-mono text-zinc-600">{expectedTotal}</td>
                      </tr>
                      <tr>
                        <td className="px-2 py-1 text-xs font-semibold">實分</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          // ⭐ 切片 B：原本這裡是唯讀的「·」。改成可以填 —— 填了就用
                          //   rpc_add_wave_item 補一列（campaign_id = NULL，不用有團、不用有客人訂單）。
                          //   視覺上刻意用**虛線框 + 天藍色**，與既有列（實線框）一眼分得開。
                          if (!it) {
                            const raw = newCells.get(cellKey(sku.id, st.id)) ?? "";
                            const bad = raw.trim() !== "" && newCellQty(sku.id, st.id) === null;
                            return (
                              <td key={st.id} className="px-1 py-1 text-right">
                                <input
                                  inputMode="decimal"
                                  disabled={locked}
                                  value={raw}
                                  placeholder="＋"
                                  onChange={(e) => setNewCell(sku.id, st.id, e.target.value)}
                                  title={`${st.name}原本沒有叫貨，填了數量就會新增一列`}
                                  className={`w-14 rounded-md border border-dashed px-1 py-0.5 text-right font-mono text-sm font-semibold placeholder:font-normal placeholder:text-zinc-300 disabled:opacity-60 ${
                                    bad
                                      ? "border-red-400 bg-red-50 text-red-700 dark:border-red-700 dark:bg-red-950 dark:text-red-300"
                                      : raw.trim() !== ""
                                      ? "border-sky-500 bg-sky-50 text-sky-800 dark:border-sky-600 dark:bg-sky-950 dark:text-sky-200"
                                      : "border-zinc-300 bg-transparent dark:border-zinc-700"
                                  }`}
                                />
                              </td>
                            );
                          }
                          const edit = edits.get(it.id);
                          const cur = edit !== undefined ? edit : String(it.picked_qty ?? it.qty);
                          const curNum = Number(cur);
                          const expNum = Number(it.qty);
                          const isShort = !Number.isNaN(curNum) && curNum < expNum;
                          const isOver = !Number.isNaN(curNum) && curNum > expNum;
                          const isEdited = edit !== undefined;
                          const isShippedItem = it.generated_transfer_id !== null;
                          const inputCls = isShort
                            ? "border-red-400 bg-red-50 text-red-700 dark:border-red-700 dark:bg-red-950 dark:text-red-300"
                            : isOver
                            ? "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-700 dark:bg-purple-950 dark:text-purple-300"
                            : isEdited
                            ? "border-amber-400 bg-amber-50 dark:bg-amber-950"
                            : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800";
                          return (
                            <td
                              key={st.id}
                              className={`px-1 py-1 text-right ${isShort ? "bg-red-50/50 dark:bg-red-950/20" : ""}`}
                            >
                              <input
                                inputMode="decimal"
                                disabled={isShippedItem || effectiveStatus === "shipped"}
                                value={cur}
                                onChange={(e) => setEdit(it.id, e.target.value)}
                                className={`w-14 rounded-md border px-1 py-0.5 text-right font-mono text-sm font-semibold ${inputCls} disabled:opacity-60`}
                              />
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono font-semibold ${
                          totalDiff < 0
                            ? "text-red-700 dark:text-red-300"
                            : totalDiff > 0
                            ? "text-purple-700 dark:text-purple-300"
                            : ""
                        }`}>
                          {actualTotal}
                        </td>
                      </tr>
                      <tr className={skuHasShortage ? "bg-red-50/60 dark:bg-red-950/20" : "bg-zinc-50/50 dark:bg-zinc-900/50"}>
                        <td className="px-2 py-1 text-xs text-zinc-500">狀態</td>
                        {stores.map((st) => {
                          const it = row?.get(st.id);
                          if (!it) {
                            const raw = newCells.get(cellKey(sku.id, st.id)) ?? "";
                            const nq = newCellQty(sku.id, st.id);
                            if (raw.trim() === "") {
                              return <td key={st.id} className="px-2 py-1 text-right text-zinc-300">—</td>;
                            }
                            // ⛔ 填了但不是有效正數 → 一定要當場標紅，不可以看起來跟沒填一樣
                            //   （本專案反覆踩過的靜默丟失：填了、沒存進去、畫面零提示）
                            return (
                              <td key={st.id} className="px-2 py-1 text-right">
                                <span
                                  className={`inline-block rounded px-1.5 py-0.5 text-[10px] font-semibold ${
                                    nq === null
                                      ? "bg-red-100 text-red-700 dark:bg-red-950 dark:text-red-300"
                                      : "bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-300"
                                  }`}
                                >
                                  {nq === null ? "數字不對" : `+${nq} 新增`}
                                </span>
                              </td>
                            );
                          }
                          const edit = edits.get(it.id);
                          const cur = Number(edit !== undefined ? edit : (it.picked_qty ?? it.qty));
                          const diff = !Number.isNaN(cur) ? cur - Number(it.qty) : 0;
                          if (diff === 0) {
                            return <td key={st.id} className="px-2 py-1 text-right text-xs text-zinc-400">—</td>;
                          }
                          if (diff > 0) {
                            return (
                              <td key={st.id} className="px-2 py-1 text-right">
                                <span className="inline-block rounded bg-purple-100 px-1.5 py-0.5 text-[10px] font-semibold text-purple-700 dark:bg-purple-950 dark:text-purple-300">
                                  +{diff} 超賣
                                </span>
                              </td>
                            );
                          }
                          return (
                            <td key={st.id} className="bg-red-50/50 px-2 py-1 text-right dark:bg-red-950/20">
                              <span className="inline-block rounded bg-red-100 px-1.5 py-0.5 text-[10px] font-semibold text-red-700 dark:bg-red-950 dark:text-red-300">
                                {diff} 短缺
                              </span>
                            </td>
                          );
                        })}
                        <td className={`px-3 py-1 text-right font-mono text-xs font-semibold ${
                          totalDiff === 0
                            ? "text-emerald-600 dark:text-emerald-400"
                            : totalDiff > 0
                            ? "text-purple-600 dark:text-purple-400"
                            : "text-red-600 dark:text-red-400"
                        }`}>
                          {totalDiff === 0 ? "✓" : (totalDiff > 0 ? `+${totalDiff}` : `${totalDiff}`)}
                        </td>
                      </tr>
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {/* 切片 A：就地補總倉庫存。用的是庫存總覽那一支既有的彈窗與 RPC，後端零改動。
          倉別鎖成總倉（locked）、商品鎖成這一列（presetSku）、數量預設帶短少的差額。
          ⛔ 存完不關 PickModal，只重載一次數字 —— 老闆補完貨要能接著按「派貨出倉」。 */}
      {addStock && hqLocId !== null && (
        <AddStockModal
          locations={[{ id: hqLocId, label: "總倉" }]}
          defaultLocationId={String(hqLocId)}
          locked
          presetSku={addStock.sku}
          defaultQty={addStock.qty}
          onClose={() => setAddStock(null)}
          onSaved={() => setReloadTick((n) => n + 1)}
        />
      )}
    </div>
  );
}
