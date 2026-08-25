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

// 這個套件是 ESM-interop 包裝：真正的 factory 掛在 .default 上。
const newParser = () => require('pg-query-emscripten').default();

// libpg_query 的 offset 是 **byte** offset，而 migration 裡滿滿中文註解，
// 直接拿去 String.slice（UTF-16 code unit）會偏掉好幾十個字元。
const sliceBytes = (buf, from, len) =>
  buf.slice(from, len == null ? undefined : from + len).toString('utf8');

(async () => {
  let bad = 0;

  for (const f of files) {
    // 每個檔案開一個全新的 wasm instance：同一個 instance 連續 parsePlpgsql
    // 多份檔案會在模組內部爆掉（`Ma[...] is not a function`），
    // 那是 emscripten 的狀態問題、不是 SQL 有錯 —— 曾經誤判過一次。
    const PgQuery = await newParser();
    const sql = fs.readFileSync(f, 'utf8');
    const buf = Buffer.from(sql, 'utf8');
    const res = PgQuery.parse(sql);
    if (res.error) {
      bad++;
      const { message, cursorpos } = res.error;
      // cursorpos 是 byte offset → 換算成行號，方便直接跳過去看
      const line = sliceBytes(buf, 0, cursorpos ?? 0).split('\n').length;
      const around = sliceBytes(buf, Math.max(0, (cursorpos ?? 0) - 60), 120);
      console.error(`✗ ${f}:${line}  ${message}`);
      console.error(`    …${around.replace(/\n/g, ' ⏎ ')}`);
      continue;
    }

    // 外層 SQL 過了不代表函式內文是對的 —— 對 parser 來說 PL/pgSQL 的 body
    // 只是一個字串常數。parsePlpgsql 才會真的去解 DECLARE/BEGIN…END 那一段，
    // 而這支 migration 的程式碼大半在那裡面。
    //
    // ⚠ 一次餵整個檔案會在**第 4 支** plpgsql 函式左右爆同一個
    // `Ma[...] is not a function`（同 instance 的狀態問題，不是 SQL 有錯）——
    // 2026-08-25 實測：已經套上線的 20260824060000（7 支）也照炸，
    // 等於大檔一律驗不到函式內文，而 migration 的程式碼大半在那裡面。
    // 所以改成**一支函式一個 instance**：拿 parse tree 的 stmt_location/stmt_len
    // 切出每一段 CREATE FUNCTION 單獨驗（regex 切會被字串裡的 $$ 騙）。
    const stmts = res.parse_tree?.stmts ?? [];
    let fns = 0;
    let plErr = null;
    for (const s of stmts) {
      const text = sliceBytes(buf, s.stmt_location ?? 0, s.stmt_len);
      if (!/\bCREATE\s+(OR\s+REPLACE\s+)?FUNCTION\b/i.test(text)) continue;
      const one = await newParser();
      const pl = one.parsePlpgsql(`${text};`);
      if (pl.error) {
        const name = /FUNCTION\s+(?:public\.)?(\w+)/i.exec(text)?.[1] ?? '?';
        plErr = `${name}: ${pl.error.message}`;
        break;
      }
      fns += pl.plpgsql_funcs?.length ?? 0;
    }
    if (plErr) {
      bad++;
      console.error(`✗ ${f}  [plpgsql] ${plErr}`);
      continue;
    }

    console.log(`✓ ${f}  (${stmts.length} statements, ${fns} plpgsql funcs)`);
  }

  process.exit(bad > 0 ? 1 : 0);
})().catch((e) => {
  console.error('parser error:', e);
  process.exit(2);
});
