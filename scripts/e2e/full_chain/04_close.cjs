// Step 4: 關 campaign → 自動建 PR + 驗 trigger
const { newClient, setJwt, ADMIN_UID } = require('./_db.cjs');

const CAMP_ID = 18;

async function main() {
  const c = newClient();
  await c.connect();
  console.log('==== Step 4: Close campaign ====');

  // Inject tenant_id JWT claim (rpc_close_campaign uses _current_tenant_id())
  await c.query(`BEGIN`);
  await setJwt(c);

  // Campaign 是否已 closed? 是的話跳過 close, 直接 try create_pr_from_campaign
  const cur = await c.query(`SELECT status FROM group_buy_campaigns WHERE id=$1`, [CAMP_ID]);
  if (cur.rows[0]?.status === 'open') {
    const result = await c.query(`SELECT rpc_close_campaign($1, $2) AS result`, [CAMP_ID, ADMIN_UID]);
    console.log('rpc_close_campaign result:');
    console.log(JSON.stringify(result.rows[0].result, null, 2));
  } else {
    console.log('Campaign already closed (status=', cur.rows[0]?.status, '); calling rpc_create_pr_from_campaign directly');
    try {
      const r = await c.query(`SELECT rpc_create_pr_from_campaign($1, $2) AS pr_id`, [CAMP_ID, ADMIN_UID]);
      console.log('Created PR id:', r.rows[0].pr_id);
    } catch (e) {
      console.log('rpc_create_pr_from_campaign error:', e.message);
    }
  }
  await c.query(`COMMIT`);

  // 驗 campaign status
  const camp = await c.query(`SELECT id, status, end_at FROM group_buy_campaigns WHERE id=$1`, [CAMP_ID]);
  console.log('Campaign after close:', JSON.stringify(camp.rows[0]));

  // 驗 PR 自動建立
  const pr = await c.query(`
    SELECT pr.id, pr.pr_no, pr.status, pr.source_type, pr.source_close_date, pr.source_campaign_id,
           array_agg(json_build_object('sku_id', pri.sku_id, 'qty', pri.qty_requested, 'source_camp', pri.source_campaign_id)) AS items
      FROM purchase_requests pr
      LEFT JOIN purchase_request_items pri ON pri.pr_id = pr.id
     WHERE pr.created_at >= NOW() - INTERVAL '1 minute'
       AND (pr.source_campaign_id = $1
            OR EXISTS (SELECT 1 FROM purchase_request_items WHERE pr_id=pr.id AND source_campaign_id=$1))
     GROUP BY pr.id
  `, [CAMP_ID]);
  console.log('\nNew PR(s) from close:');
  console.log(JSON.stringify(pr.rows, null, 2));

  if (pr.rows[0]) {
    const prId = pr.rows[0].id;
    // 驗 trigger: purchase_request_campaigns 應該已 sync
    const prc = await c.query(`SELECT pr_id, campaign_id FROM purchase_request_campaigns WHERE pr_id=$1`, [prId]);
    console.log(`\npurchase_request_campaigns for PR ${prId}:`);
    console.log(JSON.stringify(prc.rows, null, 2));

    // 跑 invariant check
    const check = await c.query(`SELECT COUNT(*) AS orphans FROM fn_check_pr_campaigns_consistency()`);
    console.log('Invariant check orphans:', check.rows[0].orphans);
  }

  await c.end();
}

main().catch(e => { console.error('FAIL:', e.message); process.exit(1); });
