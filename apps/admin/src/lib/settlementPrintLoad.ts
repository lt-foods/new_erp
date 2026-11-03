// 月結對帳單列印：讀資料與「能不能印」的判斷。單張頁（finance/receivables/print）與
// 一次列印頁（transfers/settlement/print-batch）共用，兩頁擋法才會是同一套。單獨測試：
//   node --test apps/admin/src/lib/settlementPrintLoad.test.mjs
//
// 一次列印的讀法（正式庫 2026-09-24 才因記憶體爆掉重開過，⛔ 不要改成逐家照單張的讀法重複查，16 家約 140 次）：
//   - 明細：每家用 fetchAllRows 分頁讀完，最多同時讀 PRINT_BATCH_ITEM_CONCURRENCY 家，其餘排隊。
//   - 月結表頭、店名、調整、應收單：一次查詢（或 fetchInBatches 分批）讀完再分回各家；公司名只查一次。
//   - 品名：只查「逐筆印出」那些行的 sku（一天一行的 HQ 進貨／退貨沖回紙上不印品名），跨店去重後分批查。
//   - ⛔ 任何查詢失敗都不能當成空資料（調整不能當成 0：正負剛好互抵時金額核對擋不住，紙看起來正常、調整表卻整段消失）。
import type { SupabaseClient } from "@supabase/supabase-js";
import { fetchAllRows } from "./fetchAllRows";
import {
  buildSettlementPrintRows,
  fetchInBatches,
  statementTotals,
  sumMoney,
  summarizeSettlementItems,
  type StatementTotals,
} from "./settlementPrintRows";

export type Settlement = {
  id: number;
  settlement_month: string;
  store_id: number;
  payable_amount: number;
  cost_amount: number;
  branch_amount: number;
  transfer_count: number;
  item_count: number;
  status: string;
  generated_receivable_id: number | null;
};

export type SettlementItem = {
  id: number;
  transfer_id: number;
  sku_id: number;
  qty_received: number;
  unit_cost: number | null;
  line_amount: number | null;
  unit_branch_price: number;
  branch_amount: number;
  received_at: string;
  /** 認得的見 SettlementEntryType；以後新增的類型照樣印（類型欄退回原始代號） */
  entry_type: string;
  description: string | null;
};

export type Adjustment = {
  id: number;
  amount: number;
  reason: string;
  created_at: string;
};

export type Store = { id: number; code: string; name: string };
export type Sku = { id: number; sku_code: string | null; product_name: string | null; variant_name: string | null };
export type Receivable = { id: number; receivable_no: string; due_date: string; status: string };

/** 印一張對帳單要的全部資料 */
export type StatementData = {
  settlement: Settlement;
  store: Store;
  items: SettlementItem[];
  adjustments: Adjustment[];
  skus: Map<number, Sku>;
  tenantName: string;
  receivable: Receivable | null;
};

// .in("id", …) 一批最多幾個 id：太多會撞網址長度上限（PostgREST 走 GET）
const IN_BATCH = 200;

const SETTLEMENT_SELECT =
  "id, settlement_month, store_id, payable_amount, cost_amount, branch_amount, transfer_count, item_count, status, generated_receivable_id";

// 明細一張月結常破千列（HQ 派車每張單的每個品項一列），PostgREST 單次最多回 1000 列、
// 超過會靜默截斷 → 一定要走 fetchAllRows 分頁讀完。排序加 id 給分頁一個穩定的順序。
function fetchSettlementItems(sb: SupabaseClient, settlementId: number): Promise<SettlementItem[]> {
  return fetchAllRows<SettlementItem>(() =>
    sb.from("store_monthly_settlement_items")
      .select("id, transfer_id, sku_id, qty_received, unit_cost, line_amount, unit_branch_price, branch_amount, received_at, entry_type, description")
      .eq("settlement_id", settlementId)
      .order("entry_type")
      .order("received_at")
      .order("id"),
  );
}

// ── 能不能印（兩頁共用）──

/** 紙上三個整數與金額自我核對。金額一律用原始小數精確加總，只在顯示時取整（見 lib/settlementPrintRows.ts） */
export function statementPaper(
  settlement: Pick<Settlement, "payable_amount">,
  items: readonly SettlementItem[],
  adjustments: readonly Pick<Adjustment, "amount">[],
): StatementTotals {
  return statementTotals(
    summarizeSettlementItems(items).branchAmount,
    sumMoney(adjustments.map((a) => a.amount)),
    settlement.payable_amount,
  );
}

