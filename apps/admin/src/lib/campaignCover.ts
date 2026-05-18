import { getSupabase } from "@/lib/supabase";

// 開團封面回退鏈（與 supabase/functions/liff-api listActiveCampaigns 一致）：
// group_buy_campaigns.cover_image_url 優先 → 否則取 sort_order 最小的
// campaign_item 之 sku.product.images[0]。images[0] 可能是字串或 { url }；
// 路徑若已是絕對 URL 則不再加 storage 前綴，否則用 products bucket public URL。

export type CampaignCoverItem = {
  sort_order: number | null;
  sku: { product: { images: unknown } | null } | null;
};

export function publicProductUrl(path: string | null | undefined): string | null {
  if (!path) return null;
  if (/^https?:\/\//i.test(path)) return path;
  return getSupabase().storage.from("products").getPublicUrl(path).data.publicUrl;
}

export function campaignCoverUrl(
  coverImageUrl: string | null | undefined,
  items: CampaignCoverItem[] | null | undefined,
): string | null {
  let path: string | null = coverImageUrl ?? null;
  if (!path) {
    const sorted = [...(items ?? [])].sort(
      (a, b) => (a.sort_order ?? 0) - (b.sort_order ?? 0),
    );
    const imgs = sorted[0]?.sku?.product?.images;
    if (Array.isArray(imgs) && imgs.length > 0) {
      const first = imgs[0] as unknown;
      path =
        typeof first === "string"
          ? first
          : (first as { url?: string | null })?.url ?? null;
    }
  }
  return publicProductUrl(path);
}
