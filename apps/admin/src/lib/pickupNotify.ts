import { getSupabase } from "@/lib/supabase";

export type NotifyTarget = {
  member_id: number;
  order_id: number;
  order_no: string;
  last_notify_pickup_at: string | null;
};

// 推播「您的商品到貨」給一批 (member, order) 名單。
// 會先去重：同會員只推一次、同訂單只標記一次 last_notify_pickup_at。
// 名單來源自己過黑名單（rpc_get_members_to_notify_for_transfer /
// rpc_manual_allocate_confirmed_orders 的 notify 都已濾掉 no_notify_pickup）。
// 回傳推播成功的會員數；任何失敗只 console.warn，不影響呼叫端流程。
export async function pushArrivalNotifications(list: NotifyTarget[]): Promise<number> {
  if (list.length === 0) return 0;
  const sb = getSupabase();

  // 去重：同一會員（可能跨多張調撥單 / 多張訂單）只推一次（取第一張當代表）
  const seenMembers = new Set<number>();
  const uniqueByMember = list.filter((r) => {
    if (seenMembers.has(r.member_id)) return false;
    seenMembers.add(r.member_id);
    return true;
  });

  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  if (!supabaseUrl) return 0;
  const { data: sess } = await sb.auth.getSession();
  const token = sess.session?.access_token;
  const operator = sess.session?.user?.id;
  if (!token) return 0;

  let success = 0;
  await Promise.allSettled(
    uniqueByMember.map(async (r) => {
      try {
        const resp = await fetch(`${supabaseUrl}/functions/v1/admin-notify`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${token}`,
          },
          body: JSON.stringify({
            member_id: r.member_id,
            title: "您的商品到貨",
            message: "點此開啟訂單頁查看",
            url: "/orders",
            category: "order_arrived",
          }),
        });
        if (resp.ok) success += 1;
      } catch (e) {
        console.warn(`push to member ${r.member_id} failed:`, e);
      }
    }),
  );

  // 不論推播成功與否，都把所有受影響訂單（含同會員多張，跨單去重）標 last_notify_pickup_at
  // 讓 /pickup 顯示「📨 上次通知 X」避免再手動重複推
  const seenOrders = new Set<number>();
  const uniqueOrders = list.filter((r) => {
    if (seenOrders.has(r.order_id)) return false;
    seenOrders.add(r.order_id);
    return true;
  });
  await Promise.allSettled(
    uniqueOrders.map((r) =>
      sb.rpc("rpc_mark_pickup_notified", {
        p_order_id: r.order_id,
        p_operator: operator ?? null,
      }),
    ),
  );

  return success;
}

// 收貨後推播「您的商品到貨」給受影響會員。可一次傳多張調撥單（批次收貨），
// 會先合併名單再去重。名單由 rpc_get_members_to_notify_for_transfer 提供
// （已過濾 no_notify_pickup 黑名單，且只含真的可取貨的訂單 —— 20260813 起
// 手動配單模式下沒配到的 confirmed 單不會被通知）。
// 回傳推播成功的會員數；任何失敗只 console.warn，不影響收貨流程。
export async function fanoutPickupNotifications(transferIds: number[]): Promise<number> {
  if (transferIds.length === 0) return 0;
  const sb = getSupabase();

  const results = await Promise.allSettled(
    transferIds.map((id) =>
      sb.rpc("rpc_get_members_to_notify_for_transfer", { p_transfer_id: id }),
    ),
  );
  const list: NotifyTarget[] = [];
  for (const r of results) {
    if (r.status !== "fulfilled") {
      console.warn("get members for push failed:", r.reason);
      continue;
    }
    if (r.value.error) {
      console.warn("get members for push failed:", r.value.error.message);
      continue;
    }
    list.push(...((r.value.data as NotifyTarget[] | null) ?? []));
  }
  return pushArrivalNotifications(list);
}
