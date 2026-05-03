import StatusChip from "./StatusChip";

export type OrderItem = {
  id: number;
  sku_id: number;
  sku_code: string | null;
  product_name: string | null;
  variant_name: string | null;
  campaign_item_id: number | null;
  qty: number;
  unit_price: number;
  subtotal: number;
  status: string;
  notes: string | null;
  image_url: string | null;
};

export type OrderRow = {
  id: number;
  order_no: string;
  pickup_deadline: string | null;
  payable_amount: number;
  items_total: number;
  shipping_fee: number;
  discount_amount: number;
  arrived: boolean;
  settled: boolean;
  paid: boolean;
  shipped: boolean;
  items: OrderItem[];
  notes: string | null;
  created_at: string;
  campaign_name: string | null;
  campaign_cover_url: string | null;
  campaign_cutoff_date: string | null;
  store_name: string | null;
  settlement_no: string;
};

function fmtAmount(n: number | string | null | undefined): string {
  return Number(n ?? 0).toLocaleString();
}

function fmtDate(iso: string | null | undefined): string {
  if (!iso) return "-";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}/${m}/${day}`;
}

export default function OrderCard({ order }: { order: OrderRow }) {
  const totalQty = order.items.reduce((s, i) => s + Number(i.qty ?? 0), 0);
  const title = order.campaign_name ?? `訂單 ${order.order_no}`;

  return (
    <article className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
      <header className="flex items-start gap-3 px-4 pt-4 pb-3">
        {order.campaign_cover_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={order.campaign_cover_url}
            alt=""
            className="h-14 w-14 flex-shrink-0 rounded-xl object-cover"
          />
        ) : (
          <div className="flex h-14 w-14 flex-shrink-0 items-center justify-center rounded-xl bg-[#7676801a] text-2xl">
            📦
          </div>
        )}
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-[18px] font-semibold text-[var(--foreground)]">{title}</h3>
          <p className="mt-0.5 text-[14px] text-[var(--secondary-label)]">
            <span className="font-mono">{order.order_no}</span>
            <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
            {fmtDate(order.created_at)}
          </p>
          {order.campaign_cutoff_date && (
            <p className="text-[14px] text-[var(--secondary-label)]">
              結單日 {order.campaign_cutoff_date}
            </p>
          )}
        </div>
      </header>

      <div className="flex flex-wrap gap-1.5 px-4 pb-3">
        <StatusChip tone={order.arrived ? "ok" : "muted"} label={order.arrived ? "已到貨" : "未到貨"} />
      </div>

      <ul className="border-t border-[var(--separator)] px-4">
        {order.items.map((it, idx) => (
          <li
            key={it.id}
            className={`flex items-start gap-3 py-3 ${
              idx > 0 ? "border-t border-[var(--separator)]" : ""
            }`}
          >
            {it.image_url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                src={it.image_url}
                alt=""
                className="h-12 w-12 flex-shrink-0 rounded-lg object-cover bg-[#7676801a]"
              />
            ) : (
              <div className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-lg bg-[#7676801a] text-xl">
                📦
              </div>
            )}
            <div className="min-w-0 flex-1">
              <div className="text-[16px] text-[var(--foreground)]">
                {it.product_name ?? `SKU#${it.sku_id}`}
                {it.variant_name && (
                  <span className="ml-1 text-[var(--secondary-label)]">/ {it.variant_name}</span>
                )}
              </div>
              {it.sku_code && (
                <div className="font-mono text-[12px] text-[var(--tertiary-label)]">{it.sku_code}</div>
              )}
              <div className="text-[14px] text-[var(--secondary-label)]">
                {fmtAmount(it.unit_price)} × {it.qty}
              </div>
              {it.notes && (
                <div className="mt-0.5 text-[14px] text-[var(--secondary-label)]">📝 {it.notes}</div>
              )}
            </div>
            <div className="flex-shrink-0 text-right text-[16px] font-medium tabular-nums text-[var(--foreground)]">
              {fmtAmount(it.subtotal)}
            </div>
          </li>
        ))}
      </ul>

      {order.notes && (
        <div className="mx-4 mb-3 rounded-xl bg-[#7676801a] p-3 text-[14px] text-[var(--secondary-label)]">
          📝 {order.notes}
        </div>
      )}

      <div className="space-y-1 border-t border-[var(--separator)] px-4 py-3 text-[14px]">
        <div className="flex justify-between text-[var(--secondary-label)]">
          <span>商品（{totalQty} 件）</span>
          <span className="tabular-nums">{fmtAmount(order.items_total)}</span>
        </div>
        {Number(order.shipping_fee) > 0 && (
          <div className="flex justify-between text-[var(--secondary-label)]">
            <span>運費</span>
            <span className="tabular-nums">{fmtAmount(order.shipping_fee)}</span>
          </div>
        )}
        {Number(order.discount_amount) > 0 && (
          <div className="flex justify-between text-[var(--secondary-label)]">
            <span>折扣</span>
            <span className="tabular-nums">−{fmtAmount(order.discount_amount)}</span>
          </div>
        )}
        <div className="flex items-baseline justify-between pt-2">
          <span className="text-[16px] text-[var(--foreground)]">應付金額</span>
          <span className="text-[24px] font-semibold tabular-nums text-[var(--brand-strong)]">
            ${fmtAmount(order.payable_amount)}
          </span>
        </div>
      </div>

      <div className="border-t border-[var(--separator)] px-4 py-2.5 text-[12px] text-[var(--tertiary-label)]">
        結單編號 <span className="font-mono">{order.settlement_no}</span>
        {order.store_name && <span className="ml-2">· 取貨 {order.store_name}</span>}
      </div>
    </article>
  );
}
