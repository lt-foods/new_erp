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
    <article className="overflow-hidden rounded-md border border-pink-100 bg-white shadow-sm">
      <header className="flex items-start gap-3 border-b border-pink-50 p-4">
        {order.campaign_cover_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={order.campaign_cover_url}
            alt=""
            className="h-16 w-16 flex-shrink-0 rounded-md object-cover"
          />
        ) : (
          <div className="flex h-16 w-16 flex-shrink-0 items-center justify-center rounded-md bg-pink-100 text-2xl">
            📦
          </div>
        )}
        <div className="min-w-0 flex-1">
          <h3 className="truncate text-lg font-medium text-zinc-900">{title}</h3>
          <p className="mt-1 text-sm text-zinc-500">
            訂單編號：<span className="font-mono">{order.order_no}</span>
          </p>
          <p className="text-sm text-zinc-500">
            訂購日期：{fmtDate(order.created_at)}
            {order.campaign_cutoff_date ? `・結單日：${order.campaign_cutoff_date}` : ""}
          </p>
        </div>
      </header>

      <div className="space-y-3 p-4">
        <div className="flex flex-wrap gap-1.5">
          <StatusChip tone={order.arrived ? "ok" : "muted"} label={order.arrived ? "全到" : "未到"} />
          <StatusChip tone={order.settled ? "ok" : "muted"} label={order.settled ? "全結" : "未結"} />
          <StatusChip tone={order.paid    ? "ok" : "muted"} label={order.paid    ? "已付" : "未付"} />
          <StatusChip tone={order.shipped ? "ok" : "muted"} label={order.shipped ? "已寄" : "未寄"} />
        </div>

        <ul className="divide-y divide-zinc-100">
          {order.items.map((it) => (
            <li key={it.id} className="flex items-start justify-between gap-2 py-2">
              <div className="min-w-0 flex-1">
                <div className="text-base text-zinc-900">
                  {it.product_name ?? `SKU#${it.sku_id}`}
                  {it.variant_name && (
                    <span className="ml-1 text-sm text-zinc-500">/ {it.variant_name}</span>
                  )}
                </div>
                {it.sku_code && (
                  <div className="font-mono text-xs text-zinc-400">{it.sku_code}</div>
                )}
                <div className="text-sm text-zinc-500">
                  {fmtAmount(it.unit_price)} × {it.qty}
                </div>
                {it.notes && (
                  <div className="mt-0.5 text-sm text-zinc-500">📝 {it.notes}</div>
                )}
              </div>
              <div className="flex-shrink-0 text-right">
                <div className="text-base font-medium text-zinc-900">
                  {fmtAmount(it.subtotal)}
                </div>
              </div>
            </li>
          ))}
        </ul>

        {order.notes && (
          <div className="rounded-md bg-zinc-50 p-2 text-sm text-zinc-600">
            📝 {order.notes}
          </div>
        )}

        <div className="space-y-1 border-t border-zinc-100 pt-3 text-sm">
          <div className="flex justify-between text-zinc-500">
            <span>商品 ({totalQty} 件)</span>
            <span>{fmtAmount(order.items_total)}</span>
          </div>
          {Number(order.shipping_fee) > 0 && (
            <div className="flex justify-between text-zinc-500">
              <span>運費</span>
              <span>{fmtAmount(order.shipping_fee)}</span>
            </div>
          )}
          {Number(order.discount_amount) > 0 && (
            <div className="flex justify-between text-zinc-500">
              <span>折扣</span>
              <span>-{fmtAmount(order.discount_amount)}</span>
            </div>
          )}
          <div className="flex justify-between border-t border-zinc-100 pt-1 text-lg font-semibold text-pink-600">
            <span>應付金額</span>
            <span>{fmtAmount(order.payable_amount)}</span>
          </div>
        </div>

        <div className="text-xs text-zinc-400">
          結單編號：<span className="font-mono">{order.settlement_no}</span>
          {order.store_name && <span>・取貨：{order.store_name}</span>}
        </div>
      </div>
    </article>
  );
}
