/**
 * fetchAllPaginated — 自動翻頁取完所有資料的 helper。
 *
 * 動機: PostgREST `max_rows = 1000` 對任何 .select() / view / RPC SETOF 套上 1000 列上限,
 *   不分頁就會靜默截斷。詳見 docs/STANDARD-資料分頁與筆數限制.md。
 *
 * 使用情境 (模式 C — 後端聚合 / 後台一次拿完):
 *   const all = await fetchAllPaginated<Row>(
 *     ({ from, to }) => sb.from("v_order_shortage")
 *       .select("...")
 *       .order("id", { ascending: true })
 *       .range(from, to)
 *   );
 *
 * **重要**:
 *  1. 呼叫端的 query 必須有穩定 ORDER BY (否則跨頁可能重複/遺漏)。
 *  2. safetyCap 預設 50000 (約 50 頁 × 1000)。超過會 throw,避免無上限掃描拖垮 admin tab。
 *  3. 任何用此 helper 計算「金額」「數量」聚合的程式,參見 STANDARD §4 — 仍應評估是否該改為 SQL 端 JSONB RPC。
 */
// 接受 supabase-js 的 PostgrestFilterBuilder (thenable),不限定必須是真正的 Promise。
// 回傳資料用 unknown[] 因為 supabase-js 對複雜 select 字串會推 GenericStringError[]。
// 由 caller 透過泛型 T 收斂類型。
type LooseResult = { data: unknown; error: { message: string } | null };

export async function fetchAllPaginated<T>(
  fetchPage: (args: { from: number; to: number }) => PromiseLike<LooseResult>,
  opts: { pageSize?: number; safetyCap?: number; label?: string } = {},
): Promise<T[]> {
  const pageSize = opts.pageSize ?? 1000;
  const safetyCap = opts.safetyCap ?? 50000;
  const label = opts.label ?? "fetchAllPaginated";
  const all: T[] = [];
  let from = 0;
  while (true) {
    const to = from + pageSize - 1;
    const { data, error } = await fetchPage({ from, to });
    if (error) throw new Error(`${label}: ${error.message}`);
    const rows = (Array.isArray(data) ? data : []) as T[];
    if (rows.length === 0) break;
    all.push(...rows);
    // 用「實際回傳筆數」推進 offset,而非寫死 pageSize。
    // 這樣即使 PostgREST max_rows 把單頁截到比 pageSize 短 (例如環境把
    // max_rows 調成 500、pageSize 仍 1000),offset 也只前進實際拿到的筆數,
    // 不會誤判「沒更多資料」而漏掉後續 row。只有真的回 0 筆才是結束。
    from += rows.length;
    if (all.length >= safetyCap) {
      console.error(`[PAGINATION-RISK] ${label} 撞到 safetyCap=${safetyCap},可能有未載入資料`);
      throw new Error(`${label} 累計 ${all.length} 筆超過 safetyCap=${safetyCap},請改用 SQL RPC 聚合或縮小過濾條件`);
    }
  }
  return all;
}
