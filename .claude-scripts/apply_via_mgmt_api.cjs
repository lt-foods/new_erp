#!/usr/bin/env node
// 對 prod 跑 SQL — 走 Supabase Management API（pooler TCP 在本環境被擋，見 CLAUDE.md）。
// 用法：
//   node .claude-scripts/apply_via_mgmt_api.cjs <migration.sql>          # 套整檔
//   node .claude-scripts/apply_via_mgmt_api.cjs --sql "SELECT ..."       # ad-hoc 查詢
// 需要 SUPABASE_ACCESS_TOKEN（sbp_ 開頭的 personal access token）。
const fs = require('fs');

const PROJECT_REF = 'anfyoeviuhmzzrhilwtm';
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!token) {
  console.error('Set SUPABASE_ACCESS_TOKEN env var (https://supabase.com/dashboard/account/tokens)');
  process.exit(2);
}

let sql;
if (process.argv[2] === '--sql') {
  sql = process.argv[3];
} else if (process.argv[2]) {
  sql = fs.readFileSync(process.argv[2], 'utf8');
}
if (!sql) {
  console.error('usage: apply_via_mgmt_api.cjs <sql_path> | --sql "<query>"');
  process.exit(2);
}

(async () => {
  const res = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await res.text();
  if (!res.ok) {
    console.error(`FAIL HTTP ${res.status}: ${body}`);
    process.exit(1);
  }
  try {
    console.log(JSON.stringify(JSON.parse(body), null, 2));
  } catch {
    console.log(body);
  }
})().catch((e) => { console.error('FAIL:', e.message); process.exit(1); });
