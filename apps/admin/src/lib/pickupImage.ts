/**
 * 把「可取貨訂單」畫成一張圖，直接當 LINE 訊息的附圖發給會員。
 *
 * 為什麼是圖不是文字：店員原本的做法就是自己截圖貼進 LINE，因為品項一多
 * 純文字在手機上很難讀（會被 LINE 折行折得亂七八糟）。這裡把那張圖自動產出來，
 * 省掉「切到訂單頁 → 截圖 → 裁切 → 貼上」四個動作，也不會截到不該給顧客看的欄位。
 *
 * 用 canvas 而不是後端算圖：後端要算圖得跑 headless browser，edge function 做不到；
 * 而這張圖的資料 admin 前端本來就有，畫完直接走既有的
 * 「上傳 line-media → admin-line-push 發送」管線，不必新增任何後端。
 *
 * ⚠ 一律輸出 JPEG：LINE 的 image message 只吃 JPEG/PNG，而 JPEG 沒有 alpha，
 *   所以底色要自己鋪白（跟 LineMessageModal 的 encodeJpeg 同樣理由）。
 */

export type PickupLine = {
  name: string;
  qty: number;
  unitPrice: number | null;
};

export type PickupOrder = {
  orderNo: string;
  campaign: string | null;
  lines: PickupLine[];
};

export type PickupImageData = {
  storeName: string | null;
  memberName: string | null;
  orders: PickupOrder[];
};

// 以 2 倍解析度繪製再縮回去，手機上看才不會糊（LINE 會放大顯示）
const SCALE = 2;
const W = 720;
const PAD = 28;
const FONT = '"Noto Sans TC", "PingFang TC", "Microsoft JhengHei", system-ui, sans-serif';

/** 超出寬度的品項名截斷加省略號，避免壓到右側數量欄 */
function ellipsize(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
  if (ctx.measureText(text).width <= maxWidth) return text;
  let t = text;
  while (t.length > 1 && ctx.measureText(t + "…").width > maxWidth) t = t.slice(0, -1);
  return t + "…";
}

export async function renderPickupImage(data: PickupImageData): Promise<Blob> {
  // 先算高度：標題區 + 每張訂單（抬頭 + 品項列）+ 合計 + 頁尾
  const lineH = 34;
  const orderHeadH = 40;
  let h = 96;
  for (const o of data.orders) h += orderHeadH + o.lines.length * lineH + 12;
  h += 76;

  const canvas = document.createElement("canvas");
  canvas.width = W * SCALE;
  canvas.height = h * SCALE;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("無法建立 canvas");
  ctx.scale(SCALE, SCALE);

  // JPEG 沒有透明度，底色一定要自己鋪
  ctx.fillStyle = "#ffffff";
  ctx.fillRect(0, 0, W, h);

  let y = PAD;

  // 標題
  ctx.fillStyle = "#111827";
  ctx.font = `bold 26px ${FONT}`;
  ctx.fillText("可取貨訂單", PAD, y + 22);
  y += 36;

  ctx.font = `15px ${FONT}`;
  ctx.fillStyle = "#6b7280";
  const sub = [data.storeName, data.memberName].filter(Boolean).join("　·　");
  if (sub) ctx.fillText(sub, PAD, y + 14);
  y += 30;

  ctx.strokeStyle = "#e5e7eb";
  ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(PAD, y); ctx.lineTo(W - PAD, y); ctx.stroke();
  y += 12;

  let totalQty = 0;
  let totalAmount = 0;

  for (const o of data.orders) {
    ctx.fillStyle = "#111827";
    ctx.font = `bold 16px ${FONT}`;
    ctx.fillText(o.orderNo, PAD, y + 22);
    // ⚠ 寬度必須在「還是 bold 16px」時量 —— 切成 14px 再量會少算，
    //   團購名就會壓在訂單編號上面（2026-08-07 產圖預覽踩到）
    const noW = ctx.measureText(o.orderNo).width;
    if (o.campaign) {
      ctx.font = `14px ${FONT}`;
      ctx.fillStyle = "#6b7280";
      ctx.fillText(ellipsize(ctx, o.campaign, W - PAD * 2 - noW - 20), PAD + noW + 16, y + 22);
    }
    y += orderHeadH;

    for (const l of o.lines) {
      totalQty += l.qty;
      const sub2 = l.unitPrice != null ? l.unitPrice * l.qty : 0;
      totalAmount += sub2;

      ctx.font = `15px ${FONT}`;
      ctx.fillStyle = "#374151";
      // 右側兩欄固定寬度：數量 70、小計 110
      ctx.fillText(ellipsize(ctx, l.name, W - PAD * 2 - 190), PAD + 8, y + 20);

      ctx.textAlign = "right";
      ctx.fillStyle = "#6b7280";
      ctx.fillText(`×${l.qty}`, W - PAD - 120, y + 20);
      ctx.fillStyle = "#111827";
      ctx.fillText(l.unitPrice != null ? `$${sub2.toLocaleString()}` : "—", W - PAD, y + 20);
      ctx.textAlign = "left";

      y += lineH;
    }
    y += 12;
  }

  ctx.strokeStyle = "#e5e7eb";
  ctx.beginPath(); ctx.moveTo(PAD, y); ctx.lineTo(W - PAD, y); ctx.stroke();
  y += 12;

  ctx.font = `bold 18px ${FONT}`;
  ctx.fillStyle = "#111827";
  ctx.fillText(`共 ${totalQty} 件`, PAD, y + 22);
  ctx.textAlign = "right";
  ctx.fillText(`$${totalAmount.toLocaleString()}`, W - PAD, y + 22);
  ctx.textAlign = "left";
  y += 38;

  ctx.font = `12px ${FONT}`;
  ctx.fillStyle = "#9ca3af";
  ctx.fillText(`產生時間：${new Date().toLocaleString("zh-TW")}`, PAD, y + 12);

  const blob = await new Promise<Blob | null>((res) => canvas.toBlob(res, "image/jpeg", 0.92));
  if (!blob) throw new Error("圖片產生失敗");
  return blob;
}
