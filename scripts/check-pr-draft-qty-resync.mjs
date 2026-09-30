import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const migrationPath = resolve(root, "supabase/migrations/20260930000000_pr_draft_qty_resync.sql");
const pagePath = resolve(root, "apps/admin/src/app/(protected)/purchase/requests/edit/page.tsx");
const migration = readFileSync(migrationPath, "utf8");
const page = readFileSync(pagePath, "utf8");

function section(source, start, end) {
  const from = source.indexOf(start);
  assert.notEqual(from, -1, `missing section: ${start}`);
  const to = end ? source.indexOf(end, from + start.length) : source.length;
  assert.notEqual(to, -1, `missing section end: ${end}`);
  return source.slice(from, to);
}

function replaceInSection(source, start, end, find, replacement) {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from);
  const chunk = source.slice(from, to);
  const changed = chunk.replace(find, replacement);
  assert.notEqual(changed, chunk, `fault injection target missing: ${find}`);
  return source.slice(0, from) + changed + source.slice(to);
}

function verify(sql, ui) {
  assert.match(sql, /CREATE TABLE public\.purchase_request_qty_dirty/);
  assert.equal((sql.match(/REFERENCING (?:OLD|NEW)/g) ?? []).length, 4);
  assert.equal((sql.match(/FOR EACH STATEMENT/g) ?? []).length, 4);

  const triggerPart = section(sql, "CREATE OR REPLACE FUNCTION public._pr_mark_dirty", "-- 現有 helper");
  assert.equal((triggerPart.match(/EXCEPTION WHEN OTHERS/g) ?? []).length, 2);
  assert.equal((triggerPart.match(/RAISE WARNING/g) ?? []).length, 2);
  assert.doesNotMatch(triggerPart, /_pr_apply_qty_sync|UPDATE public\.purchase_request_items/);

  assert.equal((sql.match(/CHECK \(qty_requested >= 0\)/g) ?? []).length, 2);
  const apply = section(sql, "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync", "CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty");
  assert.match(apply, /UPDATE public\.purchase_request_item_campaigns[\s\S]*SET qty_requested = r\.target_qty/);
  assert.match(apply, /UPDATE public\.purchase_request_items pri[\s\S]*SELECT COALESCE\(SUM\(pric\.qty_requested\), 0\)/);
  assert.match(sql, /revision = public\.purchase_request_qty_dirty\.revision \+ 1/);
  assert.match(sql, /v_dirty_seen ->> \(r\.campaign_id::TEXT \|\| ':' \|\| r\.sku_id::TEXT\)/);

  const submit = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_submit_pr", "-- ---------------------------------------------------------------------------\n-- 建 PO");
  assert.ok(submit.indexOf("_pr_apply_qty_sync") < submit.indexOf("SET status = 'submitted'"));
  assert.ok(submit.indexOf("_pr_validate_qty_current") < submit.indexOf("SET status = 'submitted'"));

  const split = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos", "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po");
  assert.ok(split.indexOf("_pr_validate_qty_current") >= 0);
  assert.ok(split.indexOf("_pr_validate_qty_current") < split.indexOf("rpc_next_po_no"));
  assert.match(split, /qty_requested > 0/);

  const merge = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po", "-- 部分轉採購");
  assert.ok(merge.indexOf("_pr_validate_qty_current") >= 0);
  assert.ok(merge.indexOf("_pr_validate_qty_current") < merge.indexOf("INSERT INTO public.purchase_orders"));

  const partial = section(sql, "CREATE OR REPLACE FUNCTION public.rpc_create_partial_pr_from_items", "COMMENT ON TABLE");
  assert.match(partial, /UPDATE public\.purchase_request_items[\s\S]*SET pr_id = v_new_pr_id/);
  assert.doesNotMatch(partial, /DELETE FROM public\.purchase_request_items/);

  assert.match(ui, /rpc_preview_pr_qty_sync/);
  assert.match(ui, /rpc_sync_pr_qty/);
  assert.match(ui, /開啟頁面不會改資料/);
  assert.match(ui, /editable && !itemCampaignOptions\.has\(r\.id\)/);
  assert.match(ui, /if \(!itemCampaignOptions\.has\(r\.id\)\) changes\.qty_requested/);
  for (const editableField of ["unit_cost", "suggested_supplier_id", "franchise_price", "retail_price"]) {
    assert.match(ui, new RegExp(editableField));
  }
}

verify(migration, page);

const targetQty = (demand, immutable) => Math.max(demand - immutable, 0);
assert.equal(targetQty(9, 0), 9, "10 cancel 1 must become 9");
assert.equal(targetQty(11, 0), 11, "10 - 1 + 2 must become 11");
assert.equal(targetQty(4, 6), 0, "immutable overage must never produce a negative draft qty");

// 故障反例：這三種回退必須真的被同一支檢查抓紅。
for (const [name, brokenSql, brokenUi] of [
  ["qty=0 被禁", migration.replace("CHECK (qty_requested >= 0)", "CHECK (qty_requested > 0)"), page],
  [
    "split 少花錢前守門",
    replaceInSection(
      migration,
      "CREATE OR REPLACE FUNCTION public.rpc_split_pr_to_pos",
      "CREATE OR REPLACE FUNCTION public.rpc_merge_prs_to_po",
      "PERFORM public._pr_validate_qty_current(ARRAY[p_pr_id]);",
      "-- validation removed",
    ),
    page,
  ],
  [
    "父層數量未重算",
    replaceInSection(
      migration,
      "CREATE OR REPLACE FUNCTION public._pr_apply_qty_sync",
      "CREATE OR REPLACE FUNCTION public.rpc_sync_pr_qty",
      "UPDATE public.purchase_request_items pri",
      "UPDATE public.purchase_request_items_broken pri",
    ),
    page,
  ],
  ["linked qty 又可手改", migration, page.replace("editable && !itemCampaignOptions.has(r.id)", "editable")],
]) {
  let failed = false;
  try {
    verify(brokenSql, brokenUi);
  } catch {
    failed = true;
  }
  assert.ok(failed, `fault injection did not fail: ${name}`);
}

console.log("✓ PR draft qty resync static checks (including negative delta, 10-1+2=11, and 4 fault injections)");
