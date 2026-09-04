"use client";

import { Suspense, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { SendPOModal } from "@/components/SendPOModal";
import SpinButton from "@/components/SpinButton";
import { poStatusLabel, PO_TERM_ZH } from "@/lib/poStatus";

type Supplier = {
  id: number;
  name: string;
  code: string | null;
  preferred_po_channel: string | null;
  line_contact: string | null;
  email: string | null;
  phone: string | null;
};

type POHeader = {
  id: number;
  po_no: string;
  status: string;
  supplier_id: number;
  dest_location_id: number;
  order_date: string;
  expected_date: string | null;
  subtotal: number;
  total: number;
  payment_terms: string | null;
  notes: string | null;
  sent_at: string | null;
  sent_by: string | null;
  sent_channel: string | null;
  stockout_at: string | null;
  stockout_reason: string | null;
  stockout_split_from_po_id: number | null;
  stockout_restored_at: string | null;
  created_by: string | null;
  created_at: string | null;
  updated_at: string | null;
};

/** 斷貨拆單的另一端：本單拆出去的斷貨單，或本單的來源單 */
type LinkedPO = { id: number; po_no: string; status: string };

type Item = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_uom: string | null;
  qty_ordered: number;
  qty_received: number;
  qty_returned: number;
  qty_shipped: number;
  unit_cost: number;
  line_subtotal: number;
  notes: string | null;
  stockout_at: string | null;
  stockout_reason: string | null;
  // 20260902030000：確定短少 —— 廠商說「這幾件不會到」，但其餘照到、照派。
  // ⛔ 與斷貨的分工：斷貨＝整項供不了（會取消該團所有客人）；這裡＝只少幾件。
  confirmed_shortfall: number | null;
  confirmed_shortfall_at: string | null;
};

const STATUS_LABEL = poStatusLabel;

export default function EditPurchaseOrderPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <PageContent />
    </Suspense>
  );
}

