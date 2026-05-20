"use client";

import { useEffect, useMemo, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";

const PRODUCTS_BUCKET = "products";
const MEMBER_APP_URL = (process.env.NEXT_PUBLIC_MEMBER_APP_URL ?? "https://shop.lt-foods.tw").replace(/\/$/, "");

type FbPage = {
  id: number;
  page_id: string;
  name: string;
  sort_order: number;
};

type CampaignDetail = {
  id: number;
  name: string;
  description: string | null;
  cover_image_url: string | null;
};

type PreviousPost = {
  id: number;
  fb_page_id: number;
  fb_post_id: string | null;
  permalink: string | null;
  status: string;
  error_message: string | null;
  posted_at: string | null;
  created_at: string;
};

type PublishResult = {
  fb_page_id: number;
  page_name: string;
  status: "success" | "failed";
  fb_post_id?: string;
  permalink?: string | null;
  error?: string;
};

type Props = {
  open: boolean;
  campaignId: number | null;
  onClose: () => void;
};

function resolveImagePath(p: string): string {
  if (/^https?:\/\//i.test(p)) return p;
  return getSupabase().storage.from(PRODUCTS_BUCKET).getPublicUrl(p).data.publicUrl;
}

export default function FbPublishModal({ open, campaignId, onClose }: Props) {
  const [loading, setLoading] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [campaign, setCampaign] = useState<CampaignDetail | null>(null);
  const [allImages, setAllImages] = useState<string[]>([]);
  const [pages, setPages] = useState<FbPage[]>([]);
  const [previous, setPrevious] = useState<PreviousPost[]>([]);

  const [message, setMessage] = useState("");
  const [selectedImageUrls, setSelectedImageUrls] = useState<Set<string>>(new Set());
  const [selectedPageIds, setSelectedPageIds] = useState<Set<number>>(new Set());

  const [results, setResults] = useState<PublishResult[] | null>(null);

  const sentPageIds = useMemo(() => {
    return new Set(previous.filter((p) => p.status === "success").map((p) => p.fb_page_id));
  }, [previous]);

  useEffect(() => {
    if (!open || !campaignId) return;
    let cancelled = false;
    (async () => {
      setLoading(true);
      setError(null);
      setResults(null);
      try {
        const sb = getSupabase();
        const [campRes, pagesRes, prevRes] = await Promise.all([
          sb
            .from("group_buy_campaigns")
            .select(
              "id, name, description, cover_image_url, campaign_items(sort_order, sku:skus(product:products(images)))",
            )
            .eq("id", campaignId)
            .maybeSingle(),
          sb
            .from("fb_pages")
            .select("id, page_id, name, sort_order")
            .eq("is_active", true)
            .order("sort_order", { ascending: true }),
          sb
            .from("campaign_fb_posts")
            .select("id, fb_page_id, fb_post_id, permalink, status, error_message, posted_at, created_at")
            .eq("campaign_id", campaignId)
            .order("created_at", { ascending: false }),
        ]);
        if (cancelled) return;
        if (campRes.error) throw campRes.error;
        if (pagesRes.error) throw pagesRes.error;
        if (prevRes.error) throw prevRes.error;

        const camp = campRes.data as (CampaignDetail & {
          campaign_items?: Array<{
            sort_order: number;
            sku?: { product?: { images?: string[] } | null } | null;
          }>;
        }) | null;
        if (!camp) throw new Error("找不到開團資料");

        const imageSet = new Set<string>();
        if (camp.cover_image_url) imageSet.add(resolveImagePath(camp.cover_image_url));
        const items = (camp.campaign_items ?? []).slice().sort((a, b) => a.sort_order - b.sort_order);
        for (const it of items) {
          const imgs = it.sku?.product?.images ?? [];
          for (const p of imgs) if (typeof p === "string" && p) imageSet.add(resolveImagePath(p));
        }
        const imgList = [...imageSet];

        setCampaign({
          id: camp.id,
          name: camp.name,
          description: camp.description ?? null,
          cover_image_url: camp.cover_image_url ?? null,
        });
        setAllImages(imgList);
        setSelectedImageUrls(new Set(imgList));
        setPages(pagesRes.data ?? []);
        setSelectedPageIds(new Set());
        setPrevious(prevRes.data ?? []);
        setMessage(buildDefaultMessage(camp.name, camp.description ?? null, camp.id));
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [open, campaignId]);

  const togglePage = (id: number) => {
    setSelectedPageIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  const toggleImage = (url: string) => {
    setSelectedImageUrls((prev) => {
      const next = new Set(prev);
      if (next.has(url)) next.delete(url);
      else next.add(url);
      return next;
    });
  };

  async function handleSubmit() {
    if (!campaignId || !campaign) return;
    if (selectedPageIds.size === 0) {
      setError("請選擇至少一個粉絲團");
      return;
    }
    if (!message.trim()) {
      setError("貼文內容不可為空");
      return;
    }
    setSubmitting(true);
    setError(null);
    setResults(null);
    try {
      const sb = getSupabase();
      const { data: { session } } = await sb.auth.getSession();
      if (!session) throw new Error("尚未登入");

      const resp = await fetch(
        `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/campaign-publish-facebook`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${session.access_token}`,
          },
          body: JSON.stringify({
            campaign_id: campaignId,
            fb_page_ids: [...selectedPageIds],
            message: message.trim(),
            image_urls: allImages.filter((u) => selectedImageUrls.has(u)),
          }),
        },
      );
      const data = await resp.json();
      if (!resp.ok) throw new Error(data?.error || data?.detail || `HTTP ${resp.status}`);
      setResults(data.results ?? []);

      // refresh previous posts so badges update
      const { data: prev } = await sb
        .from("campaign_fb_posts")
        .select("id, fb_page_id, fb_post_id, permalink, status, error_message, posted_at, created_at")
        .eq("campaign_id", campaignId)
        .order("created_at", { ascending: false });
      setPrevious(prev ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  const allFailed = !!results && results.length > 0 && results.every((r) => r.status === "failed");
  const allSuccess = !!results && results.length > 0 && results.every((r) => r.status === "success");

  return (
    <Modal open={open} onClose={onClose} title="發佈到 FB 粉絲團" maxWidth="max-w-4xl">
      {loading ? (
        <div className="py-10 text-center text-sm text-zinc-500">載入中…</div>
      ) : !campaign ? (
        <div className="py-10 text-center text-sm text-red-600">{error ?? "資料不可用"}</div>
      ) : (
        <div className="space-y-5">
          <section>
            <div className="text-xs font-medium text-zinc-500">開團</div>
            <div className="mt-1 text-sm font-semibold">{campaign.name}</div>
            <a
              href={`${MEMBER_APP_URL}/shop/c/${campaign.id}`}
              target="_blank"
              rel="noreferrer"
              className="text-xs text-blue-600 hover:underline dark:text-blue-400"
            >
              {MEMBER_APP_URL}/shop/c/{campaign.id}
            </a>
          </section>

          <section>
            <label className="block text-xs font-medium text-zinc-500">貼文內容</label>
            <textarea
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              rows={8}
              className="mt-1 w-full rounded border border-zinc-300 px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
              disabled={submitting}
            />
          </section>

          <section>
            <div className="mb-2 text-xs font-medium text-zinc-500">
              圖片（{selectedImageUrls.size}/{allImages.length}）
            </div>
            {allImages.length === 0 ? (
              <div className="text-xs text-zinc-400">此開團沒有圖片，將只發文字</div>
            ) : (
              <div className="grid grid-cols-3 gap-2 sm:grid-cols-5">
                {allImages.map((url) => {
                  const selected = selectedImageUrls.has(url);
                  return (
                    <button
                      key={url}
                      type="button"
                      onClick={() => toggleImage(url)}
                      disabled={submitting}
                      className={`relative aspect-square overflow-hidden rounded border-2 transition ${
                        selected
                          ? "border-blue-500 ring-2 ring-blue-200 dark:ring-blue-900"
                          : "border-zinc-200 opacity-50 dark:border-zinc-700"
                      }`}
                    >
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      <img src={url} alt="" className="h-full w-full object-cover" />
                      {selected && (
                        <span className="absolute right-1 top-1 rounded-full bg-blue-500 px-1.5 py-0.5 text-[10px] font-medium text-white">
                          ✓
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            )}
          </section>

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
                  const sent = sentPageIds.has(p.id);
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
                      {sent && (
                        <span
                          className={`ml-1 rounded-full px-1 text-[10px] ${
                            selected ? "bg-white/30" : "bg-amber-100 text-amber-700 dark:bg-amber-900/50 dark:text-amber-300"
                          }`}
                          title="此粉絲團已發過"
                        >
                          已發
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            )}
          </section>

          {previous.length > 0 && (
            <section>
              <div className="mb-1 text-xs font-medium text-zinc-500">發送紀錄</div>
              <ul className="space-y-1 text-xs">
                {previous.slice(0, 5).map((p) => {
                  const pg = pages.find((x) => x.id === p.fb_page_id);
                  return (
                    <li key={p.id} className="flex items-center gap-2">
                      <span
                        className={`inline-flex rounded px-1.5 py-0.5 text-[10px] font-medium ${
                          p.status === "success"
                            ? "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300"
                            : "bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300"
                        }`}
                      >
                        {p.status === "success" ? "成功" : "失敗"}
                      </span>
                      <span className="text-zinc-500">{pg?.name ?? `page #${p.fb_page_id}`}</span>
                      <span className="text-zinc-400">{p.posted_at ?? p.created_at}</span>
                      {p.permalink && (
                        <a
                          href={p.permalink}
                          target="_blank"
                          rel="noreferrer"
                          className="text-blue-600 hover:underline dark:text-blue-400"
                        >
                          看貼文
                        </a>
                      )}
                      {p.error_message && (
                        <span className="text-red-600 dark:text-red-400" title={p.error_message}>
                          ({p.error_message.slice(0, 40)}{p.error_message.length > 40 ? "…" : ""})
                        </span>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          )}

          {error && (
            <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-xs text-red-700 dark:border-red-900 dark:bg-red-950/30 dark:text-red-300">
              {error}
            </div>
          )}

          {results && (
            <div
              className={`rounded border px-3 py-2 text-xs ${
                allSuccess
                  ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/30 dark:text-green-300"
                  : allFailed
                  ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950/30 dark:text-red-300"
                  : "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950/30 dark:text-amber-300"
              }`}
            >
              <div className="font-medium">
                {allSuccess ? "全部發送成功" : allFailed ? "全部發送失敗" : "部分發送成功"}
              </div>
              <ul className="mt-1 space-y-0.5">
                {results.map((r) => (
                  <li key={r.fb_page_id}>
                    {r.status === "success" ? "✓" : "✕"} {r.page_name}
                    {r.error ? `：${r.error}` : ""}
                    {r.permalink && (
                      <>
                        {" "}
                        <a
                          href={r.permalink}
                          target="_blank"
                          rel="noreferrer"
                          className="text-blue-600 hover:underline dark:text-blue-400"
                        >
                          看貼文
                        </a>
                      </>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}

          <div className="flex justify-end gap-2 border-t border-zinc-200 pt-3 dark:border-zinc-800">
            <SpinButton
              onClick={onClose}
              disabled={submitting}
              className="rounded border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800 disabled:opacity-50"
            >
              關閉
            </SpinButton>
            <SpinButton
              onClick={handleSubmit}
              disabled={submitting || pages.length === 0 || selectedPageIds.size === 0}
              className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {submitting ? "發送中…" : `發送到 ${selectedPageIds.size} 個粉絲團`}
            </SpinButton>
          </div>
        </div>
      )}
    </Modal>
  );
}

function buildDefaultMessage(name: string, description: string | null, campaignId: number): string {
  const link = `${MEMBER_APP_URL}/shop/c/${campaignId}`;
  const parts: string[] = [];
  parts.push(`【開團】${name}`);
  if (description) {
    const plain = description
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n")
      .replace(/<[^>]+>/g, "")
      .trim();
    if (plain) parts.push(plain);
  }
  parts.push(`\n👉 立即下單：${link}`);
  return parts.join("\n\n");
}
