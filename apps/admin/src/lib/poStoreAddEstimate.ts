// 採購單頁「分店／批發追加」：送出前預估「請購單、採購單各會加幾件」。
//
// 後端（20261016000000_picking_post_po_cancel_to_store.sql）：
//   rpc_add_po_store_demands（A7）實際寫入時：
//     請購 +max(差額 + N, 0)（N＝這次各店加的件數合計；跟改前一模一樣）
//     採購單：這個（採購單品項, 團）套新規則 ⇒ +max(0, 差額 + N + R − E)
//             不套（分界前、一團兩張、一鍵關掉）⇒ 跟請購一樣
//   R、E、套不套都讀 rpc_preview_po_store_addition_extra（A8）：
//     R＝叫貨後才取消、照派原店的件數（不拿來抵這次追加）
//     E＝以前追加時採購單比請購多加的件數合計（可能是負的）
//     沒有列＝R、E 都是 0、當不套（後端 A7 也是這樣當）。
//   ⇒ 這支的公式要跟 A7 同一條；A7 改了這裡要跟著改。
//
// ⓘ 一個 import 都沒有：純計算，`node --test` 直接吃 .ts 就驗得到（同 receiveAllocation.ts 的作法）。

/** rpc_preview_po_store_addition_extra 的一列。id、數量經 PostgREST 可能是字串 → 用的時候 Number() */
export type PoStoreAddExtraRow = {
  po_item_id: number | string;
  campaign_id: number | string;
  post_po_cancelled_qty: number | string | null;
  prior_po_extra_qty: number | string | null;
  rule_applies: boolean | null;
};

/** 一個（採購單品項, 團）的 R、E、套不套 */
export type PoStoreAddExtra = { r: number; e: number; ruleApplies: boolean };

/** 沒有列＝R、E 都是 0、不套（跟後端 A7 同一個當法） */
export const PO_STORE_ADD_NO_EXTRA: PoStoreAddExtra = { r: 0, e: 0, ruleApplies: false };

/**
 * 從 A8 的回傳挑出這個（採購單品項, 團）。
 * 跟 A7 讀法一樣：同一組有幾列就加總 R、E，有一列套就算套（實際上一組最多一列）。
 * 這一組的 R 或 E 讀到不是有限數字的值（例："NaN"、"abc"）⇒ 回 null＝當作讀不到 A8，
 *   呼叫端走既有退路（照不套算＋註明以送出後為準）；不可以默默當 0 算。
 */
export function pickPoStoreAddExtra(
  rows: PoStoreAddExtraRow[] | null | undefined,
  poItemId: number,
  campaignId: number | null,
): PoStoreAddExtra | null {
  if (!rows || campaignId == null) return PO_STORE_ADD_NO_EXTRA;
  let r = 0;
  let e = 0;
  let ruleApplies = false;
  let found = false;
  for (const row of rows) {
    if (Number(row.po_item_id) !== Number(poItemId) || Number(row.campaign_id) !== Number(campaignId)) continue;
    const rowR = readNum(row.post_po_cancelled_qty);
    const rowE = readNum(row.prior_po_extra_qty);
    if (rowR == null || rowE == null) return null;
    found = true;
    r += rowR;
    e += rowE;
    if (row.rule_applies === true) ruleApplies = true;
  }
  return found ? { r, e, ruleApplies } : PO_STORE_ADD_NO_EXTRA;
}

export type PoStoreAddEstimate = {
  /** 請購單會加幾件 */
  prAdd: number;
  /** 採購單會加幾件 */
  poAdd: number;
};

/**
 * 預估這次追加，請購單、採購單各會加幾件。
 *   delta      ＝追加之前這個（團, 商品）的差額（rpc_preview_po_store_additions 的 delta_qty；null＝後端查不到）
 *   storeTotal ＝這次各店加的件數合計（N）
 *   extra      ＝A8 這一組的 R、E、套不套；讀不到 A8 時傳 null ⇒ 照不套算（呼叫端要註明「以送出後為準」）
 * delta 是 null ⇒ 回 null（算不出來，由後端在送出時算）。
 * 結果四捨五入到小數 3 位（件數是 NUMERIC(18,3)），去掉 0.1＋0.2 這種浮點尾數；整數結果不變。
 */
export function estimatePoStoreAdd(
  delta: number | null,
  storeTotal: number,
  extra: PoStoreAddExtra | null,
): PoStoreAddEstimate | null {
  if (delta == null || !Number.isFinite(delta)) return null;
  const base = delta + storeTotal;
  const prAdd = round3(Math.max(base, 0));
  const ex = extra ?? PO_STORE_ADD_NO_EXTRA;
  const poAdd = ex.ruleApplies ? round3(Math.max(0, base + ex.r - ex.e)) : prAdd;
  return { prAdd, poAdd };
}

/**
 * 預估數字下面的說明（為什麼採購單加的件數 ≠ 店家加的件數、請購為什麼不一樣）。
 *   style＝"preview"：視窗裡那塊黃底預估（短句）；"confirm"：按送出後的確認框（括號句，含請購那一行）
 *   extra＝null：R、E 還沒讀到或讀不到 ⇒ 照不套的原文，再加一行「照舊算法估的，實際以送出後為準」
 *     （extraLoading：true＝讀取中、false＝讀不到；只影響那一行的用字）
 *   poTerm＝「採購單」那個詞（畫面統一用 PO_TERM_ZH；這支不 import，由呼叫端傳）
 *
 * 不套新規則：一字不改沿用改前的原文（「多叫…之前有人取消…先用掉」「原本就還沒叫貨的量」）。
 * 套新規則：採購單加完＝派車要送的量（有效訂單＋叫貨後才取消照派原店的件數），所以
 *   · 多叫／還沒叫貨，是跟「派車要送的量」比，不再說是「之前有人取消」造成的
 *     （叫貨後的取消已經算進要送的量，不會被拿來抵）；
 *   · R＞0 另外寫一行「照派原店、不算多叫、不拿來抵」；R＜0（抵減單）寫「照叫貨時的數量算」；
 *   · 請購跟採購單加的不一樣時，講清楚兩邊各照什麼算。
 *   E（以前追加多加／少加的件數）是內部帳，不另外寫；它已經反映在「多叫／還沒叫貨」的件數裡。
 */
