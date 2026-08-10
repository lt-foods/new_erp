import StatusChip from "./StatusChip";

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
  /** 還沒領走的金額（@20260810000000）；0 = 貨都領完了 = 現金都收了 */
  outstanding_amount?: number;
};

function fmtAmount(n: number): string {
  return Number(n ?? 0).toLocaleString();
}

function Row({
  label,
  value,
}: {
  label: string;
  value: React.ReactNode;
}) {
  return (
    <div className="flex items-start justify-between gap-3 border-t border-[var(--separator)] py-3 first:border-t-0">
      <span className="text-[14px] text-[var(--secondary-label)]">{label}</span>
      <span className="max-w-[60%] text-right text-[16px] text-[var(--foreground)]">{value}</span>
    </div>
  );
}

export default function SettlementCard({ settlement: s }: { settlement: SettlementRow }) {
  // payment_status 全站從來沒被寫成 'paid'（取貨當下收現金，不回寫欄位），
  // 只看它會讓每一張已取貨的單都掛「未付款」。以「還有沒有貨沒領」為準。
  const paid =
    s.payment_status === "paid" ||
    (s.outstanding_amount != null && Number(s.outstanding_amount) <= 0);
  const shipped = ["shipping", "completed"].includes(s.status);

  return (
    <article className="card overflow-hidden">
      <header className="flex items-center justify-between gap-2 bg-[var(--brand-soft)]/35 px-4 pt-3.5 pb-3">
        <div>
          <div className="text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">結單編號</div>
          <div className="font-mono text-[17px] font-bold text-[var(--foreground)]">{s.settlement_no}</div>
        </div>
        <div className="flex gap-1.5">
          <StatusChip tone={paid ? "ok" : "warn"} label={paid ? "已付款" : "未付款"} />
          <StatusChip tone={shipped ? "ok" : "muted"} label={shipped ? "已出貨" : "未出貨"} />
        </div>
      </header>

      <section className="border-t border-[var(--separator)] px-4">
        <div className="py-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">付款資訊</div>
        <Row label="付款方式" value={s.payment_method ?? "—"} />
        <Row label="匯款金額" value={<span className="tabular-nums">{fmtAmount(s.remit_amount)}</span>} />
        <Row label="匯款時間" value={s.remit_at ?? "—"} />
        <Row label="匯款備註" value={s.remit_note ?? "—"} />
      </section>

      <section className="border-t border-[var(--separator)] px-4">
        <div className="py-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">出貨資訊</div>
        <Row label="出貨方式" value={s.shipping_method ?? "—"} />
        <Row label="收件電話" value={s.shipping_phone ?? "—"} />
        {s.shipping_address && <Row label="收件地址" value={s.shipping_address} />}
        <Row label="出貨備註" value={s.shipping_note ?? "—"} />
      </section>

      <section className="border-t border-[var(--separator)] space-y-1 px-4 py-3 text-[14px]">
        <div className="flex justify-between text-[var(--secondary-label)]">
          <span>商品總額</span>
          <span className="tabular-nums">{fmtAmount(s.items_total)}</span>
        </div>
        <div className="flex justify-between text-[var(--secondary-label)]">
          <span>運費</span>
          <span className="tabular-nums">{fmtAmount(s.shipping_fee)}</span>
        </div>
        <div className="flex justify-between text-[var(--secondary-label)]">
          <span>促銷折扣</span>
          <span className="tabular-nums">
            {s.discount_amount > 0 ? `−${fmtAmount(s.discount_amount)}` : "0"}
          </span>
        </div>
        <div className="flex items-baseline justify-between pt-2">
          <span className="text-[16px] text-[var(--foreground)]">應付金額</span>
          <span className="text-[24px] font-semibold tabular-nums text-[var(--brand-strong)]">
            ${fmtAmount(s.payable_amount)}
          </span>
        </div>
      </section>
    </article>
  );
}
