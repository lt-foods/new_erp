import type { Metadata } from "next";
import CampaignDetailClient from "./CampaignDetailClient";
import { fetchCampaignPreview } from "@/lib/sharePreview";
import { SITE_NAME, SITE_OG_IMAGE, SITE_URL } from "@/lib/site";
import { cleanCampaignText } from "@/lib/text";

/**
 * 團購商品頁的**外殼**：本體是 CampaignDetailClient（client component），
 * 這一層只為了 generateMetadata —— 貼到 LINE / FB 的時候，對方爬蟲讀的是
 * 伺服器吐出來的 OG tag，client component 自己 fetch 回來的資料它看不到。
 * 沒有這一層的話，每一支團的連結預覽都長一樣（站台標題 + 店家 logo）。
 *
 * ISR：頁面外殼對所有人都一樣（真正的資料是登入後由 client 抓），所以整頁
 * 連同 metadata 快取 5 分鐘就好，不必每次瀏覽都往 edge function 多打一次。
 */
export const revalidate = 300;

const MAX_DESC = 90;

function ogDescription(p: { description: string | null; price_from: number | null }): string {
  const price = p.price_from != null && p.price_from > 0
    ? `$${Math.round(p.price_from).toLocaleString("en-US")} 起・`
    : "";
  // 團購文案常夾著報名表單連結，整行拿掉（只砍網址會把上下句黏成一團）
  const body = cleanCampaignText(p.description)
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !/https?:\/\//.test(l))
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
  const tail = body.length > MAX_DESC ? `${body.slice(0, MAX_DESC)}…` : body;
  return `${price}${tail || "點開看今日開團，線上下單、門市取貨。"}`;
}

export async function generateMetadata(
  { params }: { params: Promise<{ id: string }> },
): Promise<Metadata> {
  const { id } = await params;
  const preview = await fetchCampaignPreview(Number(id));

  // 抓不到（團不存在 / edge function 掛了）就退回站台通用卡，不要吐半套
  if (!preview) {
    return {
      metadataBase: new URL(SITE_URL),
      title: SITE_NAME,
      openGraph: {
        type: "website",
        siteName: SITE_NAME,
        title: SITE_NAME,
        url: `/shop/c/${id}`,
        locale: "zh_TW",
        images: [{ url: SITE_OG_IMAGE }],
      },
    };
  }

  const name = cleanCampaignText(preview.name) || SITE_NAME;
  const description = ogDescription(preview);
  // 商品圖是 Supabase storage 的絕對網址；沒有圖才退回店家 banner
  const image = preview.image_url ?? SITE_OG_IMAGE;

  return {
    metadataBase: new URL(SITE_URL),
    title: `${name}｜${SITE_NAME}`,
    description,
    alternates: { canonical: `/shop/c/${preview.id}` },
    openGraph: {
      type: "website",
      siteName: SITE_NAME,
      title: name,
      description,
      url: `/shop/c/${preview.id}`,
      locale: "zh_TW",
      images: [{ url: image, alt: name }],
    },
    twitter: {
      card: "summary_large_image",
      title: name,
      description,
      images: [image],
    },
  };
}

export default function CampaignDetailPage() {
  return <CampaignDetailClient />;
}
