// 開團「上架通知」文本：預設值 + 佔位符代換
// SQL 端有同一份邏輯（20260814010000 的 _default_campaign_notify_template /
// _render_campaign_notify_text），改的話兩邊一起改。
import { getSupabase } from "@/lib/supabase";

export type CloseType = "regular" | "fast" | "limited" | "food_train";
export type NotifyTemplate = { title: string; body: string };

export const NOTIFY_PLACEHOLDERS = ["{團名}", "{團號}", "{收單時間}"] as const;

export const DEFAULT_NOTIFY_TEMPLATE: Record<CloseType, NotifyTemplate> = {
  food_train: { title: "美食列車新團上架", body: "{團名}" },
  regular: { title: "新團上架", body: "{團名}" },
  fast: { title: "新團上架", body: "{團名}" },
  limited: { title: "新團上架", body: "{團名}" },
};

export function renderNotifyText(
  template: string,
  c: { name: string; campaign_no: string; end_at: string | null }
): string {
  const endAt = c.end_at
    ? new Date(c.end_at).toLocaleString("zh-TW", {
        timeZone: "Asia/Taipei",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false,
      })
    : "";
  return template
    .replaceAll("{團名}", c.name)
    .replaceAll("{團號}", c.campaign_no)
    .replaceAll("{收單時間}", endAt);
}

// 讀 tenant 自訂文本；沒有列（或讀失敗）就用內建預設
export async function getNotifyTemplate(closeType: CloseType): Promise<NotifyTemplate> {
  try {
    const { data } = await getSupabase()
      .from("campaign_notify_templates")
      .select("title, body")
      .eq("close_type", closeType)
      .maybeSingle();
    if (data?.title && data?.body) return { title: data.title, body: data.body };
  } catch {
    // 讀不到就退回預設；文本層失敗不該擋通知
  }
  return DEFAULT_NOTIFY_TEMPLATE[closeType];
}