export function poStoreAddExplainLines(opts: {
  estimate: PoStoreAddEstimate | null;
  storeTotal: number;
  extra: PoStoreAddExtra | null;
  extraLoading?: boolean;
  style: "preview" | "confirm";
  poTerm: string;
}): string[] {
  const { estimate, storeTotal, extra, extraLoading = false, style, poTerm } = opts;
  // 店家件數也取到小數 3 位，才跟 estimate（已四捨五入）比得齊：0.1＋0.2 不會變成「多叫 0 件」
  const n = round3(storeTotal);
  const confirm = style === "confirm";
  const lines: string[] = [];

  if (!estimate) {
    // 差額查不到：預估區塊什麼都不加；確認框照改前那樣只留請購那一行
    if (confirm) lines.push(`請購單對應那一列會跟著${poTerm}一起加（不用另外動）。`);
    return lines;
  }
  if (!confirm && !(n > 0)) return lines;

  const x = estimate.poAdd;
  const pr = estimate.prAdd;
  const rule = extra?.ruleApplies === true;

  if (!rule) {
    // ── 不套新規則（或 R、E 讀不到）：改前原文 ──
    if (x < n) {
      lines.push(
        confirm
          ? `　（這個團原本已經多叫 ${fmt(n - x)} 件——之前有人取消——先用掉，所以${poTerm}只加 ${fmt(x)} 件）`
          : `這個團原本已經多叫 ${fmt(n - x)} 件（之前有人取消），會先用掉。`,
      );
    }
    if (x > n) {
      lines.push(
        confirm
          ? `　（其中 ${fmt(x - n)} 件是這個團原本就還沒叫貨的量，一起補進這張${poTerm}）`
          : `其中 ${fmt(x - n)} 件是這個團原本就還沒叫貨的量，會一起補進來。`,
      );
    }
    if (extra == null) {
      lines.push(
        confirm
          ? "　（叫貨後取消的件數讀不到，這是照舊算法估的，實際以送出後為準）"
          : `叫貨後取消的件數${extraLoading ? "讀取中" : "讀不到"}，這是照舊算法估的，實際以送出後為準。`,
      );
    }
    if (confirm) {
      lines.push(
        x === 0 ? "請購單不用改（原本叫的量已經夠）。" : `請購單對應那一列會跟著${poTerm}一起加（不用另外動）。`,
      );
    }
    return lines;
  }

  // ── 套新規則 ──
  const r = extra.r;
  if (x < n) {
    lines.push(
      confirm
        ? `　（這個團原本叫的量比派車要送的多，先用掉其中 ${fmt(n - x)} 件，所以${poTerm}只加 ${fmt(x)} 件）`
        : `這個團原本叫的量比派車要送的多，會先用掉其中 ${fmt(n - x)} 件。`,
    );
  }
  if (x > n) {
    lines.push(
      confirm
        ? `　（其中 ${fmt(x - n)} 件是這個團原本就還沒叫貨的量，一起補進這張${poTerm}）`
        : `其中 ${fmt(x - n)} 件是這個團原本就還沒叫貨的量，會一起補進來。`,
    );
  }
  if (r > 0) {
    lines.push(
      confirm
        ? `　（叫貨後才取消的 ${fmt(r)} 件照派原店，不算多叫，不拿來抵這次追加）`
        : `叫貨後才取消的 ${fmt(r)} 件照派原店，不算多叫，不拿來抵這次追加。`,
    );
  } else if (r < 0) {
    lines.push(
      confirm
        ? `　（叫貨後才取消的抵減單 ${fmt(-r)} 件，派車照叫貨時的數量算，${poTerm}不用為它多加）`
        : `叫貨後才取消的抵減單 ${fmt(-r)} 件，派車照叫貨時的數量算，${poTerm}不用為它多加。`,
    );
  }
  if (pr !== x) {
    const why = `請購單只照現在還有效的訂單算，${poTerm}照派車要送的量算，所以兩邊加的不一樣`;
    if (confirm) {
      lines.push(
        pr === 0
          ? `請購單不用改（${why}；不用另外動）。`
          : `請購單對應那一列加 ${fmt(pr)} 件（${why}；不用另外動）。`,
      );
    } else {
      lines.push(pr === 0 ? `請購單不用改（${why}）。` : `請購單加 ${fmt(pr)} 件（${why}）。`);
    }
  } else if (confirm) {
    lines.push(
      x === 0 ? "請購單不用改（原本叫的量已經夠）。" : `請購單對應那一列會跟著${poTerm}一起加（不用另外動）。`,
    );
  }
  return lines;
}

/** 數量經 PostgREST 可能是字串；null＝0；不是有限數字（"NaN"、"abc"）⇒ null＝讀不到 */
function readNum(value: number | string | null | undefined): number | null {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? n : null;
}

function round3(n: number): number {
  return Math.round(n * 1000) / 1000;
}

function fmt(n: number): string {
  return Number.isInteger(n) ? String(n) : n.toFixed(3).replace(/\.?0+$/, "");
}
