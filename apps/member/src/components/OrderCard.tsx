import StatusChip from "./StatusChip";

export type OrderRow = {
  id: number;
  order_no: string;
  pickup_deadline: string | null;
  payable_amount: number;
  arrived: boolean;
  settled: boolean;
  paid: boolean;
  shipped: boolean;
  items: Array<{ qty: number; unit_price: number; status: string }>;
  notes: string | null;
};

export default function OrderCard({
  order,
  campaignName,
}: {
  order: OrderRow;
  campaignName?: string;
}) {
  const totalQty = order.items.reduce((s, i) => s + Number(i.qty ?? 0), 0);

  return (
    <article className="rounded-md border border-pink-100 bg-white p-4 shadow-sm">
      <div className="flex items-start justify-between gap-2">
        <div className="flex-1">
          <h3 className="text-sm font-medium text-zinc-900">
            {campaignName ?? `訂單 ${order.order_no}`}
          </h3>
          <p className="mt-0.5 text-xs text-zinc-400">
            {order.pickup_deadline ? `截止 ${order.pickup_deadline}・` : ""}共 {totalQty} 件
          </p>
        </div>
        <div className="text-right">
          <div className="text-xs text-zinc-400">總金額</div>
          <div className="text-base font-semibold text-pink-600">
            {Number(order.payable_amount).toLocaleString()}
          </div>
        </div>
      </div>

      <div className="mt-2 flex flex-wrap gap-1.5">
        <StatusChip tone={order.arrived ? "ok" : "muted"} label={order.arrived ? "全到" : "未到"} />
        <StatusChip tone={order.settled ? "ok" : "muted"} label={order.settled ? "全結" : "未結"} />
        <StatusChip tone={order.paid    ? "ok" : "muted"} label={order.paid    ? "已付" : "未付"} />
        <StatusChip tone={order.shipped ? "ok" : "muted"} label={order.shipped ? "已寄" : "未寄"} />
      </div>

      {order.notes && (
        <p className="mt-2 text-xs text-zinc-500">📝 {order.notes}</p>
      )}
    </article>
  );
}
