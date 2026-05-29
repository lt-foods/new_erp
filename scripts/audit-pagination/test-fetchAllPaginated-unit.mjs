// 複製 fetchAllPaginated 的核心邏輯 (新版) 驗證演算法
async function fetchAllPaginated(fetchPage, opts = {}) {
  const pageSize = opts.pageSize ?? 1000;
  const safetyCap = opts.safetyCap ?? 50000;
  const all = [];
  let from = 0;
  while (true) {
    const to = from + pageSize - 1;
    const { data, error } = await fetchPage({ from, to });
    if (error) throw new Error(error.message);
    const rows = Array.isArray(data) ? data : [];
    if (rows.length === 0) break;
    all.push(...rows);
    from += rows.length;
    if (all.length >= safetyCap) throw new Error("safetyCap");
  }
  return all;
}

// 模擬一個資料源,server 端 max_rows 上限可調 (模擬 PostgREST)
function makeSource(total, serverMaxRows) {
  const data = Array.from({ length: total }, (_, i) => i);
  return ({ from, to }) => {
    const reqCount = to - from + 1;
    const capped = Math.min(reqCount, serverMaxRows);   // server 截短
    const slice = data.slice(from, from + capped);
    return Promise.resolve({ data: slice, error: null });
  };
}

let pass = 0, fail = 0;
function check(name, got, want) {
  if (got === want) { pass++; console.log(`✅ ${name}: ${got}`); }
  else { fail++; console.log(`❌ ${name}: got ${got}, want ${want}`); }
}

// 1. pageSize == max_rows == 1000, 1500 筆
check("正常 1500筆/page1000/max1000", (await fetchAllPaginated(makeSource(1500, 1000), {pageSize:1000})).length, 1500);
// 2. 關鍵情境: max_rows(500) < pageSize(1000), 1500 筆 — 舊版會漏,新版不漏
check("max_rows<pageSize 1500筆", (await fetchAllPaginated(makeSource(1500, 500), {pageSize:1000})).length, 1500);
// 3. 剛好整除 1000 筆
check("剛好1000筆", (await fetchAllPaginated(makeSource(1000, 1000), {pageSize:1000})).length, 1000);
// 4. 0 筆
check("0筆", (await fetchAllPaginated(makeSource(0, 1000), {pageSize:1000})).length, 0);
// 5. max_rows 極小(7) vs pageSize 1000, 50 筆
check("max7 50筆", (await fetchAllPaginated(makeSource(50, 7), {pageSize:1000})).length, 50);
// 6. safetyCap 觸發
try { await fetchAllPaginated(makeSource(100000, 1000), {pageSize:1000, safetyCap:5000}); check("safetyCap throw", false, true); }
catch { check("safetyCap throw", true, true); }

console.log(`\n${fail === 0 ? "ALL PASS" : fail + " FAILED"} (${pass}/${pass+fail})`);
process.exit(fail === 0 ? 0 : 1);