/**
 * 不給印的原因（依序）：金額核對沒過 → 單號／品名載入失敗 → 單號／品名還在載入。
 * 核對沒過（明細沒讀完整、月結表頭過期）就擋下列印，不印出等式對不上的紙。
 * namesFailed：null＝還在載；[]＝全部載到；有值＝哪幾樣載入失敗。
 */
export function statementPrintBlockReason(
  paper: Pick<StatementTotals, "ok">,
  namesFailed: readonly string[] | null,
): string | undefined {
  if (!paper.ok) return "明細合計與系統應付總倉不一致，請先重算月結";
  if ((namesFailed?.length ?? 0) > 0) return "部分單號／品名載入失敗，請重新整理後再印";
  if (namesFailed === null) return "單號／品名載入中…";
  return undefined;
}

// ── 單張頁的讀法（查詢與單張頁原本的內容相同）──

/** 第一段：畫面主體要的資料。分店、金額調整查失敗 → 丟錯、整頁錯誤（同明細失敗） */
export async function loadSingleStatementCore(sb: SupabaseClient, settlementId: number) {
  const { data: s, error: e1 } = await sb
    .from("store_monthly_settlements")
    .select(SETTLEMENT_SELECT)
    .eq("id", settlementId)
    .maybeSingle();
  if (e1) throw new Error(e1.message);
  if (!s) throw new Error("找不到此月結算");
  const settlement = s as Settlement;

  const [storeRes, items, tenantRes, adjRes] = await Promise.all([
    sb.from("stores").select("id, code, name").eq("id", settlement.store_id).maybeSingle(),
    fetchSettlementItems(sb, settlementId),
    sb.from("tenants").select("name").limit(1),
    sb.from("store_settlement_adjustments")
      .select("id, amount, reason, created_at")
      .eq("store_id", settlement.store_id)
      .eq("settlement_month", settlement.settlement_month)
      .eq("status", "active")
      .order("created_at"),
  ]);
  // 調整不能當成 0：正負剛好互抵時金額核對擋不住，紙看起來正常、調整表卻整段消失。
  if (storeRes.error) throw new Error(`分店資料載入失敗：${storeRes.error.message}`);
  if (!storeRes.data) throw new Error("找不到此月結算的分店");
  if (adjRes.error) throw new Error(`金額調整載入失敗：${adjRes.error.message}`);

  const tenantFailed = !!tenantRes.error;
  const tenantName = tenantFailed ? "" : (tenantRes.data as { name: string }[] | null)?.[0]?.name ?? "";
  return {
    settlement,
    store: storeRes.data as Store,
    items,
    adjustments: (adjRes.data ?? []) as Adjustment[],
    tenantName,
    tenantFailed,
  };
}

/**
 * 第二段：單號／品名類（商品編號／品名、應收單號）。查失敗不影響金額，但紙上會變「—」，
 * 所以不整頁擋，改成黃字提醒＋停用列印（載入完成前也不給印）。
 * 紙上不印調撥單號（2026-10-07 老闆指示整欄刪掉），所以不查 transfers —— 免得一個用不到的查詢失敗還擋列印。
 */
export async function loadSingleStatementNames(
  sb: SupabaseClient,
  items: readonly SettlementItem[],
  settlement: Pick<Settlement, "generated_receivable_id">,
): Promise<{ skus: Map<number, Sku> | null; receivable: Receivable | null; failed: string[] }> {
  const failed: string[] = [];
  const skuIds = Array.from(new Set(items.map((i) => i.sku_id)));
  const [skRes] = await Promise.allSettled([
    fetchInBatches<Sku>(skuIds, IN_BATCH, (ids) =>
      sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", ids),
    ),
  ]);
  const skus = skRes.status === "fulfilled" ? new Map(skRes.value.map((x) => [x.id, x])) : null;
  if (!skus) failed.push("商品編號／品名");

  // 如果有對應 store_receivable 也載入
  let receivable: Receivable | null = null;
  if (settlement.generated_receivable_id) {
    const { data: r, error: rErr } = await sb
      .from("store_receivables")
      .select("id, receivable_no, due_date, status")
      .eq("id", settlement.generated_receivable_id)
      .maybeSingle();
    if (rErr) failed.push("應收單號");
    else if (r) receivable = r as Receivable;
  }
  return { skus, receivable, failed };
}

// ── 列表頁「一次列印」的勾選規則 ──

export type PrintSelectRow = { id: number; status: string; settlement_month: string | null };

