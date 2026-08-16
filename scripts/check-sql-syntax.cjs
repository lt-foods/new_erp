// 用 libpg_query（pg-query-emscripten）離線檢查 migration 的 SQL 語法。
// 用法：node scripts/check-sql-syntax.cjs supabase/migrations/xxx.sql [...]
//
// 為什麼要有這支：套 SQL 到線上要走 Management API，出錯才知道語法問題太晚
// （而且 CREATE OR REPLACE 半套會留下壞掉的函式）。這支用真的 Postgres parser
// 先擋一輪語法錯 —— 注意它**只驗語法**，不驗欄位/函式存不存在。
const fs = require('fs');

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('usage: node scripts/check-sql-syntax.cjs <file.sql> [...]');
  process.exit(2);
}

(async () => {
  let bad = 0;

  for (const f of files) {
    // 每個檔案開一個全新的 wasm instance：同一個 instance 連續 parsePlpgsql
    // 多份檔案會在模組內部爆掉（`Ma[...] is not a function`），
    // 那是 emscripten 的狀態問題、不是 SQL 有錯 —— 曾經誤判過一次。
    // 這個套件是 ESM-interop 包裝：真正的 factory 掛在 .default 上。
    const PgQuery = await require('pg-query-emscripten').default();
    const sql = fs.readFileSync(f, 'utf8');
    const res = PgQuery.parse(sql);
    if (res.error) {
      bad++;
      const { message, cursorpos } = res.error;
      // cursorpos 是 byte offset → 換算成行號，方便直接跳過去看
      const upto = sql.slice(0, cursorpos ?? 0);
      const line = upto.split('\n').length;
      console.error(`✗ ${f}:${line}  ${message}`);
      console.error(`    …${sql.slice(Math.max(0, (cursorpos ?? 0) - 60), (cursorpos ?? 0) + 60).replace(/\n/g, ' ⏎ ')}`);
      continue;
    }

    // 外層 SQL 過了不代表函式內文是對的 —— 對 parser 來說 PL/pgSQL 的 body
    // 只是一個字串常數。parsePlpgsql 才會真的去解 DECLARE/BEGIN…END 那一段，
    // 而這支 migration 的程式碼大半在那裡面。
    const pl = PgQuery.parsePlpgsql(sql);
    if (pl.error) {
      bad++;
      console.error(`✗ ${f}  [plpgsql] ${pl.error.message}`);
      continue;
    }

    const n = res.parse_tree?.stmts?.length ?? 0;
    const fns = pl.plpgsql_funcs?.length ?? 0;
    console.log(`✓ ${f}  (${n} statements, ${fns} plpgsql funcs)`);
  }

  process.exit(bad > 0 ? 1 : 0);
})().catch((e) => {
  console.error('parser error:', e);
  process.exit(2);
});
