"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";

type PRHeader = {
  id: number;
  pr_no: string;
  source_type: string;
  source_close_date: string | null;
  status: string;
  review_status: string;
  total_amount: number;
  notes: string | null;
};

type Supplier = { id: number; name: string };

type ItemRow = {
  id: number;
  sku_id: number;
  sku_code: string;
  product_name: string;
  variant_name: string | null;
  unit_uom: string | null;
  qty_requested: number;
  unit_cost: number;
  line_subtotal: number;
  suggested_supplier_id: number | null;
  source_campaign_id: number | null;
  retail_price: number | null;     // PR snapshot，可手動覆寫
  franchise_price: number | null;  // PR snapshot，可手動覆寫
  dirty: boolean;
};

const REVIEW_LABEL: Record<string, string> = {
  approved: "已通過",
  pending_review: "待審核",
  rejected: "已退回",
};

const STATUS_LABEL: Record<string, string> = {
  draft: "草稿",
  submitted: "已送審",
  partially_ordered: "部分轉單",
  fully_ordered: "全部轉單",
  cancelled: "已取消",
};

export default function EditPurchaseRequestPage() {
  const router = useRouter();
  const params = useSearchParams();
  const idStr = params.get("id");
  const id = idStr ? Number(idStr) : null;

  const [header, setHeader] = useState<PRHeader | null>(null);
  const [items, setItems] = useState<ItemRow[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<"save" | "submit" | "split" | null>(null);
  const [destLocationId, setDestLocationId] = useState<number | null>(null);

  useEffect(() => {
    if (!id) {
      setLoading(false);
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const supabase = getSupabase();

        const [
          { data: prData, error: prErr },
          { data: itemRows, error: itemErr },
          { data: supRows },
          { data: locRow },
        ] = await Promise.all([
          supabase
            .from("purchase_requests")
            .select(
              "id, pr_no, source_type, source_close_date, status, review_status, total_amount, notes, source_location_id",
            )
            .eq("id", id)
            .maybeSingle(),
          supabase
            .from("purchase_request_items")
            .select(
              "id, sku_id, qty_requested, unit_cost, line_subtotal, suggested_supplier_id, source_campaign_id, retail_price, franchise_price",
            )
            .eq("pr_id", id)
            .order("id"),
          supabase.from("suppliers").select("id, name").eq("is_active", true).order("name"),
          supabase.from("locations").select("id").order("id").limit(1).maybeSingle(),
        ]);

        if (cancelled) return;
        if (prErr || !prData) throw new Error(prErr?.message ?? "找不到採購單");
        if (itemErr) throw new Error(itemErr.message);

        setHeader(prData as PRHeader);
        setSuppliers((supRows ?? []) as Supplier[]);
        setDestLocationId(prData.source_location_id ?? locRow?.id ?? null);

        const skuIds = (itemRows ?? []).map((r) => r.sku_id);
        if (skuIds.length === 0) {
          setItems([]);
          return;
        }

        // 一次撈 SKU + product 資訊
        const { data: skuRows } = await supabase
          .from("skus")
          .select(
            "id, sku_code, variant_name, base_unit, products!inner(name)",
          )
          .in("id", skuIds);

        const skuMap = new Map(
          (skuRows ?? []).map((s) => {
            const prod = Array.isArray(s.products) ? s.products[0] : s.products;
            return [
              s.id,
              {
                sku_code: s.sku_code as string,
                variant_name: s.variant_name as string | null,
                product_name: prod?.name as string | null,
                unit_uom: (s.base_unit as string | null) ?? null,
              },
            ];
          }),
        );

        const merged: ItemRow[] = (itemRows ?? []).map((r) => {
          const m = skuMap.get(r.sku_id);
          return {
            id: r.id,
            sku_id: r.sku_id,
            sku_code: m?.sku_code ?? "?",
            product_name: m?.product_name ?? "?",
            variant_name: m?.variant_name ?? null,
            unit_uom: m?.unit_uom ?? null,
            qty_requested: Number(r.qty_requested),
            unit_cost: Number(r.unit_cost),
            line_subtotal: Number(r.line_subtotal ?? 0),
            suggested_supplier_id: r.suggested_supplier_id,
            source_campaign_id: r.source_campaign_id,
            retail_price: r.retail_price !== null && r.retail_price !== undefined ? Number(r.retail_price) : null,
            franchise_price: r.franchise_price !== null && r.franchise_price !== undefined ? Number(r.franchise_price) : null,
            dirty: false,
          };
        });

        setItems(merged);
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [id]);

  const editable = header?.status === "draft";
  const canSplit =
    header?.status === "submitted" && header?.review_status === "approved";

  const totals = useMemo(() => {
    const subtotal = items.reduce((s, r) => s + r.qty_requested * r.unit_cost, 0);
    return { subtotal, withTax: subtotal * 1.05 };
  }, [items]);

  const unassignedCount = items.filter((r) => !r.suggested_supplier_id).length;

  function patchItem(idx: number, patch: Partial<ItemRow>) {
    setItems((cur) =>
      cur.map((r, i) => {
        if (i !== idx) return r;
        const next = { ...r, ...patch, dirty: true };
        next.line_subtotal = next.qty_requested * next.unit_cost;
        return next;
      }),
    );
  }

  function removeItem(idx: number) {
    setItems((cur) => cur.filter((_, i) => i !== idx));
  }

  async function saveDraft() {
    if (!id) return;
    setBusy("save");
    setError(null);
    try {
      const supabase = getSupabase();
      const dirtyRows = items.filter((r) => r.dirty);
      for (const r of dirtyRows) {
        const { error: err } = await supabase
          .from("purchase_request_items")
          .update({
            qty_requested: r.qty_requested,
            unit_cost: r.unit_cost,
            suggested_supplier_id: r.suggested_supplier_id,
            retail_price: r.retail_price,
            franchise_price: r.franchise_price,
          })
          .eq("id", r.id);
        if (err) throw new Error(err.message);
      }
      // notes
      if (header) {
        const { error: hErr } = await supabase
          .from("purchase_requests")
          .update({ notes: header.notes })
          .eq("id", id);
        if (hErr) throw new Error(hErr.message);
      }
      setItems((cur) => cur.map((r) => ({ ...r, dirty: false })));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function submitForReview() {
    if (!id) return;
    if (unassignedCount > 0) {
      if (!confirm(`仍有 ${unassignedCount} 行未指派供應商，送審後可審核但拆 PO 時會被擋。確定送審？`)) return;
    } else if (!confirm("確定送出審核？")) {
      return;
    }
    await saveDraft();
    setBusy("submit");
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { error: rpcErr } = await supabase.rpc("rpc_submit_pr", {
        p_pr_id: id,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      // refresh header
      const { data } = await supabase
        .from("purchase_requests")
        .select("status, review_status, total_amount")
        .eq("id", id)
        .maybeSingle();
      if (data && header) {
        setHeader({ ...header, ...(data as Partial<PRHeader>) });
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  async function splitToPos() {
    if (!id || !destLocationId) return;
    if (unassignedCount > 0) {
      setError(`有 ${unassignedCount} 行未指派供應商，無法拆 PO`);
      return;
    }
    if (!confirm("確定拆成採購訂單（PO）發給供應商？")) return;
    setBusy("split");
    setError(null);
    try {
      const supabase = getSupabase();
      const { data: userData } = await supabase.auth.getUser();
      const { data: poIds, error: rpcErr } = await supabase.rpc("rpc_split_pr_to_pos", {
        p_pr_id: id,
        p_dest_location_id: destLocationId,
        p_operator: userData.user?.id,
      });
      if (rpcErr) throw new Error(rpcErr.message);
      alert(`已產生 ${(poIds as number[]).length} 張採購訂單`);
      router.push("/purchase/orders");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }

  if (!id) {
    return (
      <div className="p-6 text-sm text-zinc-500">
        缺少 id 參數。請從 <a href="/purchase/requests" className="text-blue-600 underline">採購單列表</a> 進入。
      </div>
    );
  }

  if (loading) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
  if (!header) return <div className="p-6 text-sm text-red-600">{error ?? "找不到採購單"}</div>;

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold">
            採購單 {header.pr_no}
            <span className="ml-3 inline-block rounded bg-zinc-100 px-2 py-0.5 text-xs font-normal dark:bg-zinc-800">
              {STATUS_LABEL[header.status] ?? header.status}
            </span>
            <span
              className={`ml-2 inline-block rounded px-2 py-0.5 text-xs font-normal ${
                header.review_status === "pending_review"
                  ? "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300"
                  : header.review_status === "rejected"
                    ? "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300"
                    : "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300"
              }`}
            >
              {REVIEW_LABEL[header.review_status] ?? header.review_status}
            </span>
          </h1>
          <p className="text-sm text-zinc-500">
            結單日：{header.source_close_date ?? "—"}　·　共 {items.length} 項
            {unassignedCount > 0 && (
              <span className="ml-2 text-red-600 dark:text-red-400">⚠ {unassignedCount} 行未指派供應商</span>
            )}
          </p>
        </div>
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* Timeline stepper */}
      <Stepper status={header.status} reviewStatus={header.review_status} />

      {/* 左右兩欄：左 280px 工具/摘要/動作/備註，右側為採購清單表 */}
      <div className="grid gap-4 md:grid-cols-[280px_1fr]">
        <aside className="flex flex-col gap-4">
          {/* 摘要卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">摘要</h3>
            <dl className="space-y-2 text-sm">
              <Row label="品項數">{items.length}</Row>
              <Row label="供應商">
                {new Set(items.map((r) => r.suggested_supplier_id).filter(Boolean)).size}
              </Row>
              <Row label="未指派">
                {unassignedCount > 0 ? (
                  <span className="text-red-600 dark:text-red-400">{unassignedCount}</span>
                ) : (
                  0
                )}
              </Row>
              <div className="my-2 border-t border-zinc-200 dark:border-zinc-700" />
              <Row label="未稅小計">${totals.subtotal.toFixed(1)}</Row>
              <Row label="含稅總計">
                <span className="text-lg font-semibold text-blue-600 dark:text-blue-400">
                  ${totals.withTax.toFixed(1)}
                </span>
              </Row>
            </dl>
          </section>

          {/* 動作卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500">動作</h3>
            <div className="flex flex-col gap-2">
              <a
                href={`/purchase/requests/print?id=${id}`}
                target="_blank"
                rel="noopener"
                className="rounded-md border border-zinc-300 px-3 py-2 text-center text-sm hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                🖨 列印
              </a>
              {editable && (
                <>
                  <button
                    onClick={saveDraft}
                    disabled={busy !== null}
                    className="rounded-md border border-zinc-300 px-3 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
                  >
                    {busy === "save" ? "存檔中…" : "💾 存為草稿"}
                  </button>
                  <button
                    onClick={submitForReview}
                    disabled={busy !== null}
                    className="rounded-md bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-500 disabled:opacity-50"
                  >
                    {busy === "submit" ? "送審中…" : "📤 送出審核"}
                  </button>
                </>
              )}
              {canSplit && (
                <button
                  onClick={splitToPos}
                  disabled={busy !== null || unassignedCount > 0}
                  className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-50"
                  title={unassignedCount > 0 ? "有未指派供應商" : ""}
                >
                  {busy === "split" ? "拆 PO 中…" : "📦 拆成採購訂單"}
                </button>
              )}
              {!editable && !canSplit && (
                <p className="text-xs text-zinc-500">此採購單已 {STATUS_LABEL[header.status]}，無可用動作。</p>
              )}
            </div>
          </section>

          {/* 備註卡片 */}
          <section className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
            <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-zinc-500">備註</h3>
            <textarea
              value={header.notes ?? ""}
              onChange={(e) => setHeader({ ...header, notes: e.target.value })}
              disabled={!editable}
              rows={4}
              placeholder="(選填)…"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm disabled:opacity-50 dark:border-zinc-700 dark:bg-zinc-800"
            />
          </section>
        </aside>

        {/* 右側採購清單 */}
        <div className="flex flex-col rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
          <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-2 dark:border-zinc-800">
            <h3 className="text-sm font-semibold">📋 內部採購清單</h3>
            <span className="text-xs text-zinc-500">
              *成本=廠商給的價格，售價=ERP 商品價格
            </span>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
          <thead className="bg-zinc-50 dark:bg-zinc-900">
            <tr>
              <Th>#</Th>
              <Th>品名</Th>
              <Th>供應商</Th>
              <Th>單位</Th>
              <Th className="text-right">數量</Th>
              <Th className="text-right">成本</Th>
              <Th className="text-right">售價</Th>
              <Th className="text-right">分店價</Th>
              <Th className="text-right">小計</Th>
              <Th></Th>
            </tr>
          </thead>
          <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {items.length === 0 ? (
              <tr>
                <td colSpan={10} className="p-6 text-center text-zinc-500">
                  無品項
                </td>
              </tr>
            ) : (
              items.map((r, idx) => (
                <tr key={r.id} className="hover:bg-zinc-50 dark:hover:bg-zinc-900">
                  <Td className="text-zinc-500">{idx + 1}</Td>
                  <Td>
                    <div>{r.product_name}{r.variant_name ? `-${r.variant_name}` : ""}</div>
                    <div className="font-mono text-xs text-zinc-500">{r.sku_code}</div>
                  </Td>
                  <Td>
                    {editable ? (
                      <select
                        value={r.suggested_supplier_id ?? ""}
                        onChange={(e) =>
                          patchItem(idx, {
                            suggested_supplier_id: e.target.value ? Number(e.target.value) : null,
                          })
                        }
                        className={`rounded-md border px-2 py-1 text-sm ${
                          !r.suggested_supplier_id
                            ? "border-red-300 bg-red-50 dark:border-red-800 dark:bg-red-950"
                            : "border-zinc-300 dark:border-zinc-700"
                        } bg-white dark:bg-zinc-800`}
                      >
                        <option value="">— 未指派 —</option>
                        {suppliers.map((s) => (
                          <option key={s.id} value={s.id}>
                            {s.name}
                          </option>
                        ))}
                      </select>
                    ) : (
                      suppliers.find((s) => s.id === r.suggested_supplier_id)?.name ?? "—"
                    )}
                  </Td>
                  <Td className="text-zinc-500">{r.unit_uom ?? "—"}</Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="0.001"
                        value={r.qty_requested}
                        onChange={(e) => patchItem(idx, { qty_requested: Number(e.target.value) })}
                        className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    ) : (
                      r.qty_requested
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="0.0001"
                        value={r.unit_cost}
                        onChange={(e) => patchItem(idx, { unit_cost: Number(e.target.value) })}
                        className="w-24 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    ) : (
                      r.unit_cost.toFixed(4)
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="0.0001"
                        value={r.retail_price ?? ""}
                        onChange={(e) =>
                          patchItem(idx, {
                            retail_price: e.target.value === "" ? null : Number(e.target.value),
                          })
                        }
                        className="w-20 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    ) : r.retail_price !== null ? (
                      `$${r.retail_price.toFixed(0)}`
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td className="text-right">
                    {editable ? (
                      <input
                        type="number"
                        step="0.0001"
                        value={r.franchise_price ?? ""}
                        onChange={(e) =>
                          patchItem(idx, {
                            franchise_price: e.target.value === "" ? null : Number(e.target.value),
                          })
                        }
                        className="w-20 rounded-md border border-zinc-300 bg-white px-2 py-1 text-right text-sm dark:border-zinc-700 dark:bg-zinc-800"
                      />
                    ) : r.franchise_price !== null ? (
                      `$${r.franchise_price.toFixed(0)}`
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td className="text-right font-mono">
                    ${(r.qty_requested * r.unit_cost).toFixed(0)}
                  </Td>
                  <Td>
                    {editable && (
                      <button
                        onClick={() => removeItem(idx)}
                        className="text-xs text-red-600 hover:underline dark:text-red-400"
                      >
                        ✕
                      </button>
                    )}
                  </Td>
                </tr>
              ))
            )}
          </tbody>
        </table>
          </div>
        </div>
      </div>
    </div>
  );
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-zinc-500">{label}</dt>
      <dd className="font-mono">{children}</dd>
    </div>
  );
}

type StepState = "done" | "current" | "pending" | "rejected" | "skipped";

function Stepper({
  status,
  reviewStatus,
}: {
  status: string;
  reviewStatus: string;
}) {
  const isCancelled = status === "cancelled";
  const isRejected = reviewStatus === "rejected";

  // 5 個 step：建立 → 編輯草稿 → 送審 → 審核完成 → 拆 PO
  // 依目前 status / review_status 推算每個 step 的狀態
  const steps: { key: string; label: string; state: StepState }[] = [];

  // S1 建立 — 一定 done
  steps.push({ key: "create", label: "建立", state: "done" });

  // S2 編輯草稿
  if (status === "draft") steps.push({ key: "draft", label: "編輯草稿", state: "current" });
  else if (isCancelled) steps.push({ key: "draft", label: "編輯草稿", state: "skipped" });
  else steps.push({ key: "draft", label: "編輯草稿", state: "done" });

  // S3 送審
  if (status === "draft") steps.push({ key: "submit", label: "送出審核", state: "pending" });
  else if (status === "submitted" && reviewStatus === "pending_review")
    steps.push({ key: "submit", label: "送審中", state: "current" });
  else if (isCancelled) steps.push({ key: "submit", label: "送出審核", state: "skipped" });
  else steps.push({ key: "submit", label: "送出審核", state: "done" });

  // S4 審核完成
  if (status === "draft" || (status === "submitted" && reviewStatus === "pending_review"))
    steps.push({ key: "review", label: "審核完成", state: "pending" });
  else if (isRejected) steps.push({ key: "review", label: "已退回", state: "rejected" });
  else if (isCancelled) steps.push({ key: "review", label: "審核完成", state: "skipped" });
  else steps.push({ key: "review", label: "審核通過", state: "done" });

  // S5 拆 PO
  if (status === "fully_ordered") steps.push({ key: "split", label: "已拆 PO", state: "done" });
  else if (status === "partially_ordered")
    steps.push({ key: "split", label: "部分拆 PO", state: "current" });
  else if (isRejected || isCancelled)
    steps.push({ key: "split", label: "拆 PO", state: "skipped" });
  else steps.push({ key: "split", label: "拆成 PO", state: "pending" });

  return (
    <div className="rounded-md border border-zinc-200 bg-white p-4 dark:border-zinc-800 dark:bg-zinc-900">
      <ol className="flex items-center gap-1 sm:gap-2">
        {steps.map((s, i) => (
          <li key={s.key} className="flex flex-1 items-center">
            <div className="flex flex-col items-center">
              <StepCircle state={s.state} index={i + 1} />
              <span
                className={`mt-1.5 text-[11px] sm:text-xs ${
                  s.state === "current"
                    ? "font-semibold text-blue-600 dark:text-blue-400"
                    : s.state === "rejected"
                      ? "font-semibold text-red-600 dark:text-red-400"
                      : s.state === "done"
                        ? "text-zinc-700 dark:text-zinc-300"
                        : "text-zinc-400 dark:text-zinc-500"
                }`}
              >
                {s.label}
              </span>
            </div>
            {i < steps.length - 1 && (
              <div
                className={`mx-1 h-0.5 flex-1 sm:mx-2 ${
                  s.state === "done"
                    ? "bg-emerald-500"
                    : s.state === "rejected"
                      ? "bg-red-400"
                      : "bg-zinc-200 dark:bg-zinc-700"
                }`}
              />
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}

function StepCircle({ state, index }: { state: StepState; index: number }) {
  const base =
    "flex h-7 w-7 items-center justify-center rounded-full border-2 text-xs font-semibold sm:h-8 sm:w-8";
  if (state === "done")
    return <div className={`${base} border-emerald-500 bg-emerald-500 text-white`}>✓</div>;
  if (state === "current")
    return (
      <div
        className={`${base} border-blue-500 bg-blue-50 text-blue-600 ring-2 ring-blue-200 dark:bg-blue-950 dark:text-blue-300 dark:ring-blue-900`}
      >
        {index}
      </div>
    );
  if (state === "rejected")
    return <div className={`${base} border-red-500 bg-red-500 text-white`}>✕</div>;
  // pending / skipped
  return (
    <div
      className={`${base} border-zinc-300 bg-white text-zinc-400 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-500`}
    >
      {index}
    </div>
  );
}

function Th({ children, className = "" }: { children?: React.ReactNode; className?: string }) {
  return (
    <th
      className={`px-3 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}
    >
      {children}
    </th>
  );
}
function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-3 py-2 ${className}`}>{children}</td>;
}
