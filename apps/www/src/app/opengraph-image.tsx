import { ImageResponse } from "next/og";
import { BRAND_NAME, TAGLINE, SUB_TAGLINE } from "@/lib/site";

export const dynamic = "force-static";

export const alt = `${BRAND_NAME}｜${TAGLINE}`;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const CHIP = "團購店 ERP・免費試用 14 天";

/**
 * 抓 Google Fonts 的「子集字型」：只含本圖用到的字，檔案極小。
 * 只取 truetype/opentype 變體（satori 不吃 woff2）。
 * 抓不到（離線）就回 null，圖仍會產出（中文退化為系統字）。
 */
async function loadCjkFont(text: string): Promise<ArrayBuffer | null> {
  try {
    const url = `https://fonts.googleapis.com/css2?family=Noto+Sans+TC:wght@800&text=${encodeURIComponent(
      text,
    )}`;
    const css = await fetch(url).then((r) => r.text());
    const src = css.match(
      /src:\s*url\(([^)]+)\)\s*format\('(?:opentype|truetype)'\)/,
    )?.[1];
    if (!src) return null;
    const res = await fetch(src);
    if (res.status !== 200) return null;
    return await res.arrayBuffer();
  } catch {
    return null;
  }
}

export default async function OgImage() {
  const text = BRAND_NAME + TAGLINE + SUB_TAGLINE + CHIP;
  const font = await loadCjkFont(text);

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "80px 90px",
          background: "linear-gradient(135deg, #ea580c 0%, #c2410c 100%)",
          color: "#ffffff",
          fontFamily: "NotoSansTC",
        }}
      >
        <div
          style={{
            display: "flex",
            alignSelf: "flex-start",
            background: "rgba(255,255,255,0.15)",
            borderRadius: 999,
            padding: "10px 26px",
            fontSize: 30,
            fontWeight: 800,
          }}
        >
          {CHIP}
        </div>
        <div style={{ fontSize: 96, fontWeight: 800, marginTop: 36, lineHeight: 1.1 }}>
          {TAGLINE}
        </div>
        <div style={{ fontSize: 40, marginTop: 28, color: "rgba(255,255,255,0.92)" }}>
          {SUB_TAGLINE}
        </div>
        <div
          style={{
            display: "flex",
            marginTop: 48,
            fontSize: 52,
            fontWeight: 800,
            letterSpacing: 2,
          }}
        >
          {BRAND_NAME}
        </div>
      </div>
    ),
    {
      ...size,
      fonts: font
        ? [{ name: "NotoSansTC", data: font, weight: 800, style: "normal" }]
        : [],
    },
  );
}
