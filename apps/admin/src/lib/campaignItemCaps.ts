// 限量團每個規格（口味）各自的上限：建立開團、編輯開團共用的純函式。
// 上限填 0 在下單檢查裡等於不限（COALESCE(cap_qty, 0) > 0 才算有設），所以畫面一律拒收。

export const CAP_INPUT_ERROR = "上限要填大於 0 的整數";

/** 空字串＝沒填（null）；0、負數、小數、其他文字＝不合法（ok: false）。 */
export function parseCapInput(raw: string): { ok: true; value: number | null } | { ok: false } {
  const s = raw.trim();
  if (s === "") return { ok: true, value: null };
  if (!/^\d+$/.test(s)) return { ok: false };
  const n = Number(s);
  if (!Number.isSafeInteger(n) || n <= 0) return { ok: false };
  return { ok: true, value: n };
}

export type ItemCapsPlan =
  | { kind: "none" } // 全空：走整團總量
  | { kind: "all"; itemCaps: { sku_id: number; cap_qty: number }[] } // 全填：送 p_item_caps
  | { kind: "partial"; missing: string[] } // 只填一部分
  | { kind: "invalid"; bad: string[] }; // 有不合法的數字

/** 建立開團：把每個規格那一格的字，換成要送出的內容。 */
export function planItemCaps(
  skus: { id: number; label: string }[],
  drafts: Record<number, string>,
): ItemCapsPlan {
  const parsed = skus.map((s) => ({ s, r: parseCapInput(drafts[s.id] ?? "") }));
  const bad = parsed.filter((p) => !p.r.ok).map((p) => p.s.label);
  if (bad.length > 0) return { kind: "invalid", bad };
  const filled: { sku_id: number; cap_qty: number }[] = [];
  const missing: string[] = [];
  for (const p of parsed) {
    const value = p.r.ok ? p.r.value : null;
    if (value == null) missing.push(p.s.label);
    else filled.push({ sku_id: p.s.id, cap_qty: value });
  }
  if (filled.length === 0) return { kind: "none" };
  if (missing.length > 0) return { kind: "partial", missing };
  return { kind: "all", itemCaps: filled };
}

/** 規格的顯示名稱：沒有規格名就用編號。 */
export function skuLabel(variantName: string | null | undefined, skuCode: string): string {
  return variantName?.trim() || skuCode;
}

export type CampaignItemForCapSave = {
  id: number;
  campaign_id: number;
  sku_id: number;
  unit_price: number;
  sort_order: number;
  notes: string | null;
};

/**
 * 編輯開團存上限：rpc_upsert_campaign_item 會把 cap_qty、notes 整個蓋掉，
 * 所以單價、排序、備註一定要從存檔前剛讀到的那一列帶回去。
 */
export function capUpsertArgs(latest: CampaignItemForCapSave, cap: number | null) {
  return {
    p_id: latest.id,
    p_campaign_id: latest.campaign_id,
    p_sku_id: latest.sku_id,
    p_unit_price: latest.unit_price,
    p_cap_qty: cap,
    p_sort_order: latest.sort_order,
    p_notes: latest.notes,
  };
}

/** 編輯開團「量上限」能不能改：限量團、草稿或開團中；角色比照手機團控那組。 */
export function canEditItemCap(args: {
  closeType: string | null | undefined;
  status: string | null | undefined;
  isAdminRole: boolean;
  role: string | null;
}): boolean {
  if (args.closeType !== "limited") return false;
  if (args.status !== "draft" && args.status !== "open") return false;
  return args.isAdminRole || args.role === "hq_manager" || args.role === "assistant";
}

const hasCap = (cap: number | null | undefined) => (cap ?? 0) > 0;

/**
 * 限量團紅字：有規格沒上限（空或 0 都等於不限），而且整團總量也沒有。
 * 總量要「已存檔」和「表單目前」都有才算有：只改了表單還沒按儲存，真正的系統仍然是沒上限。
 */
export function itemsWithoutCap(args: {
  closeType: string | null | undefined;
  items: { cap_qty: number | null; label: string }[];
  savedTotalCap: number | null | undefined;
  formTotalCap: number | null | undefined;
}): string[] {
  if (args.closeType !== "limited") return [];
  if (hasCap(args.savedTotalCap) && hasCap(args.formTotalCap)) return [];
  return args.items.filter((i) => !hasCap(i.cap_qty)).map((i) => i.label);
}

/**
 * 編輯開團按儲存：要存成主商城限量團、總量又空著時，所有非贈品品項都要有上限，否則團會完全沒上限。
 * 已下架的規格不算：商品明細不顯示，也沒地方填。
 * capsEditable＝這個團「已存檔」的狀態下量上限欄能不能改；常規改限量還沒存時不能，只能先填總量。
 */
export function limitedSaveCapProblem(args: {
  closeType: string;
  salesChannel: string;
  totalCap: number | null | undefined;
  items: { cap_qty: number | null; is_gift: boolean | null; sku_status: string; label: string }[];
  capsEditable: boolean;
}): string | null {
  if (args.closeType !== "limited" || args.salesChannel !== "main") return null;
  if (args.totalCap != null) return null;
  const missing = args.items
    .filter((i) => !i.is_gift && i.sku_status !== "discontinued" && !hasCap(i.cap_qty))
    .map((i) => i.label);
  if (missing.length === 0) return null;
  const head = `沒有儲存：限量團的總量上限空著，而且這些品項沒有上限，客人可以一直買：${missing.join("、")}。`;
  return args.capsEditable
    ? `${head}請到上方「商品明細」填量上限並按「存」，或在這裡填總量上限。`
    : `${head}請在這裡填總量上限再儲存。要各口味分開限量：先存成限量團，再回來填每個口味的量上限。`;
}

/** 編輯開團表單：限量團的總量上限可留空，有填就要是大於 0 的整數。 */
export function limitedTotalCapProblem(closeType: string, total: number | null | undefined): string | null {
  if (closeType !== "limited" || total == null) return null;
  if (!Number.isInteger(total) || total <= 0) return "總量上限要填大於 0 的整數，或留空";
  return null;
}
