import { cleanCampaignText } from "@/lib/text";
import StatusChip from "@/components/StatusChip";

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
  stockout?: boolean;
  notes: string | null;
  image_url: string | null;
};

export type OrderRow = {
  id: number;
  order_no: string;
  status?: string | null;
  stockout_at?: string | null;
  pickup_deadline: string | null;
  payable_amount: number;
  /** 應付 − 已用儲值金扣抵；v_customer_order_summary 有給，訂單列表的「尚未付款」用它加總 */
  balance_due?: number;
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
  // 斷貨 / 已取消的品項照樣列出來（畫成刪除線 + 「斷貨」標），但不算件數 —
  // items_total / payable_amount 從 20260808000010 起就不含這些行了，
  // 件數要跟著排除，否則「商品（5 件）$218」對不起來。
  const totalQty = order.items.reduce(
    (s, i) => (["cancelled", "expired"].includes(i.status) ? s : s + Number(i.qty ?? 0)),
    0,
  );
  const title = cleanCampaignText(order.campaign_name) || "訂單";

  return (
    <article className="card overflow-hidden">
      <header className="bg-[var(--brand-soft)]/35 px-4 pt-4 pb-3">
        <div className="flex items-center gap-2">
          <h3 className="min-w-0 truncate text-[18px] font-bold text-[var(--foreground)]">{title}</h3>
          {order.stockout_at && (
            <StatusChip tone="danger" label="斷貨" />
          )}
        </div>
        {order.stockout_at && (
          <p className="mt-1 text-[13px] text-[#c4271d]">
            ⛔ 供應商斷貨，本筆訂單已取消，造成不便敬請見諒
          </p>
        )}
        <p className="mt-0.5 text-[14px] text-[var(--secondary-label)]">
          {fmtDate(order.created_at)}
          {order.store_name && (
            <>
              <span className="mx-1.5 text-[var(--tertiary-label)]">·</span>
              取貨：{order.store_name}
            </>
          )}
        </p>
        {order.campaign_cutoff_date && (
          <p className="text-[14px] text-[var(--secondary-label)]">
            結單日 {order.campaign_cutoff_date}
          </p>
        )}
      </header>

      <ul className="border-t border-[var(--separator)] px-4">
        {order.items.map((it, idx) => (
          <li
            key={it.id}
            className={`flex items-start gap-3 py-3 ${
              idx > 0 ? "border-t border-[var(--separator)]" : ""
            }`}
          >
            <div className="min-w-0 flex-1">
              {it.variant_name && (
                <div className={`text-[16px] ${it.stockout ? "text-[var(--secondary-label)] line-through" : "text-[var(--foreground)]"}`}>
                  {it.variant_name}
                  {it.stockout && (
                    <span className="ml-1.5 inline-block no-underline">
                      <StatusChip tone="danger" label="斷貨" />
                    </span>
                  )}
                </div>
              )}
              {!it.variant_name && it.stockout && (
                <div><StatusChip tone="danger" label="斷貨" /></div>
              )}
              <div className="text-[14px] text-[var(--secondary-label)]">
                {fmtAmount(it.unit_price)} × {it.qty}
              </div>
              {/* it.notes 是內部備註（補貨申請 / 轉單軌跡等），顧客端不顯示 */}
            </div>
            <div className={`flex-shrink-0 text-right text-[16px] font-medium tabular-nums ${it.stockout ? "text-[var(--secondary-label)] line-through" : "text-[var(--foreground)]"}`}>
              {fmtAmount(it.subtotal)}
            </div>
          </li>
        ))}
      </ul>

      {/* order.notes 同為內部備註，顧客端不顯示 */}

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
    </article>
  );
}
