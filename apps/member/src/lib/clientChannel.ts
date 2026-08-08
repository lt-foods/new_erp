// 會員自助下單的「通路」判斷 —— 寫進 customer_order_items.source，
// 訂單頁的來源折線圖 KPI 就是靠這個值分 App / 商城兩條線。
//
//   'liff' → 在 LINE 裡面（LINE 內建瀏覽器 / LIFF）＝ 後台顯示「商城」
//   'pwa'  → 其餘（已安裝的 PWA、外部瀏覽器開的會員站）＝ 後台顯示「App」
//
// 只分兩類是刻意的：會員站在「已安裝 PWA」與「外部瀏覽器」下是同一個 App
// 體驗（同一份程式、同一組頁面），會員自己也不會覺得那是兩個東西；真正
// 不同的是「在 LINE 裡逛」那條路。standalone 與否只影響推播能不能用
// （見 usePushNotification），不影響下單通路的定義。
//
// 判斷用 UA 的 " Line/" 為主、liff.isInClient() 為輔：
//   - UA 在 LINE webview 一定帶 " Line/"，而且 liff.init() 還沒跑完時就已經讀得到；
//   - liff.isInClient() 只有 LIFF SDK 載好才有，補抓 UA 判不出來的邊緣情況。
// 兩者任一為真就算在 LINE 內 —— 寧可誤判成「商城」也不要把 LINE 內的單算成 App，
// 因為 2026-08-08 之前的歷史資料全部都是 'liff'（商城），口徑才連得起來。

export type ClientChannel = "pwa" | "liff";

export function detectClientChannel(): ClientChannel {
  if (typeof window === "undefined") return "pwa";
  const ua = window.navigator?.userAgent ?? "";
  if (/ Line\//i.test(ua)) return "liff";
  try {
    if (window.liff?.isInClient?.()) return "liff";
  } catch {
    // SDK 沒載好 / init 前呼叫會 throw —— 當作不在 LINE 內，UA 那關已經擋過一次了
  }
  return "pwa";
}
