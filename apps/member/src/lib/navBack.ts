import type { useRouter } from "next/navigation";

type AppRouter = ReturnType<typeof useRouter>;

/**
 * 「回上一頁」的唯一實作：有 history 就 back，沒有（深連結 / LINE 開新分頁）
 * 才 push 到 fallback。
 *
 * 為什麼不是 `router.push(列表頁)`：push 會讓 Next 在換頁後把畫面捲到頂端
 * （app router 的 ScrollAndFocusHandler 在列表頁自己的 layout effect **之後**
 * 跑，蓋掉 /shop 的捲動位置還原），客人每買一團就得從第一項重新往下滑
 * （2026-09-30 團友回報「下單後點繼續逛會回到商城第一項商品」）。
 * back() 走 popstate，Next 不動捲動，列表頁的模組快取才有機會把位置還回去，
 * 而且會回到客人真正來的那一頁（/shop 的漂漂館分頁、專區…），不是硬指某一頁。
 */
export function backOrPush(router: AppRouter, fallbackHref: string) {
  if (typeof window !== "undefined" && window.history.length > 1) {
    router.back();
  } else {
    router.push(fallbackHref);
  }
}
