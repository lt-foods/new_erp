export type SettlementRow = {
  id: number;
  settlement_no: string;
  status: string;
  payment_status: string;
  payment_method: string | null;
  paid_at: string | null;
  remit_amount: number;
  remit_at: string | null;
  remit_note: string | null;
  shipping_method: string | null;
  shipping_address: string | null;
  shipping_phone: string | null;
  shipping_note: string | null;
  items_total: number;
  shipping_fee: number;
  discount_amount: number;
  payable_amount: number;
};

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

export default function SettlementCard({ settlement: s }: { settlement: SettlementRow }) {
  const paymentLabel  = s.payment_status === "paid" ? "已付款" : "未付款";
  const shippingLabel = ["shipping", "completed"].includes(s.status) ? "已出貨" : "未出貨";

  return (
    <article className="overflow-hidden rounded-md border border-pink-100 bg-white shadow-sm">
      <div className="border-b border-pink-100 bg-pink-50 px-4 py-2">
        <span className="text-sm font-medium text-pink-700"># 結單編號 </span>
        <span className="font-mono text-sm text-pink-700">{s.settlement_no}</span>
      </div>

      <div className="space-y-3 px-4 py-3 text-base">
        <div>
          <span className="text-zinc-500">狀態：</span>
          <span className="text-pink-600">{paymentLabel}</span>
          <span className="mx-1 text-zinc-300">/</span>
          <span className="text-pink-600">{shippingLabel}</span>
        </div>

        <div>
          <div className="text-pink-600">💳 付款方式</div>
          <div className="text-zinc-700">{s.payment_method ?? "-"}</div>
          <div className="text-sm text-zinc-500">匯款金額：{fmtAmount(s.remit_amount)} 元</div>
          <div className="text-sm text-zinc-500">匯款時間：{s.remit_at ?? "-"}</div>
          <div className="text-sm text-zinc-500">匯款備註：{s.remit_note ?? "-"}</div>
          {s.payment_status !== "paid" && (
            <div className="mt-1 text-lg font-semibold text-zinc-900">未付款</div>
          )}
        </div>

        <div>
          <div className="text-pink-600">🚚 出貨方式</div>
          <div className="text-zinc-700">{s.shipping_method ?? "-"}</div>
          <div className="text-sm text-zinc-500">{s.shipping_phone ?? "未填寫電話"}</div>
          {s.shipping_address && (
            <div className="text-sm text-zinc-500">{s.shipping_address}</div>
          )}
          <div className="text-sm text-zinc-500">{s.shipping_note ?? "未填寫備註"}</div>
        </div>

        <div className="space-y-1 border-t border-zinc-100 pt-3">
          <div className="flex justify-between text-sm text-zinc-500">
            <span>總金額</span>
            <span>{fmtAmount(s.items_total)}</span>
          </div>
          <div className="flex justify-between text-sm text-zinc-500">
            <span>運費</span>
            <span>{fmtAmount(s.shipping_fee)}</span>
          </div>
          <div className="flex justify-between text-sm text-zinc-500">
            <span>促銷活動</span>
            <span>
              {s.discount_amount > 0 ? `-${fmtAmount(s.discount_amount)}` : "0.00"}
            </span>
          </div>
          <div className="flex justify-between border-t border-zinc-100 pt-1 text-lg font-semibold text-pink-600">
            <span>應付金額</span>
            <span>{fmtAmount(s.payable_amount)}</span>
          </div>
        </div>
      </div>
    </article>
  );
}
