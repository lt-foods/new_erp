// 解析 / 顯示退貨 transfer 的 notes（rpc_create_order_return 寫的 [order return...] tag）。
// 格式：[order return{|破損}{|取貨後退回}{: 原因}]，HQ 收貨可能在後面 append 多行備註。
//
// 用於：訂單明細退貨記錄、TransferDetailModal 備註、轉貨列表 note 欄。

export type ParsedReturnNote = {
  isReturn: boolean;   // notes 是否為 rpc_create_order_return 產生
  isDamage: boolean;   // |破損
  isRestock: boolean;  // |取貨後退回（客戶已取貨後退回）
  reason: string | null;
  extra: string | null; // HQ 收貨等後續 append 的備註
};

export function parseReturnNote(notes: string | null): ParsedReturnNote {
  if (!notes) return { isReturn: false, isDamage: false, isRestock: false, reason: null, extra: null };
  const m = notes.match(/^\[order return([^\]:]*)(?::\s*([^\]]*))?\]/);
  if (!m) return { isReturn: false, isDamage: false, isRestock: false, reason: null, extra: notes.trim() || null };
  const tags = m[1] ?? "";
  return {
    isReturn: true,
    isDamage: tags.includes("破損"),
    isRestock: tags.includes("取貨後退回"),
    reason: (m[2] ?? "").trim() || null,
    extra: notes.slice(m[0].length).trim() || null,
  };
}

// 單字串中文顯示（給備註欄 / 列表）。非退貨 note 原樣回傳，方便 caller 再接其它 tag 處理。
export function formatReturnNote(notes: string | null): string {
  if (!notes) return "";
  const p = parseReturnNote(notes);
  if (!p.isReturn) return notes;
  const tags: string[] = [];
  if (p.isDamage) tags.push("破損");
  if (p.isRestock) tags.push("客戶已取貨後退回");
  let label = "退貨";
  if (tags.length > 0) label += "・" + tags.join("・");
  if (p.reason) label += "：" + p.reason;
  if (p.extra) label += ` ${p.extra}`;
  return label;
}
