#!/usr/bin/env node
// Master orchestrator — 一鍵跑完整 E2E 鏈路 (Step 1-10、跳過 UI-only step)
//
// 用法：
//   node scripts/e2e/full_chain/run_all.cjs
//
// 跳過：
//   - Step 2 直接併進 Step 1 (build product + campaign in one go)
//   - Step 9 (UI pickup) — script 內只跑 SQL fallback for orders 31/32
//     Order 30 留給 user 自行用 UI /pickup 跑、或加 SKIP_UI=1 也跑 SQL
//
// 重跑：
//   所有 step idempotent，重跑會 reuse 既有 marker 資料、不會建重複。
//   想全清重來：node scripts/e2e/full_chain/cleanup.cjs

const { spawn } = require('child_process');
const path = require('path');

const STEPS = [
  ['01', '01_setup.cjs', '建商品 / SKU / 價格 / supplier_skus / campaign / campaign_item'],
  ['03', '03_orders.cjs', '建 3 顧客訂單'],
  ['04', '04_close.cjs', '關 campaign → 自動建 PR + 驗 trigger'],
  ['05', '05_pr_po_gr.cjs', 'PR submit → approve → split PO → send → GR confirm'],
  ['07', '07_wave.cjs', 'Picking wave → ship → generate transfers'],
  ['08', '08_receive.cjs', '3 transfer 全部分店收貨'],
  ['09', '09_pickup.cjs', '顧客取貨 (SQL fallback for 31/32)'],
  ['10', '10_invariants.cjs', '最終 invariants 檢查'],
];

function run(step, script, label) {
  return new Promise((resolve, reject) => {
    const fp = path.join(__dirname, script);
    console.log(`\n\x1b[1m=== Step ${step}: ${label} ===\x1b[0m`);
    const proc = spawn('node', [fp], { stdio: 'inherit' });
    proc.on('close', code => {
      if (code === 0) resolve();
      else reject(new Error(`Step ${step} exited ${code}`));
    });
  });
}

(async () => {
  const start = Date.now();
  for (const [step, script, label] of STEPS) {
    try {
      await run(step, script, label);
    } catch (e) {
      console.error(`\x1b[31m✗ ${e.message}\x1b[0m`);
      process.exit(1);
    }
  }
  const sec = Math.round((Date.now() - start) / 1000);
  console.log(`\n\x1b[32m✅ All steps done in ${sec}s\x1b[0m`);
})();
