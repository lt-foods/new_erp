"use client";

// 現場銷售小白單（80mm 感熱紙）。版型比照 /pickup/print-list 的取貨小白單：
// 等寬字、虛線分隔、@page size 80mm auto。
//
// ⚠ 這是**唯一**一份版型，兩個地方共用：
//   1. /pos 結帳完直接在同一個畫面跳列印（主要路徑，店員不用換頁）
//   2. /pos/receipt 獨立頁（事後重印舊單）
// 抄成兩份的話下次改格式只會改到其中一份 —— 這個 repo 已經有 orderTitle.ts
// 那個「兩份副本」的前例，不要再多一個。

export type ReceiptLine = {
  label: string;
  qty: number;
  unitPrice: number;
};

export type ReceiptData = {
  storeName: string;
  orderNo: string;
  customerName: string;
  /** 真會員才給；現場客的 WALKIN- 假帳號不要印出來（客人看不懂也不該看到） */
  memberNo?: string | null;
  memberPhone?: string | null;
  createdAt: string;
  paymentMethod?: string | null;
  discount: number;
  lines: ReceiptLine[];
};

export const PAY_LABEL: Record<string, string> = {
  cash: "現金",
  transfer: "轉帳",
  credit_card: "刷卡",
  linepay: "LINE Pay",
  wallet: "儲值金",
};

/** 小白單的列印用 CSS。放在會列印的頁面上，`.pos-noprint` 的東西列印時會消失。 */
export function PosReceiptPrintStyle() {
  return (
    <style jsx global>{`
      @media print {
        @page {
          margin: 3mm;
          size: 80mm auto;
        }
        body {
          background: white !important;
        }
        .pos-noprint {
          display: none !important;
        }
      }
    `}</style>
  );
}

export function PosReceipt({ data }: { data: ReceiptData }) {
  const subtotal = data.lines.reduce((s, l) => s + l.qty * l.unitPrice, 0);
  const disc = Math.max(0, data.discount);
  const total = Math.max(0, subtotal - disc);
  const totalQty = data.lines.reduce((s, l) => s + l.qty, 0);
  // WALKIN- 是現場客共用假帳號（_walkin_member），不是客人的會員編號
  const showMember = !!data.memberNo && !data.memberNo.startsWith("WALKIN-");

  return (
    <div className="mx-auto max-w-[80mm] bg-white p-3 font-mono text-[14px] leading-tight text-black">
      <div className="text-center">
        <div className="text-[20px] font-bold">{data.storeName}</div>
        <div className="text-[13px]">銷售明細</div>
      </div>

      <div className="mt-2 border-y border-dashed border-black py-1.5 text-[13px]">
        <div className="text-[16px] font-bold">{data.customerName}</div>
        {showMember && (
          <div>
            {data.memberNo}
            {data.memberPhone && <span className="ml-2">{data.memberPhone}</span>}
          </div>
        )}
        <div>單號：{data.orderNo}</div>
        <div>{new Date(data.createdAt).toLocaleString("zh-TW", { hour12: false })}</div>
      </div>

      <div className="mt-2 divide-y divide-dashed divide-zinc-300">
        {data.lines.map((l, i) => (
          <div key={i} className="py-1">
            <div className="break-words text-[15px] font-bold">{l.label}</div>
            <div className="flex justify-between text-[14px]">
              <span>
                {l.qty} × ${l.unitPrice}
              </span>
              <span className="font-bold">${l.qty * l.unitPrice}</span>
            </div>
          </div>
        ))}
      </div>

      <div className="mt-2 border-t border-dashed border-black pt-1.5 text-[14px]">
        <div className="flex justify-between">
          <span>件數</span>
          <span>{totalQty}</span>
        </div>
        <div className="flex justify-between">
          <span>小計</span>
          <span>${subtotal}</span>
        </div>
        {disc > 0 && (
          <div className="flex justify-between font-bold">
            <span>折扣</span>
            <span>-${disc}</span>
          </div>
        )}
        <div className="mt-1 flex justify-between border-t border-black pt-1 text-[18px] font-bold">
          <span>應收</span>
          <span>${total}</span>
        </div>
        <div className="flex justify-between">
          <span>付款</span>
          <span>{PAY_LABEL[data.paymentMethod ?? ""] ?? data.paymentMethod ?? "—"}</span>
        </div>
      </div>

      <div className="mt-3 text-center text-[12px]">謝謝惠顧</div>
    </div>
  );
}

export default PosReceipt;
