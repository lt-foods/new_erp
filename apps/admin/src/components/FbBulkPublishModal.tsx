"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { cleanCampaignText } from "@/lib/text";

const PRODUCTS_BUCKET = "products";
const MEMBER_APP_URL = (process.env.NEXT_PUBLIC_MEMBER_APP_URL ?? "https://new-erp-admin.vercel.app").replace(/\/$/, "");

type FbPage = {
  id: number;
  page_id: string;
  name: string;
  sort_order: number;
};

type CampaignDraft = {
  id: number;
  name: string;
  description: string | null;
  cover_image_url: string | null;
  imageUrls: string[];
  message: string;
};

type PairStatus = "pending" | "running" | "success" | "failed";

type PairResult = {
  campaignId: number;
  campaignName: string;
  fbPageId: number;
  pageName: string;
  status: PairStatus;
  permalink?: string | null;
  error?: string;
};

type Props = {
  open: boolean;
  campaignIds: number[];
  onClose: () => void;
  onCompleted?: () => void;
};

function resolveImagePath(p: string): string {
  if (/^https?:\/\//i.test(p)) return p;
  return getSupabase().storage.from(PRODUCTS_BUCKET).getPublicUrl(p).data.publicUrl;
}

function buildDefaultMessage(name: string, description: string | null, campaignId: number): string {
  const link = `${MEMBER_APP_URL}/shop/c/${campaignId}`;
  const parts: string[] = [];
  parts.push(`【開團】${cleanCampaignText(name)}`);
  if (description) {
    const plain = cleanCampaignText(
      description
        .replace(/<br\s*\/?>/gi, "\n")
        .replace(/<\/p>/gi, "\n")
        .replace(/<[^>]+>/g, ""),
    );
    if (plain) parts.push(plain);
  }
  parts.push(`\n👉 立即下單：${link}`);
  return parts.join("\n\n");
}

export default function FbBulkPublishModal({ open, campaignIds, onClose, onCompleted }: Props) {
  const [loading, setLoading] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaigns, setCampaigns] = useState<CampaignDraft[]>([]);
  const [pages, setPages] = useState<FbPage[]>([]);
  const [selectedPageIds, setSelectedPageIds] = useState<Set<number>>(new Set());
  const [results, setResults] = useState<PairResult[] | null>(null);

  useEffect(() => {
    if (!open || campaignIds.length === 0) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      setResults(null);
      try {
        const sb = getSupabase();
        const [campRes, pagesRes] = await Promise.all([
          sb
            .from("group_buy_campaigns")
            .select(
              "id, name, description, cover_image_url, campaign_items(sort_order, sku:skus(product:products(images)))",
            )
            .in("id", campaignIds),
          sb
            .from("fb_pages")
            .select("id, page_id, name, sort_order")
            .eq("is_active", true)
            .order("sort_order", { ascending: true }),
        ]);
        if (cancelled) return;
        if (campRes.error) throw campRes.error;
        if (pagesRes.error) throw pagesRes.error;

        const camps = (campRes.data ?? []) as Array<{
          id: number;
          name: string;
          description: string | null;
          cover_image_url: string | null;
          campaign_items?: Array<{
            sort_order: number;
            sku?: { product?: { images?: string[] } | null } | null;
          }>;
        }>;

        const drafts: CampaignDraft[] = camps
          .sort((a, b) => campaignIds.indexOf(a.id) - campaignIds.indexOf(b.id))
          .map((c) => {
            const imageSet = new Set<string>();
            if (c.cover_image_url) imageSet.add(resolveImagePath(c.cover_image_url));
            const items = (c.campaign_items ?? []).slice().sort((a, b) => a.sort_order - b.sort_order);
            for (const it of items) {
              const imgs = it.sku?.product?.images ?? [];
              for (const p of imgs) if (typeof p === "string" && p) imageSet.add(resolveImagePath(p));
            }
            return {
              id: c.id,
              name: c.name,
              description: c.description ?? null,
              cover_image_url: c.cover_image_url ?? null,
              imageUrls: [...imageSet],
              message: buildDefaultMessage(c.name, c.description ?? null, c.id),
            };
          });

        setCampaigns(drafts);
        setPages(pagesRes.data ?? []);
        setSelectedPageIds(new Set());
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, campaignIds]);

  const togglePage = (id: number) => {
    setSelectedPageIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const totalPairs = campaigns.length * selectedPageIds.size;

  async function handleSubmit() {
    if (campaigns.length === 0 || selectedPageIds.size === 0) return;

    const pageList = pages.filter((p) => selectedPageIds.has(p.id));
    const initial: PairResult[] = [];
    for (const c of campaigns) {
      for (const p of pageList) {
        initial.push({
          campaignId: c.id,
          campaignName: c.name,
          fbPageId: p.id,
          pageName: p.name,
          status: "pending",
        });
      }
    }
    setResults(initial);
    setSubmitting(true);
    setError(null);

    try {
      const sb = getSupabase();
      const { data: { session } } = await sb.auth.getSession();
      if (!session) throw new Error("尚未登入");

      for (const c of campaigns) {
        // mark this campaign's pairs as running
        setResults((prev) => prev?.map((r) =>
          r.campaignId === c.id ? { ...r, status: "running" } : r
        ) ?? null);

        try {
          const resp = await fetch(
            `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/campaign-publish-facebook`,
            {
              method: "POST",
              headers: {
                "Content-Type": "application/json",
                Authorization: `Bearer ${session.access_token}`,
              },
              body: JSON.stringify({
                campaign_id: c.id,
                fb_page_ids: [...selectedPageIds],
                message: c.message,
                image_urls: c.imageUrls,
              }),
            },
          );
          const data = await resp.json();
          if (!resp.ok) throw new Error(data?.error || data?.detail || `HTTP ${resp.status}`);
          const perPage = new Map<number, { status: "success" | "failed"; permalink?: string | null; error?: string }>();
          for (const r of (data.results ?? []) as Array<{
            fb_page_id: number;
            status: "success" | "failed";
            permalink?: string | null;
            error?: string;
          }>) {
            perPage.set(r.fb_page_id, {
              status: r.status,
              permalink: r.permalink,
              error: r.error,
            });
          }
          setResults((prev) => prev?.map((r) => {
            if (r.campaignId !== c.id) return r;
            const got = perPage.get(r.fbPageId);
            if (!got) return { ...r, status: "failed", error: "edge function 未回此粉絲團結果" };
            return { ...r, status: got.status, permalink: got.permalink ?? null, error: got.error };
          }) ?? null);
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          setResults((prev) => prev?.map((r) =>
            r.campaignId === c.id && r.status === "running"
              ? { ...r, status: "failed", error: msg }
              : r
          ) ?? null);
        }
      }
      onCompleted?.();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  const summary = useMemo(() => {
    if (!results) return null;
    const success = results.filter((r) => r.status === "success").length;
    const failed = results.filter((r) => r.status === "failed").length;
    const remaining = results.length - success - failed;
    return { success, failed, remaining, total: results.length };
  }, [results]);

  return (
    <Modal open={open} onClose={onClose} title={`批次發佈到 FB 粉絲團（${campaignIds.length} 個開團）`} maxWidth="max-w-5xl">
      {loading ? (
        <div className="py-10 text-center text-sm text-zinc-500">載入中…</div>
      ) : campaigns.length === 0 ? (
        <div className="py-10 text-center text-sm text-red-600">{error ?? "找不到開團資料"}</div>
      ) : (
        <div className="space-y-5">
          <section>
            <div className="mb-2 text-xs font-medium text-zinc-500">
              粉絲團（{selectedPageIds.size}/{pages.length}）
            </div>
            {pages.length === 0 ? (
              <div className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-300">
                目前沒有啟用中的粉絲團設定。請先在資料庫的 fb_pages 表新增資料。
              </div>
            ) : (
              <div className="flex flex-wrap gap-2">
                {pages.map((p) => {
                  const selected = selectedPageIds.has(p.id);
                  return (
                    <button
                      key={p.id}
                      type="button"
                      onClick={() => togglePage(p.id)}
                      disabled={submitting}
                      className={`rounded-full border px-3 py-1 text-xs transition ${
                        selected
                          ? "border-blue-500 bg-blue-500 text-white"
                          : "border-zinc-300 bg-white text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300"
                      }`}
                    >
                      {p.name}
                    </button>
                  );
                })}
              </div>
            )}
          </section>

          <section>
            <div className="mb-2 text-xs font-medium text-zinc-500">預覽（共 {campaigns.length} 個開團）</div>
            <div className="max-h-[420px] space-y-3 overflow-y-auto rounded border border-zinc-200 p-2 dark:border-zinc-800">
              {campaigns.map((c) => (
                <div key={c.id} className="rounded border border-zinc-200 bg-white p-3 text-sm dark:border-zinc-800 dark:bg-zinc-900">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="truncate font-semibold">{c.name}</div>
                      <a
                        href={`${MEMBER_APP_URL}/shop/c/${c.id}`}
                        target="_blank"
                        rel="noreferrer"
                        className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                      >
                        {MEMBER_APP_URL}/shop/c/{c.id}
                      </a>
                    </div>
                    <span className="shrink-0 text-xs text-zinc-400">{c.imageUrls.length} 張圖</span>
                  </div>
                  <pre className="mt-2 max-h-32 overflow-y-auto whitespace-pre-wrap rounded bg-zinc-50 p-2 text-xs text-zinc-700 dark:bg-zinc-950 dark:text-zinc-300">
{c.message}
                  </pre>
                  {c.imageUrls.length > 0 && (
                    <div className="mt-2 flex flex-wrap gap-1">
                      {c.imageUrls.slice(0, 8).map((url) => (
                        <div key={url} className="h-12 w-12 overflow-hidden rounded border border-zinc-200 dark:border-zinc-700">
                          {/* eslint-disable-next-line @next/next/no-img-element */}
                          <img src={url} alt="" className="h-full w-full object-cover" />
                        </div>
                      ))}
                      {c.imageUrls.length > 8 && (
                        <div className="flex h-12 w-12 items-center justify-center rounded border border-zinc-200 text-xs text-zinc-500 dark:border-zinc-700">
                          +{c.imageUrls.length - 8}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </section>

          {results && (
            <section>
              <div className="mb-1 flex items-center justify-between text-xs font-medium text-zinc-500">
                <span>發送進度</span>
                {summary && (
                  <span>
                    完成 {summary.success + summary.failed}/{summary.total}（成功 {summary.success}、失敗 {summary.failed}{summary.remaining > 0 ? `、剩 ${summary.remaining}` : ""}）
                  </span>
                )}
              </div>
              <div className="max-h-64 space-y-1 overflow-y-auto rounded border border-zinc-200 p-2 text-xs dark:border-zinc-800">
                {results.map((r, idx) => (
                  <div key={`${r.campaignId}-${r.fbPageId}-${idx}`} className="flex items-center gap-2">
                    <StatusPill status={r.status} />
                    <span className="truncate font-medium">{r.campaignName}</span>
                    <span className="text-zinc-400">→</span>
                    <span className="text-zinc-600 dark:text-zinc-400">{r.pageName}</span>
                    {r.permalink && (
                      <a
                        href={r.permalink}
                        target="_blank"
                        rel="noreferrer"
                        className="text-blue-600 hover:underline dark:text-blue-400"
                      >
                        看貼文
                      </a>
                    )}
                    {r.error && (
                      <span className="truncate text-red-600 dark:text-red-400" title={r.error}>
                        ({r.error.slice(0, 60)}{r.error.length > 60 ? "…" : ""})
                      </span>
                    )}
                  </div>
                ))}
              </div>
            </section>
          )}

          {error && (
            <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700 dark:border-red-900 dark:bg-red-950/30 dark:text-red-300">
              {error}
            </div>
          )}

          <div className="flex items-center justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
            <SpinButton
              onClick={onClose}
              disabled={submitting}
              className="rounded border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800 disabled:opacity-50"
            >
              關閉
            </SpinButton>
            <SpinButton
              onClick={handleSubmit}
              disabled={submitting || pages.length === 0 || selectedPageIds.size === 0 || campaigns.length === 0}
              className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {submitting ? "發送中…" : `發送 ${campaigns.length} × ${selectedPageIds.size} = ${totalPairs} 筆`}
            </SpinButton>
          </div>
        </div>
      )}
    </Modal>
  );
}

function StatusPill({ status }: { status: PairStatus }) {
  const cfg: Record<PairStatus, { label: string; cls: string }> = {
    pending: { label: "待發", cls: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400" },
    running: { label: "發送中", cls: "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300" },
    success: { label: "成功", cls: "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300" },
    failed: { label: "失敗", cls: "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300" },
  };
  const { label, cls } = cfg[status];
  return <span className={`inline-flex shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${cls}`}>{label}</span>;
}
