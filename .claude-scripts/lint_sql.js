#!/usr/bin/env node
// Validates SQL syntax of all migration files using PostgreSQL parser.
const fs = require('fs');
const path = require('path');

const MIG_DIR = path.join(__dirname, '..', 'supabase', 'migrations');
const files = fs.readdirSync(MIG_DIR).filter(f => f.endsWith('.sql')).sort();

(async () => {
  const init = require('pg-query-emscripten').default;
  let totalErrors = 0;
  for (const file of files) {
    const filePath = path.join(MIG_DIR, file);
    const sql = fs.readFileSync(filePath, 'utf8');
    const api = await init();  // Fresh wasm instance per file (avoids heap exhaustion)
    try {
      const result = api.parse(sql);
      if (result.error) {
        console.error(`[FAIL] ${file}: ${result.error.message} at cursor ${result.error.cursorpos}`);
        const ctx = sql.slice(Math.max(0, result.error.cursorpos - 80), result.error.cursorpos + 80);
        console.error(`        context: ...${ctx.replace(/\n/g, ' ')}...`);
        totalErrors++;
      } else {
        console.log(`[OK]   ${file}: ${result.parse_tree.stmts.length} statements parsed`);
      }
    } catch (e) {
      console.error(`[CRASH] ${file}: ${e.message}`);
      totalErrors++;
    }
  }
  console.log(`\n${totalErrors === 0 ? 'All files parsed cleanly' : totalErrors + ' file(s) had errors'}`);
  process.exit(totalErrors === 0 ? 0 : 1);
})();
