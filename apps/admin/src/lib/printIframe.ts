// Print a same-origin page (e.g. /pickup/print, /pickup/print-list) WITHOUT
// opening a new browser tab/window. The target pages already fetch their own
// data and call window.print() once loaded — hosting them in a hidden iframe
// scopes that print() to the iframe document, so the browser's print dialog
// appears directly with no visible page jumping out.
//
// Calls are serialized: when two slips are printed back-to-back (取貨單 +
// 取貨清單), the second iframe only loads after the first one's print dialog
// has closed, so the two dialogs never clobber each other.

let chain: Promise<void> = Promise.resolve();

export function printViaIframe(url: string): Promise<void> {
  if (typeof document === "undefined") return Promise.resolve();
  chain = chain.then(() => printOnce(url)).catch(() => {});
  return chain;
}

function printOnce(url: string): Promise<void> {
  return new Promise<void>((resolve) => {
    const iframe = document.createElement("iframe");
    iframe.setAttribute("aria-hidden", "true");
    iframe.style.cssText =
      "position:fixed;right:0;bottom:0;width:0;height:0;border:0;visibility:hidden;";

    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      // 延遲移除：確保列印工作已送進佇列再拆掉 iframe
      window.setTimeout(() => iframe.remove(), 1000);
      resolve();
    };

    iframe.onload = () => {
      // 目標頁資料載入後會自行 window.print()（在 iframe 內＝印 iframe 內容）。
      // afterprint 在列印對話框關閉（送印或取消）時觸發 → 收尾並放行下一張。
      try {
        iframe.contentWindow?.addEventListener("afterprint", finish, { once: true });
      } catch {
        // same-origin 理論上不會進這裡；保險 timeout 仍會收尾
      }
      // 保險：頁面載入錯誤（沒資料 → 不會呼叫 print）時不會有 afterprint，
      // 用較長 timeout 收尾,避免永久卡住串行 chain（同時夠長,不會在
      // 使用者還在選印表機時誤觸發）。
      window.setTimeout(finish, 45000);
    };

    iframe.src = url;
    document.body.appendChild(iframe);
  });
}
