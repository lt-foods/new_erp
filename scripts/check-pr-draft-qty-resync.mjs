import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migration = readFileSync(resolve(root, "supabase/migrations/20260930000000_pr_draft_qty_resync.sql"), "utf8").replace(/\r\n?/g, "\n");
const page = readFileSync(resolve(root, "apps/admin/src/app/(protected)/purchase/requests/edit/page.tsx"), "utf8").replace(/\r\n?/g, "\n");

function section(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing section: ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.ok(to > from, `missing section end: ${end}`);
  return source.slice(from, to);
}

function verify(sql, ui) {
  assert.match(sql, /campaign_id\s+BIGINT NOT NULL REFERENCES public\.group_buy_campaigns\(id\) ON DELETE CASCADE/);
  assert.match(sql, /sku_id\s+BIGINT NOT NULL REFERENCES public\.skus\(id\) ON DELETE CASCADE/);
  assert.equal((sql.match(/REFERENCING (?:OLD|NEW)/g) ?? []).length, 4);
  assert.equal((sql.match(/FOR EACH STATEMENT/g) ?? []).length, 4);

  const triggerPart = section(sql, "CREATE OR REPLACE FUNCTION public._pr_mark_dirty", "-- \u73fe\u6709 helper");
  assert.equal((triggerPart.match(/EXCEPTION WHEN OTHERS/g) ?? []).length, 2);
  assert.equal((triggerPart.match(/RAISE WARNING/g) ?? []).length, 2);
  assert.doesNotMatch(triggerPart, /_pr_apply_qty_sync|UPDATE public\.purchase_request_items/);

  const preview = section(sql, "CREATE OR REPLACE FUNCTION public._pr_qty_sync_preview", "REVOKE ALL ON FUNCTION public._pr_qty_sync_preview");
  assert.match(preview, /pr_campaigns AS \(/);
  assert.match(preview, /purchase_request_campaigns/);
  assert.match(preview, /FROM remaining r\s+LEFT JOIN current_pairs/);
  assert.match(preview, /'missing_item'/);
  assert.doesNotMatch(preview, /JOIN pairs p USING \(campaign_id, sku_id\)/);

  const apply = section(sql, "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync", "CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty");
  const advisory = "hashtext(r.campaign_id::TEXT),\n      hashtext(r.sku_id::TEXT)";
  assert.ok(apply.includes(advisory));
  assert.ok(apply.indexOf(advisory) < apply.indexOf("FOR UPDATE;"), "advisory must precede PR/item row locks");
  assert.doesNotMatch(apply, /v_tenant::TEXT \|\| ':' \|\| r\.campaign_id/);
  assert.match(apply, /r\.pr_item_id IS NULL AND r\.delta_qty <> 0/);
  assert.match(apply, /INSERT INTO public\.purchase_request_qty_sync_log/);
  assert.match(apply, /UPDATE public\.purchase_request_item_campaigns[\s\S]*SET qty_requested = r\.target_qty/);
  assert.match(apply, /UPDATE public\.purchase_request_items pri[\s\S]*SELECT COALESCE\(SUM\(pric\.qty_requested\), 0\)/);

  const storeAddWrapper = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_add_pr_store_demands", "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync");
  assert.match(storeAddWrapper, /hashtext\(p_campaign_id::TEXT\),\s+hashtext\(v_sku_id::TEXT\)/);
  assert.match(storeAddWrapper, /FROM public\.group_buy_campaigns[\s\S]*FOR NO KEY UPDATE/);
  assert.doesNotMatch(storeAddWrapper, /FROM public\.group_buy_campaigns[\s\S]*FOR UPDATE/);
  assert.ok(storeAddWrapper.indexOf("FROM public.group_buy_campaigns") < storeAddWrapper.indexOf("pg_advisory_xact_lock"));
  assert.ok(storeAddWrapper.indexOf("pg_advisory_xact_lock") < storeAddWrapper.indexOf("_rpc_add_pr_store_demands_20260930_inner("));

  const validation = section(sql, "CREATE OR REPLACE FUNCTION public._pr_validate_qty_current", "REVOKE ALL ON FUNCTION public._pr_validate_qty_current");
  assert.match(validation, /purchase_request_campaigns/);
  assert.match(validation, /_pr_campaign_sku_remaining_rows\(v_campaign_ids\)/);
  assert.doesNotMatch(validation, /JOIN wanted/);

  const snapshot = section(sql, "CREATE OR REPLACE FUNCTION public._pr_lock_demand_snapshot", "REVOKE ALL ON FUNCTION public._pr_lock_demand_snapshot");
  const lockTargets = ["group_buy_campaigns", "campaign_items", "customer_orders", "customer_order_items"];
  let lastLock = -1;
  for (const target of lockTargets) {
    const at = snapshot.indexOf(`public.${target}`);
    assert.ok(at > lastLock, `demand lock order broken at ${target}`);
    lastLock = at;
  }
  assert.equal((snapshot.match(/FOR UPDATE/g) ?? []).length, 4);
  assert.match(snapshot, /ORDER BY gbc\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY ci\.campaign_id, ci\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY co\.campaign_id, co\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY co\.campaign_id, co\.id, coi\.id[\s\S]*FOR UPDATE OF coi/);

  const deletePr = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_delete_pr", "COMMENT ON FUNCTION public.rpc_delete_pr");
  const deleteSnapshotCall = "PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);";
  assert.ok(deletePr.indexOf(deleteSnapshotCall) >= 0 && deletePr.indexOf(deleteSnapshotCall) < deletePr.indexOf("SELECT status INTO v_status"));
  assert.match(deletePr, /v_role NOT IN \('owner','admin','hq_manager',''\)/);
  assert.match(deletePr, /v_status IN \('partially_ordered','fully_ordered'\)/);
  assert.match(deletePr, /UPDATE group_buy_campaigns[\s\S]*SET status\s+= 'closed'/);
  assert.match(deletePr, /DELETE FROM purchase_requests/);

  const submit = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_submit_pr", "-- ---------------------------------------------------------------------------\n-- \u5efa PO");
  assert.ok(submit.indexOf("_pr_apply_qty_sync") < submit.indexOf("SET status = 'submitted'"));
  assert.ok(submit.indexOf("_pr_validate_qty_current") < submit.indexOf("SET status = 'submitted'"));
  assert.ok(submit.indexOf("FOR UPDATE") === -1 || submit.indexOf("FOR UPDATE") > submit.indexOf("_pr_apply_qty_sync"));

  const split = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos", "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po");
  const splitSnapshotCall = "PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);";
  assert.match(split, /v_role\s+TEXT := COALESCE/);
  assert.match(split, /v_tenant\s+UUID := public\._current_tenant_id\(\)/);
  assert.match(split, /v_role NOT IN \('owner','admin','hq_manager','purchaser','assistant',''\)/);
  assert.match(split, /p_operator <> auth\.uid\(\)/);
  assert.ok(split.indexOf(splitSnapshotCall) >= 0 && split.indexOf(splitSnapshotCall) < split.indexOf("FOR UPDATE"));
  const splitReviewChecks = [...split.matchAll(/IF v_review <> 'approved' THEN/g)].map((m) => m.index);
  const splitStatusChecks = [...split.matchAll(/IF v_status <> 'submitted' THEN/g)].map((m) => m.index);
  assert.equal(splitReviewChecks.length, 2);
  assert.equal(splitStatusChecks.length, 2);
  assert.ok(splitReviewChecks[0] < split.indexOf(splitSnapshotCall) && splitReviewChecks[1] > split.indexOf(splitSnapshotCall));
  assert.ok(splitStatusChecks[0] < split.indexOf(splitSnapshotCall) && splitStatusChecks[1] > split.indexOf(splitSnapshotCall));
  assert.equal((split.match(/v_positive_count = 0/g) ?? []).length, 2);
  assert.equal((split.match(/v_unassigned > 0/g) ?? []).length, 2);
  assert.ok(split.indexOf("_pr_validate_qty_current") < split.indexOf("rpc_next_po_no"));
  assert.ok(split.indexOf(splitSnapshotCall) < split.indexOf("_pr_validate_qty_current"));
  assert.ok(split.indexOf("_pr_validate_qty_current") < split.indexOf("INSERT INTO public.purchase_orders"));

  const merge = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po", "-- \u90e8\u5206\u8f49\u63a1\u8cfc");
  const mergeSnapshotCall = "PERFORM public._pr_lock_demand_snapshot(v_snapshot_pr_ids);";
  assert.match(merge, /v_role NOT IN \('owner','admin','hq_manager','purchaser','assistant',''\)/);
  assert.match(merge, /p_operator <> auth\.uid\(\)/);
  assert.match(merge, /pr\.status = 'submitted'/);
  assert.match(merge, /pr\.review_status = 'approved'/);
  const mergeEligibilityChecks = [...merge.matchAll(/IF v_matched <> v_want THEN/g)].map((m) => m.index);
  assert.equal(mergeEligibilityChecks.length, 2);
  assert.ok(mergeEligibilityChecks[0] < merge.indexOf(mergeSnapshotCall));
  assert.ok(mergeEligibilityChecks[1] > merge.indexOf(mergeSnapshotCall));
  assert.ok(merge.indexOf(mergeSnapshotCall) >= 0 && merge.indexOf(mergeSnapshotCall) < merge.indexOf("FOR UPDATE"));
  assert.ok(merge.indexOf(mergeSnapshotCall) < merge.indexOf("_pr_validate_qty_current"));
  assert.ok(merge.indexOf("_pr_validate_qty_current") < merge.indexOf("INSERT INTO public.purchase_orders"));
  const spendPart = section(merge, "INSERT INTO public.purchase_orders", "RETURN v_po_id");
  assert.match(spendPart, /ANY\(v_valid_ids\)/);
  assert.doesNotMatch(spendPart, /ANY\(p_pr_item_ids\)/);

  const partial = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_create_partial_pr_from_items", "COMMENT ON TABLE");
  assert.match(partial, /UPDATE public\.purchase_request_items[\s\S]*SET pr_id = v_new_pr_id/);
  assert.match(partial, /UPDATE public\.purchase_request_store_additions[\s\S]*SET pr_id = v_new_pr_id/);
  assert.doesNotMatch(partial, /DELETE FROM public\.purchase_request_items/);

  const previewRpc = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_preview_pr_qty_sync", "REVOKE ALL ON FUNCTION public.rpc_preview_pr_qty_sync");
  assert.match(previewRpc, /'hq_accountant'/);
  const applyRoles = section(sql, "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync", "IF p_operator IS NULL");
  assert.doesNotMatch(applyRoles, /hq_accountant/);

  const syncUi = section(ui, "async function syncLatestQty", "async function submitForReview");
  const saveAt = syncUi.indexOf("await saveDraft()");
  assert.ok(saveAt >= 0 && saveAt < syncUi.indexOf('setBusy("sync")'));
  assert.match(ui, /setQtySyncError\(`\u540c\u6b65\u72c0\u614b\u66ab\u6642\u7121\u6cd5\u8b80\u53d6/);
  assert.doesNotMatch(ui, /if \(qtyPreviewErr\) throw/);
  assert.match(ui, /\{r\.campaign_label\} \u00b7 \{r\.sku_label\}/);
  assert.match(ui, /editable && !itemCampaignOptions\.has\(r\.id\)/);
  assert.match(ui, /if \(!itemCampaignOptions\.has\(r\.id\)\) changes\.qty_requested/);
  for (const editableField of ["unit_cost", "suggested_supplier_id", "franchise_price", "retail_price"]) {
    assert.match(ui, new RegExp(editableField));
  }
}

verify(migration, page);

const faults = [
  ["\u65b0 SKU \u53c8\u88ab\u73fe\u6709 attribution \u904e\u6ffe", migration.replace("FROM remaining r\n      LEFT JOIN current_pairs", "FROM remaining r\n      JOIN current_pairs"), page],
  ["merge \u53c8\u7528\u672a\u9a57\u8b49\u7684\u539f\u59cb ids", migration.replaceAll("ANY(v_valid_ids)", "ANY(p_pr_item_ids)"), page],
  ["sync \u9396 key \u4e0d\u540c", migration.replace("hashtext(r.campaign_id::TEXT)", "hashtext(v_tenant::TEXT || ':' || r.campaign_id::TEXT)"), page],
  ["partial \u6f0f\u642c additions", migration.replace("UPDATE public.purchase_request_store_additions", "UPDATE public.broken_store_additions"), page],
  ["sync \u524d\u6c92\u5b58\u6a94", migration, page.replace("if (!(await saveDraft())) return;", "// save removed")],
  ["preview \u5931\u6557\u53c8\u5f04\u58de\u6574\u9801", migration, page.replace("if (qtyPreviewErr) {", "if (qtyPreviewErr) throw new Error(qtyPreviewErr.message);\n        if (false) {")],
  ["linked qty \u53c8\u53ef\u624b\u6539", migration, page.replace("editable && !itemCampaignOptions.has(r.id)", "editable")],
  ["snapshot \u7528\u592a\u5f31\u7684 row lock", migration.replace("FOR UPDATE;\n\n  PERFORM 1\n    FROM public.campaign_items", "FOR NO KEY UPDATE;\n\n  PERFORM 1\n    FROM public.campaign_items"), page],
  ["#995 wrapper \u53c8\u7528\u6703\u64cb partial FK \u7684 campaign FOR UPDATE", migration.replace("FOR NO KEY UPDATE;\n\n  IF NOT FOUND THEN", "FOR UPDATE;\n\n  IF NOT FOUND THEN"), page],
  ["delete \u53c8\u5148\u9396 PR", migration.replace("PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);\n\n  SELECT status INTO v_status", "-- snapshot moved after PR lock\n\n  SELECT status INTO v_status"), page],
  ["split \u5c11 demand snapshot", migration.replace("PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);", "-- snapshot removed"), page],
  ["split \u5c11\u9396\u524d eligibility \u9810\u9a57", migration.replace("IF v_review <> 'approved' THEN", "IF FALSE THEN"), page],
  ["merge \u5c11 demand snapshot", migration.replace("PERFORM public._pr_lock_demand_snapshot(v_snapshot_pr_ids);", "-- snapshot removed"), page],
  ["merge \u5c11\u9396\u524d eligibility \u9810\u9a57", migration.replace("IF v_matched <> v_want THEN", "IF FALSE THEN"), page],
  ["split \u8aa4\u653e\u5206\u5e97\u89d2\u8272", migration.replace("'purchaser','assistant','') THEN\n    RAISE EXCEPTION '\u6b0a\u9650\u4e0d\u8db3，\u7121\u6cd5\u5efa\u7acb\u63a1\u8cfc\u55ae'", "'purchaser','assistant','store_manager','') THEN\n    RAISE EXCEPTION '\u6b0a\u9650\u4e0d\u8db3，\u7121\u6cd5\u5efa\u7acb\u63a1\u8cfc\u55ae'"), page],
];

for (const [name, brokenSql, brokenUi] of faults) {
  assert.throws(() => verify(brokenSql, brokenUi), undefined, `fault injection did not fail: ${name}`);
}

console.log(`\u2713 PR draft qty resync structural checks and ${faults.length} fault injections`);