/**
 * 這一列能不能勾來印；能 → null，不能 → 白話原因（給勾選框的滑鼠提示）。
 * monthFilter：畫面「月份篩選」的值（沒選是 ""）。沒選月份不給勾，避免不同月份混著印。
 * loadBlock：這個月份沒全部載入的原因（bulkSendLoadBlockReason），沒漏是 null。
 * 草稿可以手動勾（全選不選它），已取消不給勾。
 */
export function printSelectBlockReason(row: PrintSelectRow, monthFilter: string, loadBlock: string | null): string | null {
  if (!monthFilter) return "先選月份";
  if (loadBlock) return loadBlock;
  // 換篩選月份、列表還沒重新載入的那一瞬間，畫面上會是上一個月份的列
  if ((row.settlement_month ?? "").slice(0, 7) !== monthFilter) return "不是目前篩選的月份";
  if (row.status === "cancelled") return "已取消的月結不能印";
  return null;
}

/** 列表上能勾來印的列（維持列表順序） */
export function printableRows<T extends PrintSelectRow>(rows: readonly T[], monthFilter: string, loadBlock: string | null): T[] {
  return rows.filter((r) => printSelectBlockReason(r, monthFilter, loadBlock) === null);
}

/** 按「全選」要勾哪些：能勾的扣掉草稿（金額之後可能會變，要印草稿得自己勾） */
export function printSelectAllIds(rows: readonly PrintSelectRow[], monthFilter: string, loadBlock: string | null): number[] {
  return printableRows(rows, monthFilter, loadBlock).filter((r) => r.status !== "draft").map((r) => r.id);
}

/** 真正要印的：目前列表與勾選的交集，照列表順序（勾選集合裡可能還留著已經不在列表上的單） */
export function printTargetIds(
  rows: readonly PrintSelectRow[],
  selected: ReadonlySet<number>,
  monthFilter: string,
  loadBlock: string | null,
): number[] {
  return printableRows(rows, monthFilter, loadBlock).filter((r) => selected.has(r.id)).map((r) => r.id);
}

/** 一次列印頁的網址（不帶版本：⛔ 網址參數不能開內部版） */
export function printBatchHref(ids: readonly number[]): string {
  return `/transfers/settlement/print-batch?ids=${ids.join(",")}`;
}

/**
 * 解析網址的 ids：非正整數（連帶整串）一律 invalid，不默默略過 ——
 * 略過的話少印一家也不會有人發現。重複的只留第一個，順序照網址（＝列表順序）。
 */
export function parsePrintBatchIds(raw: string | null): { kind: "empty" | "invalid" } | { kind: "ok"; ids: number[] } {
  if (raw === null || raw.trim() === "") return { kind: "empty" };
  const parts = raw.split(",").map((p) => p.trim());
  if (parts.some((p) => !/^[1-9]\d{0,14}$/.test(p))) return { kind: "invalid" };
  return { kind: "ok", ids: Array.from(new Set(parts.map(Number))) };
}

// ── 一次列印頁的讀法 ──

/** 明細最多同時讀幾家 */
export const PRINT_BATCH_ITEM_CONCURRENCY = 3;