function PageContent() {
  const router = useRouter();
  const params = useSearchParams();
  const idStr = params.get("id");
  const id = idStr ? Number(idStr) : null;

  const [header, setHeader] = useState<POHeader | null>(null);
  const [items, setItems] = useState<Item[]>([]);
  const [supplier, setSupplier] = useState<Supplier | null>(null);
  const [splitPOs, setSplitPOs] = useState<LinkedPO[]>([]);
  const [sourcePO, setSourcePO] = useState<LinkedPO | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showSend, setShowSend] = useState(false);

  // 回傳「這次重新載入有沒有成功」。儲存流程要靠它決定能不能把編輯值清掉：
  // 這裡的 catch 只 setError 不 rethrow，所以呼叫端的 await 永遠不會炸；
  // 若 RPC 已存進去、但接著這支查詢失敗，items 還停在舊值，這時清掉編輯值
  // 會讓畫面「乾淨地顯示舊數字」＝謊報沒存到。
  // 既有呼叫點（useEffect / 斷貨 / 回復 / SendPOModal）忽略回傳值，行為不變。
  async function reload(): Promise<boolean> {
    if (!id) return false;
    setLoading(true);
    try {
      const supabase = getSupabase();
      const [{ data: poData, error: poErr }, { data: itemRows, error: itemErr }] = await Promise.all([
        supabase
          .from("purchase_orders")
          .select(
            "id, po_no, status, supplier_id, dest_location_id, order_date, expected_date, subtotal, total, payment_terms, notes, sent_at, sent_by, sent_channel, stockout_at, stockout_reason, stockout_split_from_po_id, stockout_restored_at, created_by, created_at, updated_at",
          )
          .eq("id", id)
          .maybeSingle(),
        supabase
          .from("purchase_order_items")
          .select("id, sku_id, qty_ordered, qty_received, qty_returned, unit_cost, line_subtotal, notes, stockout_at, stockout_reason, confirmed_shortfall, confirmed_shortfall_at")
          .eq("po_id", id)
          .order("id"),
      ]);
      if (poErr || !poData) throw new Error(poErr?.message ?? `找不到${PO_TERM_ZH}`);
      if (itemErr) throw new Error(itemErr.message);
      setHeader(poData as POHeader);

      // 斷貨拆單的兩端：本單拆出去的斷貨單 / 本單的來源單
      const { data: splitRows } = await supabase
        .from("purchase_orders")
        .select("id, po_no, status")
        .eq("stockout_split_from_po_id", id)
        .order("id");
      setSplitPOs((splitRows as LinkedPO[] | null) ?? []);

      if (poData.stockout_split_from_po_id) {
        const { data: srcRow } = await supabase
          .from("purchase_orders")
          .select("id, po_no, status")
          .eq("id", poData.stockout_split_from_po_id)
          .maybeSingle();
        setSourcePO((srcRow as LinkedPO | null) ?? null);
      } else {
        setSourcePO(null);
      }

      // supplier
      if (poData.supplier_id) {
        const { data: supRow } = await supabase
          .from("suppliers")
          .select("id, name, code, preferred_po_channel, line_contact, email, phone")
          .eq("id", poData.supplier_id)
          .maybeSingle();
        setSupplier((supRow as Supplier | null) ?? null);
      }

      // items + sku JOIN
      const skuIds = (itemRows ?? []).map((r) => r.sku_id);
      const { data: skuRows } = skuIds.length
        ? await supabase
            .from("skus")
            .select("id, sku_code, variant_name, base_unit, products!inner(name)")
            .in("id", skuIds)
        : { data: [] as unknown[] };

      type SkuLite = {
        id: number;
        sku_code: string;
        variant_name: string | null;
        base_unit: string | null;
        products: { name: string } | { name: string }[];
      };
      const skuMap = new Map<number, { sku_code: string; variant_name: string | null; product_name: string; unit_uom: string | null }>();
      for (const s of (skuRows as SkuLite[] | null) ?? []) {
        const prod = Array.isArray(s.products) ? s.products[0] : s.products;
        skuMap.set(s.id, {
          sku_code: s.sku_code,
          variant_name: s.variant_name,
          product_name: prod?.name ?? "?",
          unit_uom: s.base_unit ?? null,
        });
      }

      // 已出（衍生：該 PO 已揀/出貨波次本 sku 加總）
      const { data: shipRows } = await supabase.rpc("rpc_po_items_shipped", { p_po_id: id });
      const shipMap = new Map<number, number>();
      for (const s of (shipRows as { po_item_id: number; qty_shipped: number }[] | null) ?? []) {
        shipMap.set(Number(s.po_item_id), Number(s.qty_shipped));
      }

      const merged: Item[] = (itemRows ?? []).map((r) => {
        const m = skuMap.get(r.sku_id);
        return {
          id: r.id,
          sku_id: r.sku_id,
          sku_code: m?.sku_code ?? "?",
          product_name: m?.product_name ?? "?",
          variant_name: m?.variant_name ?? null,
          unit_uom: m?.unit_uom ?? null,
          qty_ordered: Number(r.qty_ordered),
          qty_received: Number(r.qty_received),
          qty_returned: Number(r.qty_returned),
          qty_shipped: shipMap.get(r.id) ?? 0,
          unit_cost: Number(r.unit_cost),
          line_subtotal: Number(r.line_subtotal ?? 0),
          notes: r.notes,
          stockout_at: r.stockout_at ?? null,
          stockout_reason: r.stockout_reason ?? null,
          // null 與 0 都當「沒填」（RPC 那邊也是 NULLIF(COALESCE(p_qty,0),0)）
          confirmed_shortfall:
            r.confirmed_shortfall == null ? null : Number(r.confirmed_shortfall) || null,
          confirmed_shortfall_at: r.confirmed_shortfall_at ?? null,
        };
      });
      setItems(merged);
      return true;
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      return false;
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  const totals = useMemo(() => {
    const subtotal = items.reduce((s, r) => s + r.qty_ordered * r.unit_cost, 0);
    return { subtotal };
  }, [items]);

  const editable = header?.status === "draft";
  // 已收量可調整：已發送之後（草稿請改訂購量；已結案/已取消鎖定）
  const recvEditable =
    header?.status === "sent" ||
    header?.status === "partially_received" ||
    header?.status === "fully_received";
  const canSend = header?.status === "draft";
  const canStockout =
    header?.status === "sent" || header?.status === "partially_received";
  const canDelete =
    header?.status === "draft" ||
    header?.status === "sent" ||
    header?.status === "cancelled";
  // 純斷貨單（沒有任何到貨量）才可回復；進貨單 / 撿貨波次的守衛在 RPC 那邊
  const canRestore =
    !!header?.stockout_at &&
    (header.status === "cancelled" || header.status === "closed") &&
    items.length > 0 &&
    items.every((r) => r.qty_received === 0);

  // ── 已收量：填值（全到／全部到齊）＋ 儲存（單格／全部儲存）────────────────
  // 編輯中的數值放父層（不是每格自己 useState）：不然「全部到齊」改不到別人的格子，
  // 父層也不知道誰有未存的改動、做不出「全部儲存」。
  // 只放使用者實際動過的格子；沒有 entry 就顯示 DB 的 qty_received。
  //
  // 除了輸入字串，還要記 base = 這一格「開始編輯」當下的 qty_received，
  // 也就是使用者是看著哪個數字做的判斷。RPC 是絕對值介面
  // （p_new_qty 直接成為終值，沒有 expected-old-value、沒有版本欄位，
  //  delta 是拿資料庫當下的值現算），所以「別人在我打字期間改過這一列」若不擋，
  // 送出去就是在本人完全不知情下覆蓋掉別人剛存的數字、而且真的動到庫存。
  const [recvEdits, setRecvEdits] = useState<Record<number, { value: string; base: number }>>({});
  const [recvErrs, setRecvErrs] = useState<Record<number, string>>({});
  const [recvSavingId, setRecvSavingId] = useState<number | null>(null);
  const [recvBatchSaving, setRecvBatchSaving] = useState(false);
  const [recvBatchResult, setRecvBatchResult] =
    useState<{ ok: number; failed: { label: string; msg: string }[]; reloadOk: boolean } | null>(null);

  // 斷貨品項的已收量後端會擋（RPC 守衛 2b），批次操作必須跟畫面用同一組條件。
  const recvRows = recvEditable ? items.filter((r) => !r.stockout_at) : [];
  const recvValue = (r: Item) => recvEdits[r.id]?.value ?? String(r.qty_received);
  const recvPending = recvRows.filter((r) => recvState(r, recvValue(r)).dirty);
  // RPC 會對母單 FOR UPDATE，同頁併發送出只會互相卡住 → 一次只讓一筆在飛。
  const recvBusy = recvSavingId !== null || recvBatchSaving;

  // 有值 = 這一格的輸入基於過期資料（值本身就是開始編輯時看到的已收量）。
  // 條件：開始編輯時的 base，和現在 items 裡的 qty_received 對不上了。
  const recvStaleBase = (r: Item) => {
    const e = recvEdits[r.id];
    return e !== undefined && e.base !== r.qty_received ? e.base : undefined;
  };
  const recvStaleMsg = (r: Item) =>
    `這一列已被更新為 ${r.qty_received}（你是看著 ${recvStaleBase(r)} 輸入的）。` +
    `已收量是直接覆蓋、不是累加，請確認後重新輸入。`;
  const recvStaleRows = recvRows.filter((r) => recvStaleBase(r) !== undefined);

  // base 只在這一格「開始編輯」時記一次；中途改字不重記，
  // 不然使用者一邊打字就一邊把 base 往前推，被別人更新過反而偵測不到。
  function setRecvEdit(r: Item, value: string) {
    setRecvEdits((prev) => ({
      ...prev,
      [r.id]: { value, base: prev[r.id]?.base ?? r.qty_received },
    }));
  }

  // 過期的格子唯一的出路：丟掉自己的輸入、退回目前的 DB 值，才能用新的 base 重打。
  // （若讓「再打一次字」就重記 base，上面那道防呆等於沒有。）
  function discardRecvEdit(r: Item) {
    setRecvEdits((prev) => {
      const next = { ...prev };
      delete next[r.id];
      return next;
    });
    setRecvErrs((prev) => {
      const next = { ...prev };
      delete next[r.id];
      return next;
    });
  }

  function fillReceived(r: Item) {
    setRecvEdit(r, String(r.qty_ordered));
  }

  // 只填值、不儲存。存下去會建進貨單 + rpc_confirm_gr 真的入庫，誤觸沒有反悔機會。
  function fillAllReceived() {
    const changing = recvRows.filter((r) => recvValue(r) !== String(r.qty_ordered));
    if (changing.length === 0) return;
    const overwrite = changing.filter((r) => recvEdits[r.id] !== undefined).length;
    if (
      !window.confirm(
        `把 ${changing.length} 個品項的已收量都填成訂購量？\n` +
          (overwrite > 0 ? `其中 ${overwrite} 格是你手動改過、還沒儲存的，會被蓋掉。\n` : "") +
          `\n這一步只填數字、不會入庫；要再按「全部儲存」才會真的進貨。`,
      )
    )
      return;
    setRecvEdits((prev) => {
      const next = { ...prev };
      // 同樣不重記 base：已經在編輯中的格子沿用原本的起點，過期偵測才不會被這一鍵洗掉。
      for (const r of recvRows) {
        next[r.id] = { value: String(r.qty_ordered), base: prev[r.id]?.base ?? r.qty_received };
      }
      return next;
    });
  }

  async function saveReceived(r: Item) {
    // 過期就擋，不送。RPC 沒有樂觀鎖，送出去等於直接覆蓋別人剛存的值。
    if (recvStaleBase(r) !== undefined) {
      setRecvErrs((prev) => ({ ...prev, [r.id]: recvStaleMsg(r) }));
      return;
    }
    const { num, floor, max, invalid } = recvState(r, recvValue(r));
    if (invalid) {
      setRecvErrs((prev) => ({ ...prev, [r.id]: `已收量需介於 ${floor}~${max}` }));
      return;
    }
    setRecvSavingId(r.id);
    // 單格存完，上一輪批次的「失敗 N 筆」就過期了（多半就是來修那幾筆的），別留在畫面上誤導。
    setRecvBatchResult(null);
    setRecvErrs((prev) => {
      const next = { ...prev };
      delete next[r.id];
      return next;
    });
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();

      // 送出前的即時確認（preflight）。只比對 items 不夠：items 只有本頁真的跑過 reload
      // 才會更新，而「打開單子慢慢填 12 格、中途一筆都沒存」就完全不會觸發 reload
      // —— 那時 items 停在剛載入的舊值，base 跟它相等會被判「沒過期」直接放行。
      const base = recvEdits[r.id]?.base ?? r.qty_received;
      const { data: freshRow, error: preErr } = await supabase
        .from("purchase_order_items")
        .select("qty_received")
        .eq("id", r.id)
        .maybeSingle();
      // ⚠️ 查不到／查詢失敗一律擋下，不可以當成「沒過期」照送 —— 那等於在最需要保護的時候關掉防線。
      if (preErr || !freshRow) {
        setRecvErrs((prev) => ({
          ...prev,
          [r.id]: `無法確認這一列有沒有被別人改過（${preErr?.message ?? "查不到這個品項"}），為了安全沒有送出。請重新整理後再試。`,
        }));
        return;
      }
      const freshQty = Number(freshRow.qty_received);
      if (freshQty !== base) {
        // 把真實值寫回這一列，既有的 recvStaleBase → 紅框／紅字／「改用最新值」就會自己接手，
        // 不必另外做一套過期狀態。
        setItems((prev) => prev.map((x) => (x.id === r.id ? { ...x, qty_received: freshQty } : x)));
        return;
      }

      const { error: rpcErr } = await supabase.rpc("rpc_adjust_po_item_received", {
        p_po_item_id: r.id,
        p_new_qty: num,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      // 只有 reload 真的成功才清編輯值：
      // 一定要等 reload 完才丟（先丟的話這一格會閃回舊的 qty_received 再跳成新值）；
      // 而 reload 失敗時 items 還停在舊值，這時清掉會變成「乾淨地顯示舊數字」＝謊報沒存到。
      if (await reload()) {
        setRecvEdits((prev) => {
          const next = { ...prev };
          delete next[r.id];
          return next;
        });
      } else {
        setRecvErrs((prev) => ({
          ...prev,
          [r.id]: "已存檔成功，但重新載入失敗；畫面數字可能不是最新的，請手動重新整理確認。",
        }));
      }
    } catch (e) {
      setRecvErrs((prev) => ({ ...prev, [r.id]: e instanceof Error ? e.message : String(e) }));
    } finally {
      setRecvSavingId(null);
    }
  }

  // 「全部儲存」：逐筆呼叫既有 RPC。每一筆都是各自獨立的交易——成功的就真的入庫了，
  // 沒有整批 rollback 這回事，所以：
  //   ① 迴圈中間不 reload（跑完再 reload 一次）；
  //   ② 失敗要逐筆講出是哪一樣、為什麼，不能只丟一句籠統的錯，不然不知道到底進了多少貨；
  //   ③ 只送真的有改動的（delta = 0 後端會直接 return，沒必要送）。
  async function saveAllReceived() {
    const targets = recvPending;
    if (targets.length === 0) return;
    setRecvBatchSaving(true);
    setRecvBatchResult(null);
    const errs: Record<number, string> = {};
    const failed: { label: string; msg: string }[] = [];
    const okIds: number[] = [];
    let reloadOk = true;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();

      // 送出前的即時確認（preflight）：一個 in 查詢一次拿完所有要送的列，不是每列查一次。
      // 理由同單筆 —— items 只有本頁跑過 reload 才會更新，慢慢填一整張單的話它是舊的。
      const { data: freshRows, error: preErr } = await supabase
        .from("purchase_order_items")
        .select("id, qty_received")
        .in("id", targets.map((t) => t.id));
      const freshMap = new Map<number, number>();
      for (const fr of (freshRows as { id: number; qty_received: number }[] | null) ?? []) {
        freshMap.set(Number(fr.id), Number(fr.qty_received));
      }
      // 查到的真實值寫回 items，既有的 recvStaleBase → 紅框／紅字／「改用最新值」自己接手。
      if (!preErr && freshMap.size > 0) {
        setItems((prev) =>
          prev.map((x) => {
            const fq = freshMap.get(x.id);
            return fq === undefined ? x : { ...x, qty_received: fq };
          }),
        );
      }

      for (const r of targets) {
        const label = r.product_name + (r.variant_name ? `-${r.variant_name}` : "");
        // 過期的那幾列擋掉就好，其他列照存 —— 本來就沒有整批 rollback，
        // 為了一列全擋反而讓人更難收拾。
        if (recvStaleBase(r) !== undefined) {
          const msg = recvStaleMsg(r);
          errs[r.id] = msg;
          failed.push({ label, msg });
          continue;
        }
        // ⚠️ 查不到／查詢失敗一律擋下這一筆，不可以當成「沒過期」照送。
        const base = recvEdits[r.id]?.base ?? r.qty_received;
        const fresh = freshMap.get(r.id);
        if (preErr || fresh === undefined) {
          const msg = `無法確認有沒有被別人改過（${preErr?.message ?? "查不到這個品項"}），為了安全沒有送出`;
          errs[r.id] = msg;
          failed.push({ label, msg });
          continue;
        }
        if (fresh !== base) {
          const msg = `已被別人改成 ${fresh}（你是看著 ${base} 輸入的），沒有送出`;
          errs[r.id] = msg;
          failed.push({ label, msg });
          continue;
        }
        const { num, floor, max, invalid } = recvState(r, recvValue(r));
        if (invalid) {
          // 不靜默跳過：跳過會讓人以為那一格存好了。
          const msg = `已收量需介於 ${floor}~${max}`;
          errs[r.id] = msg;
          failed.push({ label, msg });
          continue;
        }
        const { error: rpcErr } = await supabase.rpc("rpc_adjust_po_item_received", {
          p_po_item_id: r.id,
          p_new_qty: num,
          p_operator: userData.user?.id,
        });
        if (rpcErr) {
          errs[r.id] = rpcErr.message;
          failed.push({ label, msg: rpcErr.message });
        } else {
          okIds.push(r.id);
        }
      }
      // 同單筆：reload 失敗就不清編輯值，否則已經入庫的那幾列會被顯示成「舊值且乾淨」，
      // 老闆會以為那批貨沒進到。
      reloadOk = await reload();
      if (reloadOk) {
        setRecvEdits((prev) => {
          const next = { ...prev };
          for (const okId of okIds) delete next[okId];
          return next;
        });
      }
    } catch (e) {
      failed.push({ label: "（整批）", msg: e instanceof Error ? e.message : String(e) });
    } finally {
      setRecvErrs(errs);
      setRecvBatchResult({ ok: okIds.length, failed, reloadOk });
      setRecvBatchSaving(false);
    }
  }

  async function stockoutItem(item: Item) {
    const label = item.product_name + (item.variant_name ? `-${item.variant_name}` : "");
    const remaining = item.qty_ordered - item.qty_received;
    const reason = window.prompt(
      `將品項「${label}」標記為「斷貨」？\n供應商無法供貨時使用：未到的 ${remaining} ${item.unit_uom ?? "件"}不再等待；` +
        (item.qty_received === 0
          ? `這個品項會被自動拆到一張「斷貨單」（可在採購單列表的「斷貨」分頁一鍵回復）。`
          : `這個品項已有到貨，會留在本單、只停止等待未到的量。`) +
        `\n\n可填寫斷貨原因（可留空）：`,
    );
    if (reason === null) return;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: res, error: rpcErr } = await supabase.rpc("rpc_stockout_po_item", {
        p_po_item_id: item.id,
        p_operator: userData.user?.id,
        p_reason: reason || null,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const r = (res ?? {}) as Record<string, unknown>;
      if (r.stockout_po_no) {
        alert(
          `已標記斷貨，並拆出斷貨單 ${String(r.stockout_po_no)}（共 ${Number(r.stockout_po_items ?? 0)} 項）。\n` +
            `供應商補到貨時，可在該單按「回復斷貨」變回未採購狀態重跑流程。`,
        );
      }
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  // ── 確定短少（20260902030000）────────────────────────────────────────────
  // 廠商說「這幾件確定不會到」，但其餘照到、照派 —— 跟「斷貨」是兩件事：
  //   斷貨   ＝ 整個品項供應商完全給不了 → 取消該團**所有**訂這個商品的客人
  //   確定短少 ＝ 只少幾件 → 只把**最晚下單的 N 件**標待補貨，其他人不受影響
  //
  // ⛔ 這顆只「標記」：不動庫存、不建任何單、**不通知客人**。
  //   要通知走下面那顆「確定斷貨並通知」。兩步分開是刻意的 ——
  //   標記之後還有反悔窗（廠商又生出貨來就把數字清掉，貨到會自動解除）。
  async function setConfirmedShortfall(item: Item) {
    const label = item.product_name + (item.variant_name ? `-${item.variant_name}` : "");
    const outstanding = item.qty_ordered - item.qty_received;
    const unit = item.unit_uom ?? "件";
    // 貨補齊了／單子不在收貨中／**這個品項被按了斷貨** → 只剩「清除」這條路可走。
    // ⛔ 這時不可以還把畫面寫成「要填幾件」，那是一個一按就會被後端擋掉的指令。
    //    （三種情況後端擋的守衛不同，但對操作的人來說都是同一句話：只能清、不能改。）
    const clearOnly =
      !!item.stockout_at || !(canStockout && item.qty_received < item.qty_ordered);
    if (clearOnly) {
      const why = item.stockout_at
        ? "這個品項已經被標記斷貨"
        : "這張單已經不在收貨中（或貨已補齊）";
      // 「已取消 X 件救不回來」的 X **一定要是真數**。
      // ⛔ 這句話的重點就是那個數字；寫死 0 或省略掉，等於把最該讓人猶豫的
      //   資訊藏起來（客人已經收到取消通知了，清除救不回）。
      // ⚠️ 查不到就照實說「查不到」，⛔ 不可以退回 0 —— 0 看起來像「沒有人被取消」，
      //   那是一句可能不是事實的話。
      let settledLine: string;
      try {
        const { data: pre, error: preErr } = await getSupabase().rpc(
          "rpc_get_confirmed_shortfall_items",
          { p_po_item_id: item.id },
        );
        if (preErr) throw new Error(preErr.message);
        const already = Number((pre as { cancelled_qty?: number } | null)?.cancelled_qty ?? 0);
        settledLine =
          already > 0
            ? `　· ⚠ 先前已經「確定斷貨並通知」的 ${already}${unit} **收不回來**（客人已經收到通知了）`
            : `　· 目前沒有因為這筆短少而取消掉的訂單`;
      } catch {
        settledLine = `　· ⚠ 查不到「已經確定斷貨並通知幾件」（查詢失敗）—— 已確定斷貨的一律收不回來`;
      }
      if (
        !window.confirm(
          `「${label}」目前記著「確定短少 ${item.confirmed_shortfall}${unit}」，` +
            `但${why}，**不能再改數字**。\n\n` +
            `要清除這個標記嗎？\n` +
            `　· 會把因為它而待補貨的客人品項收回（那些人恢復正常等貨／可取貨）\n` +
            `${settledLine}`,
        )
      )
        return;
    }
    const input = clearOnly ? "0" : window.prompt(
      `「${label}」廠商確定不會到幾${unit}？\n\n` +
        `訂購 ${item.qty_ordered}、已收 ${item.qty_received}、未到 ${outstanding}${unit}。\n` +
        `填了之後，系統會把這一團**最晚下單的 N ${unit}**標成「待補貨」：\n` +
        // ⛔ 措辭只講「結果的狀態」不講「從 X 移到 Y」：貨還沒到的時候客人本來就
        //    在「待到貨」，寫成搬移會讓人以為畫面上看得到變化，其實多半沒有。
        `　· 這幾件會歸在客人訂單頁的「待到貨」，取貨頁不會放行\n` +
        `　· 這一步**不會通知客人、也不會取消任何訂單**\n` +
        `　· 廠商後來又生出貨來：把這個數字清掉就會立刻收回這些待補貨標記\n` +
        `　· 沒清掉也沒關係 —— 貨收進店裡而且量夠的時候，系統會自動解除\n\n` +
        `留空或填 0 ＝ 清除（把先前標的待補貨收回來）。`,
      item.confirmed_shortfall != null ? String(item.confirmed_shortfall) : "",
    );
    if (input === null) return;
    const qty = input.trim() === "" ? 0 : Number(input);
    // 阿審 P2：件數就是整數，前後端都擋（後端 RPC 也有 trunc 檢查）
    if (!Number.isFinite(qty) || qty < 0 || !Number.isInteger(qty)) {
      alert("請填 0 或正整數（件數不接受小數）。");
      return;
    }
    if (qty > outstanding) {
      alert(`確定短少 ${qty} 超過未到量 ${outstanding}${unit}。\n若整項都不會到，請改按「斷貨」。`);
      return;
    }
    try {
      const supabase = getSupabase();
      // ⛔ 不再傳 p_operator：後端一律用 auth.uid()，杜絕冒名（阿審 P0-1）
      const { data: res, error: rpcErr } = await supabase.rpc("rpc_set_confirmed_shortfall", {
        p_po_item_id: item.id,
        p_qty: qty === 0 ? null : qty,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const r = (res ?? {}) as Record<string, number | null>;
      const marked = Number(r.marked ?? 0);
      const cleared = Number(r.cleared ?? 0);
      const merged = Number(r.merged ?? 0);
      const settled = Number(r.settled ?? 0);
      const unmet = Number(r.unmet ?? 0);
      if (qty === 0) {
        alert(
          `已清除「${label}」的確定短少${cleared > 0 ? `，收回 ${cleared} 筆待補貨` : ""}。` +
            (merged > 0 ? `\n其中 ${merged} 筆是先前拆出來的行，已併回原訂單列。` : "") +
            // 已取消的不收回，也不假裝收回了
            (settled > 0
              ? `\n\n⚠ 先前已經「確定斷貨並通知」的 ${settled}${unit} **不會**被收回（客人已經收到通知了）。`
              : ""),
        );
      } else {
        alert(
          `已記錄「${label}」確定短少 ${qty}${unit}。\n` +
            (settled > 0 ? `其中 ${settled}${unit} 先前已確定斷貨並通知過，這次不重複處理。\n` : "") +
            `這次標成待補貨：${marked} 筆` +
            (Number(r.split ?? 0) > 0 ? `（其中 ${Number(r.split)} 筆是拆行：同一張訂單一部分可取、一部分待補）` : "") +
            (cleared > 0
              ? `\n先前標的 ${cleared} 筆已先收回重算${merged > 0 ? `（${merged} 筆併回原訂單列）` : ""}。`
              : "") +
            // ⛔ 標不滿要照實講：等貨的客人不夠多時 unmet > 0，
            //   不可以讓畫面看起來像「3 件都處理掉了」。
            (unmet > 0
              ? `\n\n⚠ 還有 ${unmet}${unit} 沒有標到 —— 目前在等這樣商品的客人不夠多（或剩下的都已經可取貨了）。`
              : "") +
            `\n\n要通知這些客人請按同一列的「✕ 確定斷貨並通知」。`,
        );
      }
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  // 對因「確定短少」被標成待補貨的客人品項確定斷貨，並通知（20260902030000 / G1、G3）
  // ⛔ 這條鏈上的文案不要改回「取消／取消並通知」—— 2026-09-04 老闆原話
  //   「你的取消 我根本不知道取消什麼」。改名理由寫在畫面那顆鈕上面（搜「鈕名不要改回」）。
  // ⚠️ item ids **按下當下重查**，不沿用標記時回傳的 —— 中間客人可能自己取消、
  //    或補到貨被 _settle_arrived_backorders 自動解除（見該 RPC 的 COMMENT）。
  async function cancelShortfallBackorders(item: Item) {
    const label = item.product_name + (item.variant_name ? `-${item.variant_name}` : "");
    const unit = item.unit_uom ?? "件";
    try {
      const supabase = getSupabase();
      const { data: listed, error: listErr } = await supabase.rpc(
        "rpc_get_confirmed_shortfall_items",
        { p_po_item_id: item.id },
      );
      if (listErr) throw new Error(listErr.message);
      const info = (listed ?? {}) as {
        items?: {
          item_id: number;
          order_no: string;
          store_name: string | null;
          qty: number;
          notifiable: boolean;
          created_at: string;
        }[];
        marked_qty?: number;
        cancelled_qty?: number;
        notifiable?: number;
        unnotifiable?: number;
      };
      const rows = info.items ?? [];
      const ids = rows.map((x) => Number(x.item_id));
      if (ids.length === 0) {
        alert(`「${label}」目前沒有因確定短少而待補貨的品項（可能已補到貨自動解除，或已經確定斷貨過了）。`);
        await reload();
        return;
      }
      const notifiable = Number(info.notifiable ?? 0);
      const unnotifiable = Number(info.unnotifiable ?? 0);
      // 阿審 P1-6：取消前要先看得到名單。⛔ 不可以只給一個數字就叫人按不可復原的鈕。
      // ⚠️ 太多筆時截斷，但**要講出截斷了**（⛔ 不可以讓人以為看到的就是全部）。
      const LIST_CAP = 25;
      const shown = rows.slice(0, LIST_CAP);
      const listText =
        shown
          .map(
            (x) =>
              `　${x.order_no}｜${x.store_name ?? "（未知分店）"}｜${x.qty} ${unit}` +
              `｜${x.notifiable ? "會收到通知" : "⚠ 沒綁會員，收不到"}`,
          )
          .join("\n") +
        (rows.length > LIST_CAP ? `\n　…以上只列出前 ${LIST_CAP} 筆，實際會取消 ${rows.length} 筆` : "");
      if (
        !window.confirm(
          `對「${label}」這 ${ids.length} 筆待補貨（共 ${Number(info.marked_qty ?? 0)} ${unit}）確定斷貨並通知客人？\n\n` +
            // 老闆 2026-09-04：「你的取消 我根本不知道取消什麼」→ 名單前面要有一句
            // 明講「這張名單就是會被處理掉的東西」，不要讓人自己猜。
            `將對以下客人品項確定斷貨：\n` +
            `${listText}\n\n` +
            // 兩個數字都是後端現查的，不是估的（rpc_get_confirmed_shortfall_items）
            `　· ${notifiable} 筆綁了會員 → 會收到「商品斷貨通知」\n` +
            `　· ${unnotifiable} 筆沒綁會員 → 收不到通知，要請店家自己聯繫\n` +
            (Number(info.cancelled_qty ?? 0) > 0
              ? `　· 另有 ${Number(info.cancelled_qty)} ${unit}先前已經確定斷貨過，不重複處理\n`
              : "") +
            `\n品項會標成斷貨取消；整張訂單品項都沒了且沒收過錢的，訂單也會一併取消。\n` +
            `此動作不可復原。`,
        )
      )
        return;
      const { data: userData } = await supabase.auth.getUser();
      const { data: res, error: rpcErr } = await supabase.rpc("rpc_cancel_backorder_items", {
        p_item_ids: ids,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const r = (res ?? {}) as Record<string, number>;
      // ⛔「訂單」那個數字講的是真的被取消掉的整張訂單（orders_cancelled），
      //    不可以一起改寫成「確定斷貨」—— 那會把兩種不同的結果混成一句話。
      alert(
        `已確定斷貨 ${r.items_cancelled ?? 0} 個品項、連帶取消 ${r.orders_cancelled ?? 0} 張訂單` +
          (r.orders_completed ? `，${r.orders_completed} 張已取完的訂單結單` : "") +
          `。\n已發出 ${r.notified ?? 0} 則通知（一位會員一則）。`,
      );
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  async function restorePO() {
    if (!header) return;
    if (
      !window.confirm(
        `確定要回復 ${header.po_no} 的斷貨？\n` +
          `這張單會變回「草稿」（未採購），可重新發送供應商繼續走流程；\n` +
          `先前因斷貨被取消的開團商品、顧客訂單品項、補貨申請也會一併還原，並通知會員。`,
      )
    )
      return;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: res, error: rpcErr } = await supabase.rpc("rpc_restore_stockout_po", {
        p_po_id: header.id,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      const r = (res ?? {}) as Record<string, number>;
      alert(
        `${header.po_no} 已回復為草稿。\n` +
          `還原：開團商品 ${r.campaign_items ?? 0} 項、訂單品項 ${r.order_items ?? 0} 項、` +
          `訂單 ${r.orders_restored ?? 0} 張、補貨明細 ${r.restock_lines ?? 0} 條`,
      );
      await reload();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }

  async function deletePO() {
    if (!header) return;
    if (
      !window.confirm(
        `確定要刪除 ${header.po_no}？\n刪除後無法復原；來源請購單的品項會解除連結、可重新拆單。`,
      )
    )
      return;
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc(
        "rpc_delete_purchase_order",
        {
          p_po_id: header.id,
          p_operator: userData.user?.id,
        },
      );
      if (rpcErr) throw new Error(rpcErr.message);
      router.replace("/purchase/orders");
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    }
  }
  const totalReceived = items.reduce((s, r) => s + r.qty_received, 0);
  const totalOrdered = items.reduce((s, r) => s + r.qty_ordered, 0);
  const recvPct = totalOrdered > 0 ? (totalReceived / totalOrdered) * 100 : 0;
  const stockoutCount = items.filter((r) => r.stockout_at).length;

  if (!id) {
    return (
      <div className="p-6 text-sm text-zinc-500">
        缺少 id 參數。請從 <Link href="/purchase/orders" className="text-blue-600 underline">{PO_TERM_ZH}列表</Link> 進入。
      </div>
    );
  }
  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  if (!header) return <div className="p-6 text-sm text-red-600">{error ?? `找不到${PO_TERM_ZH}`}</div>;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">
            {PO_TERM_ZH} {header.po_no}
            <span className="ml-3 inline-block rounded bg-zinc-100 px-2 py-0.5 text-xs font-normal dark:bg-zinc-800">
              {STATUS_LABEL(header.status)}
            </span>
            {header.stockout_at && (
              <span className="ml-1 inline-block rounded bg-amber-100 px-2 py-0.5 text-xs font-normal text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                ⛔ 斷貨單
              </span>
            )}
          </h1>
          <p className="text-sm text-zinc-500">
            供應商：{supplier?.name ?? "—"}
            {supplier?.code && <span className="text-zinc-400"> ({supplier.code})</span>}
            　·　訂購日 {header.order_date}　·　共 {items.length} 項
          </p>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* minmax(0,1fr) 不是 1fr：1fr 等同 minmax(auto,1fr)，auto 的最小值＝內容的 min-content，
          右欄會被寬表撐開 → 橫向捲動跑到整頁去，表格自己的 overflow-x-auto 永遠不會生效。
          同 layout.tsx:484 <main> 那個 min-w-0 在解的問題，只是頁面這一層的 grid 沒跟上。 */}
      <div className="grid gap-4 md:grid-cols-[280px_minmax(0,1fr)]">
        <aside className="flex flex-col gap-4">
          {/* 摘要 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">摘要</h3>
            <dl className="space-y-2 text-sm">
              <Row label="品項數">{items.length}</Row>
              {stockoutCount > 0 && (
                <Row label="斷貨品項">
                  <span className="text-amber-600 dark:text-amber-400">{stockoutCount}</span>
                </Row>
              )}
              <Row label="訂購總量">{totalOrdered}</Row>
              <Row label="已收貨量">{totalReceived}</Row>
              <Row label="到貨進度">{recvPct.toFixed(0)}%</Row>
              <div className="my-2 border-t border-zinc-200 dark:border-zinc-700" />
              <Row label="總計">
                <span className="text-lg font-semibold text-blue-600 dark:text-blue-400">
                  ${totals.subtotal.toFixed(0)}
                </span>
              </Row>
            </dl>
          </section>

          {/* 動作 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">動作</h3>
            <div className="flex flex-col gap-2">
              {canSend && (
                <SpinButton
                  onClick={() => setShowSend(true)}
                  className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500"
                >
                  📤 發送供應商
                </SpinButton>
              )}
              {header.status === "sent" && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
                  ✓ 已發送（{header.sent_channel}）
                  <br />
                  {header.sent_at && new Date(header.sent_at).toLocaleString("zh-TW")}
                </div>
              )}
              {/* 斷貨說明。⛔ 每一句都必須是程式真的會做的事 —— 這一段的逐句出處：
                  · 「還沒收過貨才會取消客人」：_stockout_po_items 只把 qty_received = 0 的品項
                    納入下游連動（20260812000000:288-294），已收到一部分的不進 v_stockout_skus。
                  · 「取消還在等的客人訂單品項」：同檔 :321-336，只動 coi.status = 'pending' 的列，
                    而且範圍限在 :297-301 撈出來的 v_campaign_ids（＝本單品項來源請購單掛的那幾團）
                    ⛔ 不可以寫成「取消所有等這項貨的客人」—— 別團的同商品訂單不會被動到。
                  · 「有綁會員的會收到通知」：同檔 :380-396，INSERT notifications 有
                    `WHERE co.member_id IS NOT NULL` —— 沒綁會員的訂單發不出去，⛔ 不可以寫成
                    「會通知客人」。
                  · 「拆成斷貨單 / 什麼時候不拆」：_split_stockout_po_items 20260812000000:131-145
                    （要 qty_received = 0 且沒掛未取消的進貨單）與 :151-152（整張全斷不拆）。
                  · 「⚖️ 配貨在收貨待辦」：wms/inbound/page.tsx:1417 的頁標題 +:2132-2145 的按鈕。
                  · 「自動標全部到貨、貨留在派貨工作台」：20260902000000 / 20260902000010 把斷貨
                    結案由 closed 改成 fully_received；fully_received 在派貨需求 view 的白名單裡
                    （20260818000030:77）。
                    ⚠️⚠️ 工作台是**雙條件**：`.eq("has_stock_left", true).eq("has_demand_left", true)`
                    （wms/picking/page.tsx:430-431；草稿預填 lib/pickingDraftView.ts:406-407 /
                     1042-1043 / 1162-1163 也是兩條都要）。
                    ⛔ 不可以寫成「貨就會回到派貨工作台」—— 需求歸零（客人取消、已從別處出貨、
                     補貨帶囤貨）時 has_demand_left = false，那批貨留在總倉當庫存、工作台看不到。
                     這一句的但書是 2026-09-02 阿審 P1 抓出來的，⛔ 不要拿掉。
                    ⚠️ 這一句要等那兩支 migration 上了正式庫才成立。 */}
              {canStockout && (
                <p className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs leading-relaxed text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800/60 dark:text-zinc-400">
                  ⛔ <strong>斷貨 ＝ 這個商品廠商完全給不了</strong>，請在右側明細列逐品項標記。
                  <br />
                  ・這項<strong>還沒收過貨</strong>：按下去會把<strong>這張單要供貨的那幾團裡、還在等這一項的客人訂單品項全部取消</strong>
                  （有綁會員的會收到系統通知），並把它拆到一張「斷貨單」
                  （整張單都斷貨、或這一列還掛著沒確認的進貨單時就不拆）。
                  <br />
                  ・這項<strong>已經收到一部分</strong>：按下去只是停止等剩下的量，不會動到客人的訂單。
                  <br />
                  ⚠️ <strong>只是這次少送幾件，請不要按斷貨</strong>——照實際收到的數量收貨就好，
                  不夠分的時候到「收貨待辦」用 ⚖️ 配貨 決定先給誰。
                  <br />
                  其餘品項照常收貨；全部收滿後本單自動標成「全部到貨」。
                  已收到、還沒派出的貨<strong>（仍有客人或補貨需求在等的部分）</strong>
                  會出現在派貨工作台；已經沒有人在等的，就留在總倉當庫存。
                </p>
              )}
              {canRestore && (
                <SpinButton
                  onClick={restorePO}
                  className="rounded-md bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-500"
                >
                  ↩ 回復斷貨（變回草稿）
                </SpinButton>
              )}
              {canDelete && (
                <SpinButton
                  onClick={deletePO}
                  className="rounded-md border border-red-400 bg-red-50 px-3 py-2 text-sm font-medium text-red-700 hover:bg-red-100 dark:border-red-700 dark:bg-red-950 dark:text-red-300 dark:hover:bg-red-900"
                >
                  🗑 刪除{PO_TERM_ZH}
                </SpinButton>
              )}
              {header.stockout_at && (
                <div className="rounded-md border border-amber-200 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
                  ⛔ 已斷貨：{new Date(header.stockout_at).toLocaleString("zh-TW")}
                  {header.stockout_reason && (
                    <>
                      <br />
                      原因：{header.stockout_reason}
                    </>
                  )}
                  {sourcePO && (
                    <>
                      <br />
                      斷貨拆自{" "}
                      <Link
                        href={`/purchase/orders/edit?id=${sourcePO.id}`}
                        className="font-mono underline"
                      >
                        {sourcePO.po_no}
                      </Link>
                    </>
                  )}
                </div>
              )}
              {header.stockout_restored_at && !header.stockout_at && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
                  ↩ 斷貨已回復：{new Date(header.stockout_restored_at).toLocaleString("zh-TW")}
                  <br />
                  可重新發送供應商，接著走到貨 / 收貨流程。
                </div>
              )}
              {splitPOs.length > 0 && (
                <div className="rounded-md border border-amber-200 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
                  ⛔ 斷貨品項已拆出：
                  {splitPOs.map((p) => (
                    <span key={p.id} className="ml-1">
                      <Link
                        href={`/purchase/orders/edit?id=${p.id}`}
                        className="font-mono underline"
                      >
                        {p.po_no}
                      </Link>
                      <span className="text-amber-600 dark:text-amber-400">
                        （{STATUS_LABEL(p.status)}）
                      </span>
                    </span>
                  ))}
                </div>
              )}
              {!editable && !canSend && !canStockout && !canDelete && !canRestore && (
                <p className="text-xs text-zinc-500">此{PO_TERM_ZH}已 {STATUS_LABEL(header.status)}。</p>
              )}
            </div>
          </section>

          {/* 供應商資訊 */}
          {supplier && (
            <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
              <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">供應商</h3>
              <dl className="space-y-1 text-xs">
                <Row label="名稱">{supplier.name}</Row>
                {supplier.line_contact && <Row label="LINE">{supplier.line_contact}</Row>}
                {supplier.email && <Row label="Email">{supplier.email}</Row>}
                {supplier.phone && <Row label="電話">{supplier.phone}</Row>}
                <Row label="偏好通路">{supplier.preferred_po_channel ?? "line"}</Row>
              </dl>
            </section>
          )}
        </aside>

        {/* 右側：line items 表格 */}
        <div className="flex flex-col rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
            <h3 className="text-sm font-semibold">📦 訂單明細</h3>
            {recvRows.length > 0 && (
              /* 觸控目標 ≥ 44px：樓下是用 iPad 單手點的。
                 touch-manipulation = touch-action: manipulation，關掉這幾顆鈕上的
                 double-tap-to-zoom：本頁 viewport 可縮放，iOS 會先等 ~350ms 看有沒有第二下才送 click，
                 那個延遲正是讓人以為沒按到、再多戳一下（然後畫面被放大）的原因。 */
              <div className="flex flex-wrap items-center gap-2">
                {recvPending.length > 0 && (
                  <span className="rounded bg-amber-100 px-2 py-1 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                    {recvPending.length} 格已改、未儲存
                  </span>
                )}
                {recvStaleRows.length > 0 && (
                  /* 過期的格子存不進去，先讓人在按「全部儲存」之前就看到 */
                  <span className="rounded bg-red-100 px-2 py-1 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-300">
                    {recvStaleRows.length} 格已被別人改過
                  </span>
                )}
                <button
                  type="button"
                  onClick={fillAllReceived}
                  disabled={recvBusy}
                  className="min-h-[44px] touch-manipulation rounded-md border border-blue-300 bg-white px-3 text-sm font-medium text-blue-700 hover:bg-blue-50 disabled:opacity-40 dark:border-blue-700 dark:bg-zinc-900 dark:text-blue-300 dark:hover:bg-blue-950"
                >
                  全部到齊
                </button>
                <button
                  type="button"
                  onClick={saveAllReceived}
                  disabled={recvBusy || recvPending.length === 0}
                  className="min-h-[44px] touch-manipulation rounded-md bg-emerald-600 px-3 text-sm font-semibold text-white hover:bg-emerald-500 disabled:opacity-40"
                >
                  {recvBatchSaving ? "儲存中…" : `全部儲存${recvPending.length > 0 ? `（${recvPending.length}）` : ""}`}
                </button>
              </div>
            )}
          </div>
          {recvBatchResult && (
            <div
              className={`border-b px-4 py-2 text-sm ${
                recvBatchResult.failed.length > 0 || !recvBatchResult.reloadOk
                  ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300"
                  : "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300"
              }`}
            >
              <div className="font-medium">
                成功 {recvBatchResult.ok} 筆
                {recvBatchResult.failed.length > 0 && `、失敗 ${recvBatchResult.failed.length} 筆`}
              </div>
              {!recvBatchResult.reloadOk && (
                /* 存進去了但畫面沒能重抓：這時桌面上的數字不代表資料庫，要講明白，
                   不然老闆會以為那批貨沒進到、又存一次。 */
                <p className="mt-1">
                  ⚠️ 上面成功的 {recvBatchResult.ok} 筆<strong>確實已經入庫</strong>，但重新載入失敗、
                  畫面可能還顯示舊數字（那幾格會繼續標成未儲存）。請手動重新整理這一頁確認。
                </p>
              )}
              {recvBatchResult.failed.length > 0 && (
                <>
                  <ul className="mt-1 list-disc space-y-0.5 pl-5">
                    {recvBatchResult.failed.map((f, i) => (
                      <li key={`${f.label}:${i}`}>
                        {f.label}：{f.msg}
                      </li>
                    ))}
                  </ul>
                  <p className="mt-1 text-xs">
                    成功那幾筆已經入庫了、失敗的沒有（每筆各自獨立，不會整批退回）。修正後再按一次「全部儲存」。
                  </p>
                </>
              )}
            </div>
          )}
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th>#</Th>
                  <Th>品名</Th>
                  <Th>單位</Th>
                  <Th className="text-right">訂購</Th>
                  <Th className="text-right">已收</Th>
                  <Th className="text-right">已退</Th>
                  <Th className="text-right">已出</Th>
                  <Th className="text-right">成本</Th>
                  <Th className="text-right">小計</Th>
                  <Th className="text-center">確定短少</Th>
                  <Th className="text-center">斷貨</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {items.length === 0 ? (
                  <tr>
                    <td colSpan={11} className="p-6 text-center text-zinc-500">無品項</td>
                  </tr>
                ) : (
                  items.map((r, idx) => (
                    <tr
                      key={r.id}
                      className={
                        r.stockout_at
                          ? "bg-amber-50/50 hover:bg-amber-50 dark:bg-amber-950/20 dark:hover:bg-amber-950/40"
                          : "hover:bg-zinc-50 dark:hover:bg-zinc-900"
                      }
                    >
                      <Td className="text-zinc-500">{idx + 1}</Td>
                      <Td>
                        <div>{r.product_name}{r.variant_name ? `-${r.variant_name}` : ""}</div>
                        <div className="font-mono text-xs text-zinc-500">{r.sku_code}</div>
                      </Td>
                      <Td className="text-zinc-500">{r.unit_uom ?? "—"}</Td>
                      <Td className="text-right">{r.qty_ordered}</Td>
                      <Td className="text-right">
                        {recvEditable && !r.stockout_at ? (
                          <ReceivedCell
                            item={r}
                            value={recvValue(r)}
                            saving={recvSavingId === r.id}
                            disabled={recvBusy}
                            err={recvErrs[r.id]}
                            staleBase={recvStaleBase(r)}
                            onChange={(v) => setRecvEdit(r, v)}
                            onFill={() => fillReceived(r)}
                            onSave={() => saveReceived(r)}
                            onDiscard={() => discardRecvEdit(r)}
                          />
                        ) : (
                          <span className="text-emerald-600 dark:text-emerald-400">
                            {r.qty_received > 0 ? r.qty_received : "—"}
                          </span>
                        )}
                      </Td>
                      <Td className="text-right text-zinc-500">
                        {r.qty_returned > 0 ? r.qty_returned : "—"}
                      </Td>
                      <Td className="text-right text-zinc-500">
                        {r.qty_shipped > 0 ? r.qty_shipped : "—"}
                      </Td>
                      <Td className="text-right font-medium text-amber-600 dark:text-amber-400">${r.unit_cost.toFixed(0)}</Td>
                      <Td className="text-right font-mono">${(r.qty_ordered * r.unit_cost).toFixed(0)}</Td>
                      {/* 確定短少（20260902030000）：只少幾件用這欄，整項供不了才按右邊的「斷貨」。
                          顯示條件與斷貨鈕一致（canStockout ＝ 已發送 / 部分到貨），
                          再加「還有未到量」—— 全到了就沒有短少可言（RPC 也會擋）。 */}
                      <Td className="text-center">
                        {/* ⚠️ 顯示條件分兩種（阿審 P1-4 的畫面那一半）：
                            ①「能不能**填**新的短少」＝ 未斷貨 × 單子還在收 × 還有未到量
                            ②「能不能**清掉舊的**」＝ 只要這一列真的掛著標記就一定要能按
                            ⛔ 兩個不可以合成一個條件：貨後來補齊了（已收 ≥ 訂購）之後
                              鈕會消失，掛著的標記就永遠拿不掉，客人卡在待補貨沒人救得了。
                            （後端 RPC 也已經放行清除路徑，兩層要一致，否則又是
                              「DB 允許、畫面按不到」那種落差。）
                            🔴 第三輪修正：`!r.stockout_at` 原本掛在**整個**條件外面，
                              於是這個品項一旦被按了（跟本功能無關的）「斷貨」鈕，
                              連清除入口都一起消失 —— 跟上面那個病一模一樣，只是換一個觸發方式。
                              ⇒ 斷貨只擋「填新的」，不擋「清舊的」。
                            ⭐ 為什麼給**真按鈕**而不是「唯讀說明講去哪清」：
                              全站沒有第二個地方可以清這個標記，說明只能寫成
                              「去別的地方清」而那個地方不存在 ＝ 又一句畫面上的假話。 */}
                        {(!r.stockout_at && canStockout && r.qty_received < r.qty_ordered) ||
                        !!r.confirmed_shortfall ? (
                          <div className="flex flex-col items-center gap-1">
                            <SpinButton
                              onClick={() => setConfirmedShortfall(r)}
                              className={
                                "min-h-[44px] touch-manipulation rounded-md border px-2 text-sm font-medium " +
                                (r.confirmed_shortfall
                                  ? "border-rose-400 bg-rose-50 text-rose-700 hover:bg-rose-100 dark:border-rose-700 dark:bg-rose-950 dark:text-rose-300 dark:hover:bg-rose-900"
                                  : "border-zinc-300 text-zinc-600 hover:bg-zinc-100 dark:border-zinc-600 dark:text-zinc-300 dark:hover:bg-zinc-800")
                              }
                              title={
                                r.confirmed_shortfall
                                  ? `廠商確定不會到 ${r.confirmed_shortfall}${r.unit_uom ?? "件"}` +
                                    (r.confirmed_shortfall_at
                                      ? `（${new Date(r.confirmed_shortfall_at).toLocaleString("zh-TW")}）`
                                      : "") +
                                    "\n點一下可改數字或清除"
                                  : "廠商說「有幾件確定不會到」時填這裡：會把最晚下單的那幾件標成待補貨。不會通知客人。"
                              }
                            >
                              {r.confirmed_shortfall ? `⚠ 短少 ${r.confirmed_shortfall}` : "＋ 標短少"}
                            </SpinButton>
                            {r.confirmed_shortfall ? (
                              /* ⛔ 鈕名不要改回「取消並通知」。2026-09-04 老闆看畫面時的原話：
                                   「你的取消 我根本不知道取消什麼」
                                 —— 舊名只講「動作」不講「對什麼東西」，而這一頁同一列右邊
                                 就是另一顆「⛔ 斷貨」，兩顆都在講取消，操作的人分不出差別。
                                 新名字「確定斷貨並通知」講的是結果，且與系統對客人發出的
                                 「商品斷貨通知」及品項標記「斷貨取消」同一套語彙
                                 （兩句都在本檔 cancelShortfallBackorders 的確認框裡，
                                  ⛔ 這裡刻意不寫行號 —— 行號會被後續改動推移變成假資訊）。
                                 ⚠️ 這顆與右欄「⛔ 斷貨」是兩件事，改字時務必連 title 一起看：
                                   這顆 ＝ 只對這筆短少牽連到的那幾位客人（不可復原）
                                   ⛔ 斷貨 ＝ 整個品項廠商完全給不了（會拆斷貨單、可一鍵回復） */
                              <SpinButton
                                onClick={() => cancelShortfallBackorders(r)}
                                className="min-h-[44px] touch-manipulation rounded-md border border-rose-300 px-2 text-xs text-rose-700 hover:bg-rose-50 dark:border-rose-800 dark:text-rose-400 dark:hover:bg-rose-950"
                                title="對因為這筆短少而待補貨的客人品項確定斷貨（訂單品項會取消），並通知綁了會員的那幾位。⛔ 只影響這幾筆；整個品項廠商都給不了，請按右邊的「⛔ 斷貨」。"
                              >
                                ✕ 確定斷貨並通知
                              </SpinButton>
                            ) : null}
                          </div>
                        ) : (
                          <span className="text-zinc-400">—</span>
                        )}
                      </Td>
                      <Td className="text-center">
                        {r.stockout_at ? (
                          <span
                            className="inline-flex rounded bg-amber-100 px-1.5 py-0.5 text-[11px] text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                            title={
                              `斷貨於 ${new Date(r.stockout_at).toLocaleString("zh-TW")}` +
                              (r.stockout_reason ? `\n原因：${r.stockout_reason}` : "")
                            }
                          >
                            ⛔ 斷貨
                          </span>
                        ) : canStockout && r.qty_received < r.qty_ordered ? (
                          /* 同一列裡的觸控目標要一致：已收量那三顆是 44px，這顆也跟上 */
                          <SpinButton
                            onClick={() => stockoutItem(r)}
                            className="min-h-[44px] touch-manipulation rounded-md border border-amber-400 bg-amber-50 px-2 text-sm font-medium text-amber-700 hover:bg-amber-100 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-300 dark:hover:bg-amber-900"
                          >
                            ⛔ 斷貨
                          </SpinButton>
                        ) : (
                          <span className="text-zinc-400">—</span>
                        )}
                      </Td>
                    </tr>
                  ))
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <SendPOModal
        open={showSend}
        onClose={() => setShowSend(false)}
        poId={id}
        poNo={header.po_no}
        supplier={supplier}
        items={items.map((r) => ({
          sku_code: r.sku_code,
          product_name: r.product_name + (r.variant_name ? `-${r.variant_name}` : ""),
          qty_ordered: r.qty_ordered,
          unit_cost: r.unit_cost,
          unit_uom: r.unit_uom,
        }))}
        total={totals.subtotal}
        onSent={reload}
      />
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}
function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="font-mono">{children}</dd>
    </div>
  );
}

/**
 * 已收量的邊界與狀態。
 * 下限 = 已退 + 已出（已離開庫存的量不能再被「未收」回去）；上限 = 訂購量。
 * 父層（全部到齊／全部儲存）和每一格共用這一份，兩邊才不會算出不一樣的 dirty / invalid。
 */
function recvState(item: Item, value: string) {
  const floor = item.qty_returned + item.qty_shipped;
  const max = item.qty_ordered;
  const num = Number(value);
  return {
    floor,
    max,
    num,
    dirty: num !== item.qty_received,
    invalid: value.trim() === "" || Number.isNaN(num) || num < floor || num > max,
  };
}

/**
 * 已收量行內編輯（純呈現，數值狀態在父層 —— 「全部到齊／全部儲存」要跨格操作）。
 * 儲存呼叫 rpc_adjust_po_item_received（連動庫存：補收入庫 / 改少出庫修正）。
 *
 * 原本這裡用 key={`${id}:${qty_received}`} 重掛元件來清乾淨；改用父層 state 之後，
 * 「乾淨」是靠 value = edits[id] ?? qty_received 這個式子自然成立的：
 * 儲存成功 reload 後 qty_received 追上輸入值 → dirty 立刻變 false（儲存鈕消失、黃底退掉），
 * 不需要、也不會依賴重掛。輸入到一半被 reload 也不會被洗掉：reload 只動 items、不碰 edits。
 *
 * stale = 開始編輯後，這一列的 qty_received 已經被別人改掉了。此時擋住儲存，
 * 只給「改用最新值」（丟掉自己的輸入、退回 DB 值）——RPC 是絕對值覆蓋，
 * 讓他基於舊認知送出去會直接蓋掉別人剛存的數字。
 */
function ReceivedCell({
  item,
  value,
  saving,
  disabled,
  err,
  staleBase,
  onChange,
  onFill,
  onSave,
  onDiscard,
}: {
  item: Item;
  value: string;
  saving: boolean;
  disabled: boolean;
  err?: string;
  /** 有值＝這一格過期了；值本身是開始編輯時看到的已收量 */
  staleBase?: number;
  onChange: (v: string) => void;
  onFill: () => void;
  onSave: () => void;
  onDiscard: () => void;
}) {
  const { floor, max, num, dirty, invalid } = recvState(item, value);
  const stale = staleBase !== undefined;

  return (
    <div className="flex flex-col items-end gap-0.5">
      <div className="flex items-center justify-end gap-1">
        {/* text-base = 16px：iOS 對字級 < 16px 的輸入框會在 focus 時自動放大整頁，
            樓下用 iPad 點這一格畫面就會亂跳。寬度同步放到 w-20 才容得下 16px 的四位數。 */}
        <input
          type="number"
          inputMode="numeric"
          value={value}
          min={floor}
          max={max}
          disabled={disabled || stale}
          onChange={(e) => onChange(e.target.value)}
          className={`w-20 rounded border px-1 py-0.5 text-right text-base tabular-nums ${
            stale || (invalid && dirty)
              ? "border-red-400 bg-white dark:border-red-700 dark:bg-zinc-800"
              : dirty
                ? // 改過、還沒存：黃底黃框，一眼看得出哪幾格是待儲存的
                  "border-amber-400 bg-amber-50 dark:border-amber-600 dark:bg-amber-950/40"
                : "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-800"
          }`}
          aria-label={`已收量（下限 ${floor}、上限 ${max}）`}
        />
        {/* 觸控目標 ≥ 44px：樓下是用 iPad 單手點的。touch-manipulation 見上方明細標題列的說明。
            已經等於訂購量就沒事可做 → 直接 disabled，不做「按了沒反應」的鈕。
            過期時整格凍結（含輸入框與這兩顆鈕），只留「改用最新值」一條路：
            再讓他改字只會讓他基於舊認知送出，而 RPC 是絕對值覆蓋。 */}
        <button
          type="button"
          onClick={onFill}
          disabled={disabled || stale || num === max}
          title={`帶入訂購量 ${max}`}
          aria-label={`帶入訂購量 ${max}`}
          className="min-h-[44px] min-w-[44px] shrink-0 touch-manipulation rounded-md border border-blue-300 bg-white px-2 text-sm font-medium text-blue-700 hover:bg-blue-50 disabled:opacity-40 dark:border-blue-700 dark:bg-zinc-900 dark:text-blue-300 dark:hover:bg-blue-950"
        >
          全到
        </button>
        {stale ? (
          <button
            type="button"
            onClick={onDiscard}
            disabled={disabled}
            title={`丟掉你輸入的 ${value}，改用最新的 ${item.qty_received}`}
            className="min-h-[44px] shrink-0 touch-manipulation rounded-md border border-red-400 bg-white px-2 text-sm font-medium text-red-700 hover:bg-red-50 disabled:opacity-40 dark:border-red-700 dark:bg-zinc-900 dark:text-red-300 dark:hover:bg-red-950"
          >
            改用最新值
          </button>
        ) : (
          dirty && (
            <button
              type="button"
              onClick={onSave}
              disabled={disabled || invalid}
              className="min-h-[44px] min-w-[44px] shrink-0 touch-manipulation rounded-md bg-emerald-600 px-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-40"
            >
              {saving ? "…" : "儲存"}
            </button>
          )
        )}
      </div>
      {stale && (
        <span className="max-w-[13rem] text-right text-[11px] leading-tight text-red-600 dark:text-red-400">
          ⚠️ 這一列已被別人改成 {item.qty_received}（你是看著 {staleBase} 輸入的）。
          已收量是覆蓋、不是累加 —— 請按「改用最新值」再重打。
        </span>
      )}
      {err && !stale && (
        <span className="max-w-[10rem] text-right text-[11px] leading-tight text-red-500">{err}</span>
      )}
    </div>
  );
}
