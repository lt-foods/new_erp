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

  const syncKeyLock = section(sql, "CREATE OR REPLACE FUNCTION public._pr_lock_qty_sync_keys", "REVOKE ALL ON FUNCTION public._pr_lock_qty_sync_keys");
  const advisory = "hashtext(r.campaign_id::TEXT),\n      hashtext(r.sku_id::TEXT)";
  assert.ok(syncKeyLock.includes(advisory));
  assert.match(syncKeyLock, /FROM public\.group_buy_campaigns gbc[\s\S]*ORDER BY gbc\.id[\s\S]*FOR NO KEY UPDATE/);
  assert.ok(syncKeyLock.indexOf("FROM public.group_buy_campaigns") < syncKeyLock.indexOf("pg_advisory_xact_lock"));
  assert.doesNotMatch(syncKeyLock, /v_tenant::TEXT \|\| ':' \|\| r\.campaign_id/);

  const apply = section(sql, "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync", "CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty");
  assert.ok(apply.indexOf("_pr_lock_qty_sync_keys(p_pr_id)") < apply.indexOf("FOR UPDATE;"), "advisory must precede PR/item row locks");
  assert.match(apply, /r\.pr_item_id IS NULL AND r\.delta_qty <> 0/);
  assert.match(apply, /INSERT INTO public\.purchase_request_qty_sync_log/);
  assert.match(apply, /UPDATE public\.purchase_request_item_campaigns[\s\S]*SET qty_requested = r\.target_qty/);
  assert.match(apply, /UPDATE public\.purchase_request_items pri[\s\S]*SELECT COALESCE\(SUM\(pric\.qty_requested\), 0\)/);

  const storeAddWrapper = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_add_pr_store_demands", "CREATE OR REPLACE FUNCTION public._pr_lock_qty_sync_keys");
  assert.match(storeAddWrapper, /hashtext\(p_campaign_id::TEXT\),\s+hashtext\(v_sku_id::TEXT\)/);
  assert.match(storeAddWrapper, /FROM public\.group_buy_campaigns[\s\S]*FOR NO KEY UPDATE/);
  assert.doesNotMatch(storeAddWrapper, /FROM public\.group_buy_campaigns[\s\S]*FOR UPDATE/);
  assert.ok(storeAddWrapper.indexOf("FROM public.group_buy_campaigns") < storeAddWrapper.indexOf("pg_advisory_xact_lock"));
  assert.ok(storeAddWrapper.indexOf("pg_advisory_xact_lock") < storeAddWrapper.indexOf("_rpc_add_pr_store_demands_20260930_inner("));
  assert.doesNotMatch(storeAddWrapper, /RAISE EXCEPTION|v_role|auth\.uid/);
  assert.match(sql, /ALTER FUNCTION public\.rpc_add_pr_store_demands\([\s\S]*RENAME TO _rpc_add_pr_store_demands_20260930_inner/);

  const validation = section(sql, "CREATE OR REPLACE FUNCTION public._pr_validate_qty_current", "REVOKE ALL ON FUNCTION public._pr_validate_qty_current");
  assert.match(validation, /purchase_request_campaigns/);
  assert.match(validation, /_pr_campaign_sku_remaining_rows\(v_campaign_ids\)/);
  assert.doesNotMatch(validation, /JOIN wanted/);

  const campaignIds = section(sql, "CREATE OR REPLACE FUNCTION public._pr_campaign_ids", "REVOKE ALL ON FUNCTION public._pr_campaign_ids");
  for (const source of ["purchase_request_campaigns", "purchase_request_item_campaigns", "source_campaign_id"]) {
    assert.match(campaignIds, new RegExp(source));
  }
  assert.match(campaignIds, /ORDER BY x\.campaign_id/);

  const snapshot = section(sql, "CREATE OR REPLACE FUNCTION public._pr_lock_demand_snapshot", "REVOKE ALL ON FUNCTION public._pr_lock_demand_snapshot");
  const lockTargets = ["group_buy_campaigns", "campaign_items", "customer_orders", "customer_order_items"];
  let lastLock = -1;
  for (const target of lockTargets) {
    const at = snapshot.indexOf(`public.${target}`);
    assert.ok(at > lastLock, `demand lock order broken at ${target}`);
    lastLock = at;
  }
  assert.equal((snapshot.match(/FOR UPDATE/g) ?? []).length, 4);
  assert.match(snapshot, /v_campaign_ids := public\._pr_campaign_ids\(p_pr_ids\)/);
  assert.match(snapshot, /ORDER BY gbc\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY ci\.campaign_id, ci\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY co\.campaign_id, co\.id[\s\S]*FOR UPDATE/);
  assert.match(snapshot, /ORDER BY co\.campaign_id, co\.id, coi\.id[\s\S]*FOR UPDATE OF coi/);

  const deleteCampaignIds = section(sql, "CREATE OR REPLACE FUNCTION public._pr_delete_campaign_ids", "REVOKE ALL ON FUNCTION public._pr_delete_campaign_ids");
  for (const source of ["purchase_request_campaigns", "purchase_request_item_campaigns", "source_campaign_id"]) {
    assert.match(deleteCampaignIds, new RegExp(source));
  }
  assert.match(deleteCampaignIds, /ORDER BY campaign_id/);

  const deletePr = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_delete_pr", "COMMENT ON FUNCTION public.rpc_delete_pr");
  const deleteCampaignLock = "FROM public.group_buy_campaigns gbc";
  const deleteReads = [...deletePr.matchAll(/public\._pr_delete_campaign_ids\(p_pr_id\)/g)].map((m) => m.index);
  const deletePrLock = deletePr.indexOf("FOR UPDATE;", deletePr.indexOf("FROM public.purchase_requests"));
  const deleteRecheck = deletePr.indexOf("v_current_campaign_ids IS DISTINCT FROM v_campaign_ids");
  const deleteDelegate = deletePr.lastIndexOf("_rpc_delete_pr_20260930_inner(");
  assert.doesNotMatch(deletePr, /_pr_lock_demand_snapshot/);
  assert.equal(deleteReads.length, 2);
  assert.ok(deleteReads[0] < deletePr.indexOf(deleteCampaignLock));
  assert.ok(deletePr.indexOf(deleteCampaignLock) < deletePr.indexOf("FROM public.purchase_requests"));
  assert.ok(deletePrLock >= 0 && deletePrLock < deleteReads[1]);
  assert.ok(deleteReads[1] < deleteRecheck && deleteRecheck < deleteDelegate);
  assert.match(deletePr, /ORDER BY gbc\.id\s+FOR NO KEY UPDATE/);
  assert.match(deletePr, /v_current_campaign_ids\s+BIGINT\[\]/);
  assert.match(deletePr, /PERFORM public\._rpc_delete_pr_20260930_inner\(p_pr_id, p_operator\)/);
  assert.doesNotMatch(deletePr, /v_role|v_status|UPDATE group_buy_campaigns|DELETE FROM purchase_requests/);
  assert.match(sql, /ALTER FUNCTION public\.rpc_delete_pr\(BIGINT, UUID\)\s+RENAME TO _rpc_delete_pr_20260930_inner/);

  const submit = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_submit_pr", "-- ---------------------------------------------------------------------------\n-- \u5efa PO");
  const submitDelegate = submit.lastIndexOf("_rpc_submit_pr_20260930_inner(");
  const submitKeyLock = submit.indexOf("_pr_lock_qty_sync_keys(p_pr_id)");
  const submitPrLock = submit.indexOf("FOR UPDATE;");
  const submitEligibility = submit.indexOf("IF NOT FOUND OR v_status <> 'draft' THEN");
  assert.ok(submitKeyLock >= 0 && submitKeyLock < submitPrLock);
  assert.ok(submitPrLock < submitEligibility && submitEligibility < submit.indexOf("_pr_apply_qty_sync"));
  assert.ok(submit.indexOf("_pr_apply_qty_sync") < submitDelegate);
  assert.ok(submit.indexOf("_pr_validate_qty_current") < submitDelegate);
  assert.match(submit, /IF NOT FOUND OR v_status <> 'draft' THEN[\s\S]*_rpc_submit_pr_20260930_inner/);
  assert.doesNotMatch(submit, /v_role|auth\.uid|tenant_id\s*=|SET status = 'submitted'|purchase_approval_thresholds/);
  assert.match(sql, /ALTER FUNCTION public\.rpc_submit_pr\(BIGINT, UUID\)\s+RENAME TO _rpc_submit_pr_20260930_inner/);

  const splitInner = section(sql, "CREATE OR REPLACE FUNCTION public._rpc_split_pr_to_pos_20260930_inner", "CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos");
  assert.equal((splitInner.match(/qty_requested > 0/g) ?? []).length, 4);
  assert.match(splitInner, /FROM purchase_request_items\s+WHERE pr_id = p_pr_id\s+AND qty_requested > 0\s+AND suggested_supplier_id IS NULL/);
  assert.match(splitInner, /SELECT DISTINCT suggested_supplier_id AS supplier_id[\s\S]*WHERE pr_id = p_pr_id\s+AND qty_requested > 0/);
  assert.match(splitInner, /FROM purchase_request_items pri[\s\S]*WHERE pri\.pr_id = p_pr_id\s+AND pri\.qty_requested > 0\s+AND pri\.suggested_supplier_id/);
  assert.match(splitInner, /UPDATE purchase_request_items pri[\s\S]*FROM inserted i\s+WHERE pri\.pr_id = p_pr_id\s+AND pri\.qty_requested > 0\s+AND pri\.suggested_supplier_id/);

  const split = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos", "ALTER FUNCTION public.rpc_merge_prs_to_po");
  const splitSnapshotCall = "PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);";
  const splitDelegate = split.lastIndexOf("_rpc_split_pr_to_pos_20260930_inner(");
  const splitPrLock = split.indexOf("FOR UPDATE;");
  const splitCampaignRecheck = split.indexOf("v_locked_campaign_ids IS DISTINCT FROM v_campaign_ids");
  const splitEligibility = split.indexOf("IF v_review <> 'approved'");
  assert.match(split, /v_review <> 'approved'/);
  assert.match(split, /v_status IN \('fully_ordered','partially_ordered','cancelled'\)/);
  assert.doesNotMatch(split, /v_status <> 'submitted'|v_role|auth\.uid|v_tenant|tenant_id\s*=|INSERT INTO public\.purchase_orders|rpc_next_po_no/);
  assert.match(split, /RETURN public\._rpc_split_pr_to_pos_20260930_inner/);
  assert.ok(split.indexOf("v_campaign_ids := public._pr_campaign_ids") < split.indexOf(splitSnapshotCall));
  assert.ok(split.indexOf(splitSnapshotCall) >= 0 && split.indexOf(splitSnapshotCall) < splitPrLock);
  assert.ok(splitPrLock < splitCampaignRecheck && splitCampaignRecheck < splitEligibility);
  assert.ok(splitEligibility < split.indexOf("_pr_validate_qty_current"));
  assert.ok(split.indexOf("_pr_validate_qty_current") < splitDelegate);
  assert.match(sql, /ALTER FUNCTION public\.rpc_split_pr_to_pos\(BIGINT, BIGINT, UUID\)\s+RENAME TO _rpc_split_pr_to_pos_20260930_inner/);

  const merge = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po", "-- \u90e8\u5206\u8f49\u63a1\u8cfc");
  const mergeSnapshotCall = "PERFORM public._pr_lock_demand_snapshot(v_snapshot_pr_ids);";
  const mergeDelegate = merge.lastIndexOf("_rpc_merge_prs_to_po_20260930_inner(");
  assert.ok(merge.indexOf(mergeSnapshotCall) >= 0 && merge.indexOf(mergeSnapshotCall) < merge.indexOf("FOR UPDATE OF pr, pri"));
  assert.ok(merge.indexOf(mergeSnapshotCall) < merge.indexOf("_pr_validate_qty_current"));
  assert.ok(merge.indexOf("_pr_validate_qty_current") < mergeDelegate);
  assert.equal((merge.match(/qty_requested > 0/g) ?? []).length, 3);
  assert.match(merge, /pri\.qty_requested > 0/);
  assert.match(merge, /v_locked_item_ids IS DISTINCT FROM v_snapshot_item_ids/);
  assert.match(merge, /v_locked_pr_ids IS DISTINCT FROM v_snapshot_pr_ids/);
  assert.match(merge, /v_locked_campaign_ids IS DISTINCT FROM v_snapshot_campaign_ids/);
  const mergeEmptyGuard = merge.indexOf("COALESCE(array_length(v_locked_item_ids, 1), 0) = 0");
  assert.ok(mergeEmptyGuard > merge.indexOf("v_locked_campaign_ids IS DISTINCT FROM v_snapshot_campaign_ids"));
  assert.ok(mergeEmptyGuard < merge.indexOf("_pr_validate_qty_current"));
  assert.match(merge, /沒有正數量的請購品項可建立採購單/);
  assert.ok(merge.indexOf("v_snapshot_campaign_ids := public._pr_campaign_ids") < merge.indexOf(mergeSnapshotCall));
  assert.ok(merge.indexOf("v_locked_campaign_ids := public._pr_campaign_ids") > merge.indexOf("FOR UPDATE OF pr, pri"));
  assert.match(merge, /v_po_id := public\._rpc_merge_prs_to_po_20260930_inner\([\s\S]*v_locked_item_ids/);
  assert.match(merge, /pri\.qty_requested > 0[\s\S]*pri\.po_item_id IS NULL/);
  assert.doesNotMatch(merge, /v_role|auth\.uid|_current_tenant_id|pr\.status|review_status|suggested_supplier_id|p_tenant_id IS DISTINCT|INSERT INTO public\.purchase_orders/);
  assert.match(sql, /ALTER FUNCTION public\.rpc_merge_prs_to_po\(UUID, BIGINT\[\], BIGINT, BIGINT, TEXT, UUID\)\s+RENAME TO _rpc_merge_prs_to_po_20260930_inner/);

  const partial = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_create_partial_pr_from_items", "COMMENT ON TABLE");
  assert.match(partial, /UPDATE public\.purchase_request_items[\s\S]*SET pr_id = v_new_pr_id/);
  assert.match(partial, /UPDATE public\.purchase_request_store_additions[\s\S]*SET pr_id = v_new_pr_id/);
  assert.doesNotMatch(partial, /DELETE FROM public\.purchase_request_items/);
  assert.match(partial, /v_role NOT IN \('owner','admin','hq_manager',''\)/);
  assert.match(partial, /IF v_src\.status <> 'draft'/);
  assert.match(partial, /IF p_operator IS NULL THEN\s+RAISE EXCEPTION '缺少操作人員 id，無法建立新請購單'/);
  assert.doesNotMatch(partial, /p_operator := auth\.uid|p_operator <> auth\.uid/);
  assert.match(partial, /來自補貨申請，請從補貨流程處理，不可部分轉採購/);
  assert.match(partial, /已拆成採購單\(PO\)，不可搬移。請改在採購單端處理。/);
  const partialCampaignLock = partial.indexOf("FROM public.group_buy_campaigns gbc");
  const partialPrLock = partial.indexOf("FOR UPDATE;", partial.indexOf("SELECT pr.pr_no"));
  const partialCampaignBlock = partial.slice(partialCampaignLock, partial.indexOf("SELECT pr.pr_no"));
  assert.ok(partialCampaignLock >= 0 && partialCampaignLock < partialPrLock);
  assert.match(partialCampaignBlock, /ORDER BY gbc\.id\s+FOR NO KEY UPDATE/);
  assert.doesNotMatch(partialCampaignBlock, /FOR UPDATE/);

  const previewRpc = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_preview_pr_qty_sync", "REVOKE ALL ON FUNCTION public.rpc_preview_pr_qty_sync");
  assert.match(previewRpc, /'hq_accountant'/);
  const syncRpc = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty", "REVOKE ALL ON FUNCTION public.rpc_sync_pr_qty");
  assert.match(syncRpc, /v_role NOT IN \('owner','admin','hq_manager','purchaser','assistant',''\)/);
  assert.doesNotMatch(syncRpc, /hq_accountant/);

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

const deleteRecheckBlock = "  IF v_current_campaign_ids IS DISTINCT FROM v_campaign_ids THEN\n    RAISE EXCEPTION '請購單的關聯團剛剛有變動，請重試刪除';\n  END IF;\n\n";
const deleteDelegateCall = "  PERFORM public._rpc_delete_pr_20260930_inner(p_pr_id, p_operator);\n";
const deleteRecheckAfterDelegate = migration
  .replace(deleteRecheckBlock, "")
  .replace(deleteDelegateCall, `${deleteDelegateCall}${deleteRecheckBlock}`);

const faults = [
  ["\u65b0 SKU \u53c8\u88ab\u73fe\u6709 attribution \u904e\u6ffe", migration.replace("FROM remaining r\n      LEFT JOIN current_pairs", "FROM remaining r\n      JOIN current_pairs"), page],
  ["add wrapper \u6c92\u4ea4\u56de\u4e3b\u7dda inner", migration.replace("RETURN public._rpc_add_pr_store_demands_20260930_inner(", "RETURN public.broken_add_inner("), page],
  ["delete wrapper \u6c92\u4ea4\u56de\u4e3b\u7dda inner", migration.replaceAll("public._rpc_delete_pr_20260930_inner(p_pr_id, p_operator)", "public.broken_delete_inner(p_pr_id, p_operator)"), page],
  ["submit wrapper \u6c92\u4ea4\u56de\u4e3b\u7dda inner", migration.replaceAll("public._rpc_submit_pr_20260930_inner(p_pr_id, p_operator)", "public.broken_submit_inner(p_pr_id, p_operator)"), page],
  ["submit eligibility \u53c8\u5728 PR \u9396\u524d\u5224\u65b7", migration.replace("WHERE id = p_pr_id\n   FOR UPDATE;\n\n  IF NOT FOUND OR v_status <> 'draft'", "WHERE id = p_pr_id;\n\n  IF NOT FOUND OR v_status <> 'draft'"), page],
  ["split wrapper \u53c8\u9650 submitted-only", migration.replaceAll("v_status IN ('fully_ordered','partially_ordered','cancelled')", "v_status <> 'submitted'"), page],
  ["split private inner \u53c8\u628a qty0 \u9001\u9032 PO", migration.replace("     AND qty_requested > 0\n     AND suggested_supplier_id IS NULL", "     AND suggested_supplier_id IS NULL"), page],
  ["split po_item \u56de\u5beb\u53c8\u932f\u7d81\u540c SKU qty0", migration.replace("     WHERE pri.pr_id = p_pr_id\n       AND pri.qty_requested > 0\n       AND pri.suggested_supplier_id", "     WHERE pri.pr_id = p_pr_id\n       AND pri.suggested_supplier_id"), page],
  ["merge wrapper \u53c8\u628a qty0 ids \u4ea4\u56de inner", migration.replace("p_tenant_id, v_locked_item_ids, p_supplier_id", "p_tenant_id, p_pr_item_ids, p_supplier_id"), page],
  ["merge 全零又交舊 inner 建空 PO", migration.replace("IF COALESCE(array_length(v_locked_item_ids, 1), 0) = 0 THEN", "IF FALSE THEN"), page],
  ["partial \u53c8\u6539 operator \u5951\u7d04", migration.replace("RAISE EXCEPTION '\u7f3a\u5c11\u64cd\u4f5c\u4eba\u54e1 id，\u7121\u6cd5\u5efa\u7acb\u65b0\u8acb\u8cfc\u55ae';", "p_operator := auth.uid();"), page],
  ["partial \u53c8先鎖 PR 後鎖 campaign", migration.replace("FOR NO KEY UPDATE;\n\n  SELECT pr.pr_no", "FOR UPDATE;\n\n  SELECT pr.pr_no"), page],
  ["sync \u9396 key \u4e0d\u540c", migration.replace("hashtext(r.campaign_id::TEXT)", "hashtext(v_tenant::TEXT || ':' || r.campaign_id::TEXT)"), page],
  ["sync/submit \u53c8\u8b8a advisory \u5148\u65bc campaign", migration.replace("ORDER BY gbc.id\n   FOR NO KEY UPDATE;\n\n  FOR r IN", "ORDER BY gbc.id;\n\n  FOR r IN"), page],
  ["partial \u6f0f\u642c additions", migration.replace("UPDATE public.purchase_request_store_additions", "UPDATE public.broken_store_additions"), page],
  ["sync \u524d\u6c92\u5b58\u6a94", migration, page.replace("if (!(await saveDraft())) return;", "// save removed")],
  ["preview \u5931\u6557\u53c8\u5f04\u58de\u6574\u9801", migration, page.replace("if (qtyPreviewErr) {", "if (qtyPreviewErr) throw new Error(qtyPreviewErr.message);\n        if (false) {")],
  ["linked qty \u53c8\u53ef\u624b\u6539", migration, page.replace("editable && !itemCampaignOptions.has(r.id)", "editable")],
  ["snapshot \u7528\u592a\u5f31\u7684 row lock", migration.replace("FOR UPDATE;\n\n  PERFORM 1\n    FROM public.campaign_items", "FOR NO KEY UPDATE;\n\n  PERFORM 1\n    FROM public.campaign_items"), page],
  ["#995 wrapper \u53c8\u7528\u6703\u64cb partial FK \u7684 campaign FOR UPDATE", migration.replace("FOR NO KEY UPDATE;\n\n    IF FOUND THEN", "FOR UPDATE;\n\n    IF FOUND THEN"), page],
  ["delete \u53c8\u7528\u6703\u64cb partial FK \u7684 campaign FOR UPDATE", migration.replace("ORDER BY gbc.id\n   FOR NO KEY UPDATE;\n\n  PERFORM 1", "ORDER BY gbc.id\n   FOR UPDATE;\n\n  PERFORM 1"), page],
  ["delete \u6f0f\u6389 PR \u9396\u5f8c\u91cd\u7b97", migration.replace("v_current_campaign_ids := public._pr_delete_campaign_ids(p_pr_id);", "-- locked recheck removed"), page],
  ["delete \u628a\u95dc\u806f\u5718\u6bd4\u8f03\u653e\u5230 inner \u4e4b\u5f8c", deleteRecheckAfterDelegate, page],
  ["split \u5c11 demand snapshot", migration.replace("PERFORM public._pr_lock_demand_snapshot(ARRAY[p_pr_id]);", "-- snapshot removed"), page],
  ["split eligibility \u53c8\u5728 PR \u9396\u524d\u5224\u65b7", migration.replaceAll("   FOR UPDATE;\n\n  IF NOT FOUND THEN", ";\n\n  IF NOT FOUND THEN"), page],
  ["split \u5c11\u9396\u5f8c campaign \u96c6\u5408\u91cd\u9a57", migration.replace("v_locked_campaign_ids IS DISTINCT FROM v_campaign_ids", "FALSE"), page],
  ["merge \u5c11 demand snapshot", migration.replace("PERFORM public._pr_lock_demand_snapshot(v_snapshot_pr_ids);", "-- snapshot removed"), page],
  ["merge \u5c11\u9396\u5f8c PR \u96c6合重驗", migration.replace("v_locked_pr_ids IS DISTINCT FROM v_snapshot_pr_ids", "FALSE"), page],
  ["merge \u5c11\u9396\u5f8c campaign \u96c6\u5408\u91cd\u9a57", migration.replace("v_locked_campaign_ids IS DISTINCT FROM v_snapshot_campaign_ids", "FALSE"), page],
  ["merge \u4e0d\u518d\u904e\u6ffe qty0", migration.replaceAll("              AND pri.qty_requested > 0", "              AND TRUE"), page],
];

for (const [name, brokenSql, brokenUi] of faults) {
  assert.throws(() => verify(brokenSql, brokenUi), undefined, `fault injection did not fail: ${name}`);
}

console.log(`\u2713 PR draft qty resync structural checks and ${faults.length} fault injections`);
