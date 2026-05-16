// Audit trail helper — 把每天事件寫進 audit/day_N.json
const fs = require('fs');
const path = require('path');

const AUDIT_DIR = path.join(__dirname, 'audit');
fs.mkdirSync(AUDIT_DIR, { recursive: true });

function newAudit(day) {
  return {
    day,
    campaigns: [],       // [{id, no, name, sku_ids, end_at}]
    orders: [],          // [{id, no, campaign_id, member_id, store_id, items: [{sku_id, qty, unit_price}]}]
    closes: [],          // [{campaign_id, pr_id, action}]
    pr_splits: [],       // [{pr_id, po_ids: []}]
    po_sent: [],         // [{po_id, supplier_id}]
    grs: [],             // [{gr_id, gr_no, po_id, items: [{sku_id, qty}]}]
    waves: [],           // [{wave_id, wave_code, source_po_id, items: [{sku_id, store_id, qty}], transfers: [{id, no, store_id}]}]
    receives: [],        // [{transfer_id, transfer_no, store_id}]
    pickups: [],         // [{order_id, event_id, items: [...], total}]
    errors: [],          // [{step, msg}]
  };
}

function saveAudit(audit) {
  const fp = path.join(AUDIT_DIR, `day_${audit.day}.json`);
  fs.writeFileSync(fp, JSON.stringify(audit, null, 2));
  return fp;
}

module.exports = { newAudit, saveAudit, AUDIT_DIR };
