// Chunked fetch — bypass PostgREST 的 max-rows 1000 列上限。
//
// PostgREST/Supabase 單次 select 預設最多回 1000 列。撿貨工作台的
// v_picking_demand_by_po 是 PO×SKU×store 矩陣，多張未結 PO 時很容易破千列
// （實測 58 張 PO = 1811 列）；不分頁的話最新到貨的 PO 會被截在 1000 列之外、
// 整張在工作台 / 列印清單裡消失。凡是「要拿回整個 view」的查詢都該走這支。
//
// builder 必須回 fresh query builder（PostgREST builder 在 .range() 之後不可 reuse），
// 且查詢應帶 .order() 給分頁一個穩定的 total order，否則跨頁可能漏列或重複列。
export async function fetchAllRows<T>(
  builder: () => any, // eslint-disable-line @typescript-eslint/no-explicit-any
  pageSize = 1000,
  maxPages = 50,
): Promise<T[]> {
  const all: T[] = [];
  for (let p = 0; p < maxPages; p++) {
    const { data, error } = await builder().range(p * pageSize, (p + 1) * pageSize - 1);
    if (error) throw error;
    const rows = (data ?? []) as T[];
    all.push(...rows);
    if (rows.length < pageSize) break;
  }
  return all;
}
