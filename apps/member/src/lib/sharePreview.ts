/**
 * 分享連結預覽（OG tag）用的伺服器端資料抓取。
 *
 * 跟 callLiffApi 的差別：這支在 **Next 的 server 端**跑、而且不帶 token ——
 * 去抓 OG tag 的是 LINE / FB 的爬蟲，它沒有會員 session。對應的
 * liff-api action 掛在免 token 區，只回團名 / 圖 / 起跳價這類公開欄位。
 *
 * 抓不到一律回 null，讓呼叫端退回站台預設的預覽卡 —— 分享卡再重要也不能
 * 讓它把整頁 render 弄掛。
 */
export type CampaignPreview = {
  id: number;
  campaign_no: string | null;
  name: string | null;
  description: string | null;
  image_url: string | null;
  price_from: number | null;
  status: string | null;
  end_at: string | null;
};

export async function fetchCampaignPreview(
  campaignId: number,
): Promise<CampaignPreview | null> {
  const base = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!base || !Number.isFinite(campaignId) || campaignId <= 0) return null;

  try {
    const resp = await fetch(`${base}/functions/v1/liff-api`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "get_campaign_preview", campaign_id: campaignId }),
      // 爬蟲通常有秒級 timeout，我們自己先斷，寧可給通用卡也不要讓它抓到空白
      signal: AbortSignal.timeout(5000),
    });
    if (!resp.ok) return null;
    const data = await resp.json() as { campaign?: CampaignPreview };
    return data.campaign ?? null;
  } catch {
    return null;
  }
}