/** 最多同時跑 limit 個 worker，其餘排隊；isCancelled 為 true 後不再開始新的（已開始的讓它跑完） */
export async function runWithLimit<T>(
  items: readonly T[],
  limit: number,
  worker: (item: T, index: number) => Promise<void>,
  isCancelled: () => boolean = () => false,
): Promise<void> {
  if (!(limit > 0)) throw new Error(`limit 必須大於 0（收到 ${limit}）`);
  let next = 0;
  const run = async () => {
    while (next < items.length && !isCancelled()) {
      const i = next++;
      await worker(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, run));
}

type AdjustmentRow = Adjustment & { store_id: number; settlement_month: string };

/** 調整按「店＋月份」對回各家（同一家店可能同時印兩個月份，不能只看店）；順序沿用查詢結果（created_at） */
export function adjustmentsForSettlement(
  rows: readonly AdjustmentRow[],
  settlement: Pick<Settlement, "store_id" | "settlement_month">,
): Adjustment[] {
  const month = settlement.settlement_month.slice(0, 10);
  return rows
    .filter((a) => a.store_id === settlement.store_id && String(a.settlement_month).slice(0, 10) === month)
    .map((a) => ({ id: a.id, amount: a.amount, reason: a.reason, created_at: a.created_at }));
}

/** 要查品名的 sku：只有逐筆印出的行紙上才有品名（判斷用列印頁實際排版的那一支，不另外寫一套），跨店去重 */
export function printedLineSkuIds(itemLists: readonly (readonly SettlementItem[])[]): number[] {
  const ids = new Set<number>();
  for (const items of itemLists) {
    for (const row of buildSettlementPrintRows(items)) {
      if (row.kind === "line") ids.add(row.item.sku_id);
    }
  }
  return Array.from(ids);
}

function errorMessage(e: unknown): string {
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}

/** 一次列印頁的一家：data、error 都是 null ＝ 還在讀；namesFailed 意思同 statementPrintBlockReason */
export type BatchSheet = {
  id: number;
  /** 紅字、「這次沒印」清單上講是哪一家（店名查不到時退回單號） */
  label: string;
  status: string | null;
  data: StatementData | null;
  error: string | null;
  namesFailed: string[] | null;
};

/**
 * 讀一批對帳單。onChange 每有一家讀完就收到一份新的陣列（沒變的家沿用同一個物件）。
 * 月結表頭本身查失敗 → 丟錯（不知道有哪幾家）；其他失敗都記在該家身上，不影響別家。
 */
export async function loadBatchStatements(
  sb: SupabaseClient,
  ids: readonly number[],
  onChange: (sheets: BatchSheet[]) => void,
  isCancelled: () => boolean = () => false,
): Promise<void> {
  const settlementRows = await fetchInBatches<Settlement>(ids, IN_BATCH, (batch) =>
    sb.from("store_monthly_settlements").select(SETTLEMENT_SELECT).in("id", batch),
  );
  if (isCancelled()) return;
  const settlementById = new Map(settlementRows.map((s) => [s.id, s]));
  const settlements = ids.flatMap((id) => settlementById.get(id) ?? []);
  const storeIds = Array.from(new Set(settlements.map((s) => s.store_id)));
  const months = Array.from(new Set(settlements.map((s) => s.settlement_month)));
  const receivableIds = Array.from(
    new Set(settlements.flatMap((s) => (s.generated_receivable_id ? [s.generated_receivable_id] : []))),
  );

  const [storeRes, tenantRes, adjRes, receivableRes] = await Promise.allSettled([
    fetchInBatches<Store>(storeIds, IN_BATCH, (batch) => sb.from("stores").select("id, code, name").in("id", batch)),
    sb.from("tenants").select("name").limit(1),
    // 調整可能破千（店×月份），分批＋分頁讀完；排序加 id 給分頁一個穩定的順序
    (async () => {
      const rows: AdjustmentRow[] = [];
      for (let i = 0; i < storeIds.length; i += IN_BATCH) {
        const batch = storeIds.slice(i, i + IN_BATCH);
        rows.push(
          ...(await fetchAllRows<AdjustmentRow>(() =>
            sb.from("store_settlement_adjustments")
              .select("id, store_id, settlement_month, amount, reason, created_at")
              .in("store_id", batch)
              .in("settlement_month", months)
              .eq("status", "active")
              .order("created_at")
              .order("id"),
          )),
        );
      }
      return rows;
    })(),
    fetchInBatches<Receivable>(receivableIds, IN_BATCH, (batch) =>
      sb.from("store_receivables").select("id, receivable_no, due_date, status").in("id", batch),
    ),
  ]);
  if (isCancelled()) return;

  const stores = storeRes.status === "fulfilled" ? new Map(storeRes.value.map((s) => [s.id, s])) : null;
  const tenantFailed = tenantRes.status === "rejected" || !!tenantRes.value.error;
  const tenantName =
    tenantRes.status === "fulfilled" && !tenantRes.value.error
      ? (tenantRes.value.data as { name: string }[] | null)?.[0]?.name ?? ""
      : "";
  const receivables = receivableRes.status === "fulfilled" ? new Map(receivableRes.value.map((r) => [r.id, r])) : null;
  const emptySkus = new Map<number, Sku>();

  // 第一輪：不用讀明細就知道印不了的家先標好，省掉明細查詢
  const sheets: BatchSheet[] = ids.map((id) => {
    const s = settlementById.get(id);
    if (!s) return { id, label: `#${id}`, status: null, data: null, error: "查無此月結單", namesFailed: null };
    const store = stores?.get(s.store_id);
    const label = `${store?.name ?? `#${id}`} ${s.settlement_month.slice(0, 7)}`;
    const base = { id, label, status: s.status, data: null, namesFailed: null };
    if (s.status === "cancelled") return { ...base, error: "這張月結已取消" };
    if (storeRes.status === "rejected") return { ...base, error: `分店資料載入失敗：${errorMessage(storeRes.reason)}` };
    if (!store) return { ...base, error: "找不到此月結算的分店" };
    if (adjRes.status === "rejected") return { ...base, error: `金額調整載入失敗：${errorMessage(adjRes.reason)}` };
    return { ...base, error: null };
  });
  onChange([...sheets]);

  await runWithLimit(
    sheets.flatMap((sheet, index) => (sheet.error === null ? [{ sheet, index }] : [])),
    PRINT_BATCH_ITEM_CONCURRENCY,
    async ({ sheet, index }) => {
      const settlement = settlementById.get(sheet.id)!;
      let next: BatchSheet;
      try {
        const items = await fetchSettlementItems(sb, sheet.id);
        next = {
          ...sheet,
          data: {
            settlement,
            store: stores!.get(settlement.store_id)!,
            items,
            adjustments: adjRes.status === "fulfilled" ? adjustmentsForSettlement(adjRes.value, settlement) : [],
            skus: emptySkus,
            tenantName,
            receivable: settlement.generated_receivable_id ? receivables?.get(settlement.generated_receivable_id) ?? null : null,
          },
        };
      } catch (e) {
        next = { ...sheet, error: `明細讀取失敗：${errorMessage(e)}` };
      }
      if (isCancelled()) return;
      sheets[index] = next;
      onChange([...sheets]);
    },
    isCancelled,
  );
  if (isCancelled()) return;

  const skuIds = printedLineSkuIds(sheets.flatMap((s) => (s.data ? [s.data.items] : [])));
  const [skuRes] = await Promise.allSettled([
    fetchInBatches<Sku>(skuIds, IN_BATCH, (batch) =>
      sb.from("skus").select("id, sku_code, product_name, variant_name").in("id", batch),
    ),
  ]);
  if (isCancelled()) return;
  const skus = skuRes.status === "fulfilled" ? new Map(skuRes.value.map((x) => [x.id, x])) : null;

  onChange(
    sheets.map((sheet) => {
      if (!sheet.data) return sheet;
      const needsSkus = printedLineSkuIds([sheet.data.items]).length > 0;
      const failed: string[] = [];
      if (tenantFailed) failed.push("公司名稱");
      if (!skus && needsSkus) failed.push("商品編號／品名");
      if (!receivables && sheet.data.settlement.generated_receivable_id) failed.push("應收單號");
      return { ...sheet, namesFailed: failed, data: { ...sheet.data, skus: skus ?? emptySkus } };
    }),
  );
}

export type BatchPrintState = {
  total: number;
  /** 已讀完（含失敗）的家數，頂部進度用 */
  loadedCount: number;
  /** 明細、品名都讀完了 */
  allLoaded: boolean;
  /** 還要印的家（沒被拿掉），照網址順序 */
  active: BatchSheet[];
  /** 被拿掉的家（畫面要列出來「這次沒印哪幾家」） */
  removed: BatchSheet[];
  /** 印不了的家：紅字講哪一家、附「拿掉這家」 */
  issues: { id: number; label: string; message: string }[];
  draftCount: number;
  /** 列印鈕不給按的原因；能按是 undefined */
  blockReason: string | undefined;
};

/** 一次列印頁的整體狀態：全部載完、全部能印才放行列印（拿掉的家不算） */
export function batchPrintState(sheets: readonly BatchSheet[], removedIds: ReadonlySet<number>): BatchPrintState {
  const active = sheets.filter((s) => !removedIds.has(s.id));
  const removed = sheets.filter((s) => removedIds.has(s.id));
  const loadedCount = sheets.filter((s) => s.data !== null || s.error !== null).length;
  const issues: BatchPrintState["issues"] = [];
  for (const s of active) {
    if (s.error) {
      issues.push({ id: s.id, label: s.label, message: s.error });
    } else if (s.data) {
      const paper = statementPaper(s.data.settlement, s.data.items, s.data.adjustments);
      // 品名還在讀不算問題（allLoaded 會擋列印）；金額對不上不用等品名，當下就講
      if (s.namesFailed === null && paper.ok) continue;
      const reason = statementPrintBlockReason(paper, s.namesFailed);
      if (reason) issues.push({ id: s.id, label: s.label, message: reason });
    }
  }
  const allLoaded = sheets.length > 0 && loadedCount === sheets.length && !sheets.some((s) => s.data && s.namesFailed === null);
  let blockReason: string | undefined;
  if (!allLoaded) blockReason = "還在載入中…";
  else if (issues.length > 0) blockReason = `還有 ${issues.length} 家不能印，請先處理或拿掉`;
  else if (active.length === 0) blockReason = "沒有要印的對帳單";
  return {
    total: sheets.length,
    loadedCount,
    allLoaded,
    active,
    removed,
    issues,
    draftCount: active.filter((s) => s.status === "draft").length,
    blockReason,
  };
}
