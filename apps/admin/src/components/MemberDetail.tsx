"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import { MemberMergeModal } from "@/components/MemberMergeModal";
import { MemberDeleteModal } from "@/components/MemberDeleteModal";
import { WalletActionModal, type WalletActionMode } from "@/components/WalletActionModal";
import { Modal } from "@/components/Modal";
import { OrderDetail } from "@/components/OrderDetail";
import { orderStatusLabel } from "@/lib/orderStatus";
import { translateRpcError } from "@/lib/rpcError";
import { canAdjustWallet, isAdmin, useRole } from "@/lib/role";
import { walletLedgerTypeLabel, walletPaymentMethodLabel } from "@/lib/walletLedger";
import { maskLineUserId } from "@/lib/maskLineUserId";
import SpinButton from "@/components/SpinButton";

type Member = {
  id: number;
  member_no: string;
  phone: string | null;
  name: string | null;
  gender: "M" | "F" | "O" | null;
  birthday: string | null;
  email: string | null;
  tier_id: number | null;
  home_store_id: number | null;
  status: string;
  member_type: string | null;
  notes: string | null;
  admin_note: string | null;
  no_notify_pickup: boolean;
  no_new_order: boolean;
  avatar_url: string | null;
  line_user_id: string | null;
  joined_at: string;
  last_visit_at: string | null;
  merged_into_member_id: number | null;
};
type Tier = { id: number; name: string };
type Store = { id: number; code: string; name: string };

type MergedFrom = {
  merge_id: number;
  merged_at: string;
  reason: string | null;
  guest: {
    id: number;
    member_no: string;
    name: string | null;
    phone: string | null;
    avatar_url: string | null;
    joined_at: string;
  };
};

type PointsEntry = {
  id: number;
  change: number;
  balance_after: number;
  source_type: string;
  reason: string | null;
  created_at: string;
};

type WalletEntry = {
  id: number;
  change: number;
  balance_after: number;
  type: string;
  payment_method: string | null;
  reason: string | null;
  reverses: number | null;
  created_at: string;
};

type MemberOrder = {
  id: number;
  order_no: string;
  status: string;
  order_kind: string | null;
  pickup_store_id: number | null;
  created_at: string;
  campaign: { name: string } | { name: string }[] | null;
  customer_order_items: { qty: number; unit_price: number }[];
};

// 與 CampaignOrdersPanel 的 STATUS_BADGE 同款配色（+ partially_completed）
const ORDER_STATUS_BADGE: Record<string, string> = {
  pending: "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300",
  confirmed: "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300",
  shipping: "bg-cyan-100 text-cyan-800 dark:bg-cyan-950 dark:text-cyan-300",
  ready: "bg-emerald-100 text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300",
  partially_completed: "bg-teal-100 text-teal-800 dark:bg-teal-950 dark:text-teal-300",
  completed: "bg-zinc-200 text-zinc-700 dark:bg-zinc-700 dark:text-zinc-300",
  cancelled: "bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300",
  expired: "bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300",
  transferred_out: "bg-zinc-100 text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400",
};

export function MemberDetail({ memberId, onDeleted }: { memberId: number; onDeleted?: () => void }) {
  const [member, setMember] = useState<Member | null>(null);
  const [tier, setTier] = useState<Tier | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [points, setPoints] = useState(0);
  const [wallet, setWallet] = useState(0);
  const [pLedger, setPLedger] = useState<PointsEntry[]>([]);
  const [wLedger, setWLedger] = useState<WalletEntry[]>([]);
  const [orders, setOrders] = useState<MemberOrder[]>([]);
  const [orderDetail, setOrderDetail] = useState<{ id: number; no: string } | null>(null);
  const [tab, setTab] = useState<"orders" | "info" | "points" | "wallet" | "merges" | "test">("orders");
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [reloadTick, setReloadTick] = useState(0);
  const [mergeOpen, setMergeOpen] = useState<false | "guest-to-real" | "real-from-guest">(false);
  const [deleteOpen, setDeleteOpen] = useState(false);
  const [mergedFrom, setMergedFrom] = useState<MergedFrom[]>([]);
  const [savingFlags, setSavingFlags] = useState(false);
  const [draftAdminNote, setDraftAdminNote] = useState("");
  const [draftNoNotify, setDraftNoNotify] = useState(false);
  const [draftNoNewOrder, setDraftNoNewOrder] = useState(false);
  const [draftHomeStoreId, setDraftHomeStoreId] = useState<string>("");
  const [savingStore, setSavingStore] = useState(false);
  const [tenantId, setTenantId] = useState<string | null>(null);
  const [walletAction, setWalletAction] = useState<{ mode: WalletActionMode; reverseTarget?: WalletEntry } | null>(null);
  const role = useRole();
  const canAdjust = canAdjustWallet(role);

  async function saveFlags() {
    if (!member) return;
    setSavingFlags(true);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      const { error: e } = await sb.rpc("rpc_set_member_flags", {
        p_member_id: member.id,
        p_no_notify_pickup: draftNoNotify,
        p_no_new_order: draftNoNewOrder,
        p_admin_note: draftAdminNote,
        p_operator: operator,
      });
      if (e) { alert(`儲存失敗：${translateRpcError(e)}`); return; }
      setReloadTick((n) => n + 1);
    } finally {
      setSavingFlags(false);
    }
  }

  async function saveHomeStore() {
    if (!member) return;
    setSavingStore(true);
    try {
      const sb = getSupabase();
      const newId = draftHomeStoreId === "" ? null : Number(draftHomeStoreId);
      const { error: e } = await sb.rpc("rpc_set_member_home_store", {
        p_member_id: member.id,
        p_home_store_id: newId,
      });
      if (e) { alert(`儲存失敗：${translateRpcError(e)}`); return; }
      setReloadTick((n) => n + 1);
    } finally {
      setSavingStore(false);
    }
  }

  async function sendTestNotification() {
    if (!member) return;
    setSending(true);
    try {
      const sb = getSupabase();
      const { data: { session } } = await sb.auth.getSession();
      if (!session) throw new Error("No session");

      const resp = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-notify`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Authorization": `Bearer ${session.access_token}`,
        },
        body: JSON.stringify({
          member_id: memberId,
          title: "測試通知",
          message: `管理員已於 ${new Date().toLocaleString()} 發送測試通知`,
          url: "/",
        }),
      });

      const result = await resp.json();
      if (!resp.ok) throw new Error(result.error || "發送失敗");
      
      if (result.ok) {
        alert(`發送成功！送出 ${result.sent} 個裝置，失敗 ${result.failed} 個。`);
      } else {
        alert(`未發送：${result.message}`);
      }
    } catch (e) {
      alert(`錯誤：${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setSending(false);
    }
  }

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const sb = getSupabase();
      // operator tenant_id from JWT app_metadata（沿用 ProductImagesField pattern）
      const { data: sessData } = await sb.auth.getSession();
      const tid = (sessData.session?.user?.app_metadata as Record<string, unknown> | undefined)
        ?.tenant_id as string | undefined;
      if (!cancelled && tid) setTenantId(tid);

      const { data: m, error: err } = await sb
        .from("members")
        .select("id, member_no, phone, name, gender, birthday, email, tier_id, home_store_id, status, member_type, notes, admin_note, no_notify_pickup, no_new_order, avatar_url, line_user_id, joined_at, last_visit_at, merged_into_member_id")
        .eq("id", memberId).maybeSingle<Member>();
      if (cancelled) return;
      if (err) { setError(err.message); return; }
      if (!m) { setError("找不到會員"); return; }
      setMember(m);
      setDraftAdminNote(m.admin_note ?? "");
      setDraftNoNotify(!!m.no_notify_pickup);
      setDraftNoNewOrder(!!m.no_new_order);
      setDraftHomeStoreId(m.home_store_id ? String(m.home_store_id) : "");

      const [tierQ, storesQ, pb, wb, pl, wl, mm, od] = await Promise.all([
        m.tier_id ? sb.from("member_tiers").select("id, name").eq("id", m.tier_id).maybeSingle<Tier>() : Promise.resolve({ data: null }),
        sb.from("stores").select("id, code, name").eq("is_active", true).order("name"),
        sb.from("member_points_balance").select("balance").eq("member_id", memberId).maybeSingle<{ balance: number }>(),
        sb.from("wallet_balances").select("balance").eq("member_id", memberId).maybeSingle<{ balance: number }>(),
        sb.from("points_ledger").select("id, change, balance_after, source_type, reason, created_at").eq("member_id", memberId).order("created_at", { ascending: false }).limit(50),
        sb.from("wallet_ledger").select("id, change, balance_after, type, payment_method, reason, reverses, created_at").eq("member_id", memberId).order("created_at", { ascending: false }).limit(50),
        sb.from("member_merges")
          .select("id, created_at, reason, merged_member_id, members:merged_member_id (id, member_no, name, phone, avatar_url, joined_at)")
          .eq("primary_member_id", memberId)
          .order("created_at", { ascending: false }),
        sb.from("customer_orders")
          .select("id, order_no, status, order_kind, pickup_store_id, created_at, campaign:group_buy_campaigns(name), customer_order_items(qty, unit_price)")
          .eq("member_id", memberId)
          .order("created_at", { ascending: false }),
      ]);
      if (cancelled) return;
      setTier(tierQ.data as Tier | null);
      setStores((storesQ.data as Store[]) ?? []);
      setPoints(Number(pb.data?.balance ?? 0));
      setWallet(Number(wb.data?.balance ?? 0));
      setPLedger((pl.data as PointsEntry[]) ?? []);
      setWLedger((wl.data as WalletEntry[]) ?? []);
      setOrders((od.data as unknown as MemberOrder[]) ?? []);
      type MergeMemberRow = { id: number; member_no: string; name: string | null; phone: string | null; avatar_url: string | null; joined_at: string };
      type MergeRow = {
        id: number;
        created_at: string;
        reason: string | null;
        merged_member_id: number;
        members: MergeMemberRow | MergeMemberRow[] | null;
      };
      const mmRows = ((mm.data ?? []) as unknown as MergeRow[])
        .map<MergedFrom | null>((r) => {
          const guest = Array.isArray(r.members) ? r.members[0] : r.members;
          if (!guest) return null;
          return {
            merge_id: r.id,
            merged_at: r.created_at,
            reason: r.reason,
            guest,
          };
        })
        .filter((x): x is MergedFrom => x !== null);
      setMergedFrom(mmRows);
    })();
    return () => { cancelled = true; };
  }, [memberId, reloadTick]);

  const flagsDirty = !!member && (
    draftAdminNote !== (member.admin_note ?? "")
    || draftNoNotify !== !!member.no_notify_pickup
    || draftNoNewOrder !== !!member.no_new_order
  );

  if (error) {
    return (
      <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
        {error}
      </div>
    );
  }
  if (!member) return <div className="text-sm text-zinc-500">載入中…</div>;

  const isMerged = member.status === "merged";
  const isDeleted = member.status === "deleted";
  const hasLine = !!member.line_user_id;
  // 「合併到已綁 LINE 會員」：自己未綁 LINE + status≠merged 才出現
  const canMergeOut = !hasLine && !isMerged && !isDeleted;
  // 「合併未綁 LINE 會員進來」：自己已綁 LINE + status≠merged 才出現
  const canAbsorbGuest = hasLine && !isMerged && !isDeleted;
  // 刪除（GDPR 軟刪除）：僅管理員，且非已合併 / 已刪除
  const canDelete = isAdmin(role) && !isMerged && !isDeleted;

  return (
    <div className="space-y-5">
      <div className="flex items-center gap-3">
        <AvatarStack main={member} mergedFrom={mergedFrom} />
        <div className="flex-1">
          <div className="flex flex-wrap items-baseline gap-2 text-lg font-semibold">
            {member.name ?? "—"}
            {member.admin_note && (
              <span className="rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950 dark:text-amber-300" title="管理員備註（不對外顯示）">
                🔒 {member.admin_note}
              </span>
            )}
            {member.no_notify_pickup && (
              <span className="rounded bg-zinc-200 px-2 py-0.5 text-xs font-medium text-zinc-700 dark:bg-zinc-700 dark:text-zinc-200">🔕 不通知</span>
            )}
            {member.no_new_order && (
              <span className="rounded bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-950 dark:text-red-300">🚫 禁止加單</span>
            )}
            {member.status === "merged" && (
              <span className="rounded bg-zinc-300 px-2 py-0.5 text-xs font-medium text-zinc-700 line-through dark:bg-zinc-700 dark:text-zinc-300">已合併 → #{member.merged_into_member_id}</span>
            )}
            {member.member_type === "guest" && (
              <span className="rounded bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800 dark:bg-blue-950 dark:text-blue-300" title="LLM 從 LINE 留言解析的訪客會員">訪客</span>
            )}
          </div>
          <div className="font-mono text-xs text-zinc-500">#{member.member_no}</div>
        </div>
        {canMergeOut && (
          <SpinButton
            onClick={() => setMergeOpen("guest-to-real")}
            className="rounded-md border border-rose-300 px-3 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50 dark:border-rose-800 dark:text-rose-300 dark:hover:bg-rose-950"
            title="把這個未綁 LINE 的會員合併到已綁 LINE 的會員（訂單 / 點數 / 儲值會搬過去）"
          >
            🔗 合併到已綁 LINE 會員
          </SpinButton>
        )}
        {canAbsorbGuest && (
          <SpinButton
            onClick={() => setMergeOpen("real-from-guest")}
            className="rounded-md border border-emerald-300 px-3 py-1 text-xs font-medium text-emerald-700 hover:bg-emerald-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
            title="搜尋未綁 LINE 的舊會員並合併進來（訂單 / 點數 / 儲值會搬到此會員）"
          >
            📥 合併舊會員進來
          </SpinButton>
        )}
        {canDelete && (
          <SpinButton
            onClick={() => setDeleteOpen(true)}
            className="rounded-md border border-red-300 px-3 py-1 text-xs font-medium text-red-700 hover:bg-red-50 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950"
            title="刪除會員：清除個資、退卡、移除標籤；流水 / 訂單依稅務規定保留（不可還原）"
          >
            🗑️ 刪除會員
          </SpinButton>
        )}
      </div>

      {isDeleted && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          此會員已刪除（個資已清除）。歷史交易 / 流水紀錄依稅務規定保留。
        </div>
      )}

      {/* 黑名單 / 管理員備註 */}
      <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
        <div className="mb-2 text-xs font-medium text-zinc-500">管理員設定（不對外顯示）</div>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={draftNoNotify}
              onChange={(e) => setDraftNoNotify(e.target.checked)}
              className="h-4 w-4"
            />
            <span>🔕 黑名單：不發送取貨/到貨通知</span>
          </label>
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={draftNoNewOrder}
              onChange={(e) => setDraftNoNewOrder(e.target.checked)}
              className="h-4 w-4"
            />
            <span>🚫 黑名單：禁止此會員加新訂單</span>
          </label>
          <label className="block text-sm sm:col-span-2">
            <span className="mb-1 block text-xs text-zinc-500">暱稱備註（管理員專用，不會出現在小白單 / LIFF / 我的介面）</span>
            <input
              value={draftAdminNote}
              onChange={(e) => setDraftAdminNote(e.target.value)}
              placeholder="如：奧客 / 老闆親戚 / 常退貨"
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-900"
            />
          </label>
        </div>
        {flagsDirty && (
          <div className="mt-2 flex justify-end gap-2">
            <SpinButton
              onClick={() => {
                setDraftAdminNote(member.admin_note ?? "");
                setDraftNoNotify(!!member.no_notify_pickup);
                setDraftNoNewOrder(!!member.no_new_order);
              }}
              disabled={savingFlags}
              className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              還原
            </SpinButton>
            <SpinButton
              onClick={saveFlags}
              disabled={savingFlags}
              className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
            >
              {savingFlags ? "儲存中…" : "💾 儲存設定"}
            </SpinButton>
          </div>
        )}
      </div>

      {/* 取貨店 — admin 可改；改店守衛在 RPC 內檢查未取貨訂單 */}
      <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
        <div className="mb-2 flex items-center justify-between">
          <div className="text-xs font-medium text-zinc-500">取貨店（會員預設取貨店）</div>
          {member.home_store_id && (
            <span className="text-xs text-zinc-500">
              現：{stores.find((s) => s.id === member.home_store_id)?.name ?? `#${member.home_store_id}`}
            </span>
          )}
        </div>
        <div className="flex items-center gap-2">
          <select
            value={draftHomeStoreId}
            onChange={(e) => setDraftHomeStoreId(e.target.value)}
            className="flex-1 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          >
            <option value="">— 未指定 —</option>
            {stores.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
          {draftHomeStoreId !== (member.home_store_id ? String(member.home_store_id) : "") && (
            <>
              <SpinButton
                onClick={() => setDraftHomeStoreId(member.home_store_id ? String(member.home_store_id) : "")}
                disabled={savingStore}
                className="rounded-md border border-zinc-300 px-3 py-1 text-xs hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                還原
              </SpinButton>
              <SpinButton
                onClick={saveHomeStore}
                disabled={savingStore}
                className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-50"
              >
                {savingStore ? "儲存中…" : "💾 儲存"}
              </SpinButton>
            </>
          )}
        </div>
        <p className="mt-1 text-xs text-zinc-500">
          會員仍有未取貨訂單時，後端會擋下改店動作（保護既有訂單的取貨地點）。
        </p>
      </div>

      <div className="grid gap-3 sm:grid-cols-3">
        <Card label="等級">{tier?.name ?? "—"}</Card>
        <Card label="積分餘額"><span className="text-lg font-mono">{points.toLocaleString()}</span></Card>
        <Card label="儲值餘額"><span className="text-lg font-mono">{wallet.toLocaleString()}</span></Card>
      </div>

      <MemberMergeModal
        open={!!mergeOpen}
        onClose={() => setMergeOpen(false)}
        guestMember={mergeOpen === "guest-to-real"
          ? { id: member.id, name: member.name, phone: member.phone, member_no: member.member_no }
          : undefined}
        realMember={mergeOpen === "real-from-guest"
          ? { id: member.id, name: member.name, phone: member.phone, member_no: member.member_no }
          : undefined}
        onMerged={() => { setMergeOpen(false); setReloadTick((n) => n + 1); }}
      />

      <MemberDeleteModal
        open={deleteOpen}
        onClose={() => setDeleteOpen(false)}
        member={{ id: member.id, member_no: member.member_no, name: member.name }}
        onDeleted={() => {
          setDeleteOpen(false);
          setReloadTick((n) => n + 1);
          onDeleted?.();
        }}
      />

      {/* 訂單明細 — 點訂單分頁的列開啟；關閉時 reload，取貨/取消後餘額與訂單狀態才會同步 */}
      <Modal
        open={orderDetail !== null}
        onClose={() => { setOrderDetail(null); setReloadTick((n) => n + 1); }}
        title={`訂單明細 ${orderDetail?.no ?? ""}`}
        maxWidth="max-w-4xl"
      >
        {orderDetail !== null && (
          <OrderDetail
            orderId={orderDetail.id}
            onNavigate={(id, no) => setOrderDetail({ id, no })}
          />
        )}
      </Modal>

      {walletAction && tenantId && (
        <WalletActionModal
          open={true}
          onClose={() => setWalletAction(null)}
          onSuccess={() => setReloadTick((n) => n + 1)}
          tenantId={tenantId}
          memberId={member.id}
          mode={walletAction.mode}
          reverseTarget={walletAction.reverseTarget}
        />
      )}

      <div>
        <div className="flex gap-2 border-b border-zinc-200 dark:border-zinc-800">
          <TabBtn active={tab === "orders"}  onClick={() => setTab("orders")}>訂單 ({orders.length})</TabBtn>
          <TabBtn active={tab === "wallet"}  onClick={() => setTab("wallet")}>儲值金明細 ({wLedger.length})</TabBtn>
          <TabBtn active={tab === "points"}  onClick={() => setTab("points")}>積分明細 ({pLedger.length})</TabBtn>
          {mergedFrom.length > 0 && (
            <TabBtn active={tab === "merges"} onClick={() => setTab("merges")}>合併紀錄 ({mergedFrom.length})</TabBtn>
          )}
          <TabBtn active={tab === "info"}    onClick={() => setTab("info")}>會員資料</TabBtn>
          <TabBtn active={tab === "test"}    onClick={() => setTab("test")}>測試操作</TabBtn>
        </div>

        {tab === "orders" && (() => {
          // 統計沿用 CampaignOrdersPanel：取消/過期不入計；order_kind=offset 是抵減單，顯示負數
          let totalQty = 0, totalAmount = 0, normalCount = 0, offsetCount = 0;
          for (const o of orders) {
            const isOffset = o.order_kind === "offset";
            const isCancelled = o.status === "cancelled" || o.status === "expired";
            if (isOffset) offsetCount++;
            else if (!isCancelled) normalCount++;
            if (isCancelled) continue;
            for (const it of o.customer_order_items ?? []) {
              totalQty += Number(it.qty || 0);
              totalAmount += Number(it.qty || 0) * Number(it.unit_price || 0);
            }
          }
          return (
            <div className="mt-3 space-y-2">
              <div className="flex items-center justify-end">
                <Link
                  href={`/orders?q=${encodeURIComponent(member.member_no)}`}
                  className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                  title="到訂單頁以此會員編號搜尋（可再篩狀態 / 開團 / 日期）"
                >
                  完整訂單頁 →
                </Link>
              </div>
              <div className="max-h-[420px] overflow-auto rounded-md border border-zinc-200 dark:border-zinc-800">
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <thead className="sticky top-0 z-10 bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>時間</Th><Th>訂單號</Th><Th>開團</Th><Th>門市</Th><Th>狀態</Th><Th className="text-right">數量</Th><Th className="text-right">金額</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {orders.length === 0 ? (
                      <tr><td colSpan={7} className="p-6 text-center text-zinc-500">尚無訂單</td></tr>
                    ) : orders.map((o) => {
                      const campaign = Array.isArray(o.campaign) ? o.campaign[0] : o.campaign;
                      const store = stores.find((s) => s.id === o.pickup_store_id);
                      const items = o.customer_order_items ?? [];
                      const qty = items.reduce((s, i) => s + Number(i.qty || 0), 0);
                      const amt = items.reduce((s, i) => s + Number(i.qty || 0) * Number(i.unit_price || 0), 0);
                      const isOffset = o.order_kind === "offset";
                      const isCancelled = o.status === "cancelled" || o.status === "expired";
                      return (
                        <tr
                          key={o.id}
                          onClick={() => setOrderDetail({ id: o.id, no: o.order_no })}
                          className={`cursor-pointer ${isCancelled ? "opacity-50" : ""} hover:bg-zinc-50 dark:hover:bg-zinc-900`}
                          title="點此查看訂單明細"
                        >
                          <Td className="whitespace-nowrap text-xs text-zinc-500">{new Date(o.created_at).toLocaleString("zh-TW")}</Td>
                          <Td className="whitespace-nowrap font-mono text-xs">
                            {o.order_no}
                            {isOffset && (
                              <span className="ml-1.5 rounded bg-red-200 px-1 py-0.5 text-[10px] font-medium text-red-800 dark:bg-red-900 dark:text-red-300">抵減</span>
                            )}
                          </Td>
                          <Td className="max-w-[200px]">
                            <span className="block truncate" title={campaign?.name ?? undefined}>{campaign?.name ?? "—"}</span>
                          </Td>
                          <Td className="whitespace-nowrap text-zinc-600 dark:text-zinc-400">{store?.name ?? (o.pickup_store_id ? `#${o.pickup_store_id}` : "—")}</Td>
                          <Td className="whitespace-nowrap">
                            <span className={`inline-block rounded px-1.5 py-0.5 text-xs ${ORDER_STATUS_BADGE[o.status] ?? ORDER_STATUS_BADGE.pending}`}>
                              {orderStatusLabel(o.status)}
                            </span>
                          </Td>
                          <Td className={`text-right font-mono tabular-nums ${isOffset ? "text-red-700 dark:text-red-300" : ""}`}>
                            {isOffset ? `−${Math.abs(qty)}` : qty}
                          </Td>
                          <Td className={`text-right font-mono tabular-nums ${isOffset ? "text-red-700 dark:text-red-300" : ""}`}>
                            {isOffset ? `−$${Math.abs(amt).toLocaleString()}` : `$${amt.toLocaleString()}`}
                          </Td>
                        </tr>
                      );
                    })}
                  </tbody>
                  {orders.length > 0 && (
                    <tfoot className="bg-zinc-50 dark:bg-zinc-900">
                      <tr>
                        <td colSpan={4} className="px-4 py-2 text-right text-xs text-zinc-500">小計（不含取消/過期）</td>
                        <td className="px-4 py-2 text-xs text-zinc-500">
                          {normalCount} 筆{offsetCount > 0 && ` + ${offsetCount} 抵減`}
                        </td>
                        <td className="px-4 py-2 text-right font-mono tabular-nums font-semibold">{totalQty}</td>
                        <td className="px-4 py-2 text-right font-mono tabular-nums font-semibold">${totalAmount.toLocaleString()}</td>
                      </tr>
                    </tfoot>
                  )}
                </table>
              </div>
            </div>
          );
        })()}

        {tab === "wallet" && (
          <div className="mt-3 flex flex-wrap gap-2">
            <SpinButton
              onClick={() => tenantId && setWalletAction({ mode: "topup" })}
              disabled={!tenantId}
              className="rounded-md bg-emerald-600 px-3 py-1 text-xs font-medium text-white hover:bg-emerald-700 disabled:opacity-50"
            >+ 加值</SpinButton>
            <SpinButton
              onClick={() => tenantId && setWalletAction({ mode: "spend" })}
              disabled={!tenantId}
              className="rounded-md bg-amber-600 px-3 py-1 text-xs font-medium text-white hover:bg-amber-700 disabled:opacity-50"
            >− 扣款</SpinButton>
            <SpinButton
              onClick={() => tenantId && setWalletAction({ mode: "refund" })}
              disabled={!tenantId}
              className="rounded-md bg-sky-600 px-3 py-1 text-xs font-medium text-white hover:bg-sky-700 disabled:opacity-50"
            >↺ 退款</SpinButton>
            {canAdjust && (
              <SpinButton
                onClick={() => tenantId && setWalletAction({ mode: "adjust" })}
                disabled={!tenantId}
                className="rounded-md border border-zinc-400 bg-white px-3 py-1 text-xs font-medium text-zinc-800 hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-200 dark:hover:bg-zinc-700"
              >⚙ 調整</SpinButton>
            )}
          </div>
        )}

        {tab === "info" && (
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <Card label="手機"><span className="font-mono">{member.phone && !member.phone.startsWith("line:") ? member.phone : "—"}</span></Card>
            <Card label="Email">{member.email ?? "—"}</Card>
            <Card label="性別">{member.gender === "M" ? "男" : member.gender === "F" ? "女" : member.gender === "O" ? "其他" : "—"}</Card>
            <Card label="生日">{member.birthday ?? "—"}</Card>
            <Card label="加入時間">{new Date(member.joined_at).toLocaleString("zh-TW")}</Card>
            <Card label="最後消費">{member.last_visit_at ? new Date(member.last_visit_at).toLocaleString("zh-TW") : "—"}</Card>
            {member.line_user_id && (
              <Card label="LINE User ID">
                <span className="font-mono text-xs" title="完整 ID 已隱藏">{maskLineUserId(member.line_user_id)}</span>
              </Card>
            )}
            {member.notes && (
              <div className="sm:col-span-2">
                <Card label="備註"><div className="whitespace-pre-wrap text-sm">{member.notes}</div></Card>
              </div>
            )}
          </div>
        )}

        {tab === "merges" && mergedFrom.length > 0 && (
          <div className="mt-3 rounded-md border border-emerald-200 bg-emerald-50/40 p-3 dark:border-emerald-900 dark:bg-emerald-950/30">
            <div className="mb-2 text-[10px] font-normal text-emerald-700/70 dark:text-emerald-400/70">
              這些舊會員的訂單 / 點數 / 儲值都已搬到本會員名下
            </div>
            <ul className="divide-y divide-emerald-200 dark:divide-emerald-900">
              {mergedFrom.map((mf) => (
                <li key={mf.merge_id} className="flex flex-wrap items-center gap-3 py-2 text-sm">
                  {mf.guest.avatar_url ? (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={mf.guest.avatar_url} alt="" className="h-8 w-8 rounded-full object-cover ring-2 ring-emerald-300 dark:ring-emerald-700" />
                  ) : (
                    <div className="flex h-8 w-8 items-center justify-center rounded-full bg-zinc-200 text-xs text-zinc-500 ring-2 ring-emerald-300 dark:bg-zinc-700 dark:ring-emerald-700">
                      {mf.guest.name?.[0] ?? "?"}
                    </div>
                  )}
                  <div className="flex-1 min-w-[200px]">
                    <div className="font-medium">
                      {mf.guest.name ?? "—"}
                      <span className="ml-2 font-mono text-xs text-zinc-500">#{mf.guest.member_no}</span>
                    </div>
                    <div className="text-xs text-zinc-500">
                      {mf.guest.phone && !mf.guest.phone.startsWith("line:") ? mf.guest.phone : "—"}
                      　建檔：{new Date(mf.guest.joined_at).toLocaleDateString("zh-TW")}
                      　合併：{new Date(mf.merged_at).toLocaleDateString("zh-TW")}
                    </div>
                    {mf.reason && (
                      <div className="text-xs text-zinc-500">原因：{mf.reason}</div>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          </div>
        )}

        <div className={tab === "info" || tab === "merges" || tab === "orders" ? "hidden" : "mt-3 max-h-[420px] overflow-auto rounded-md border border-zinc-200 dark:border-zinc-800"}>
          {tab === "points" ? (
            <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
              <thead className="sticky top-0 z-10 bg-zinc-50 dark:bg-zinc-900">
                <tr>
                  <Th>時間</Th><Th>來源</Th><Th className="text-right">變動</Th><Th className="text-right">餘額</Th><Th>備註</Th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                {pLedger.length === 0 ? (
                  <tr><td colSpan={5} className="p-6 text-center text-zinc-500">尚無紀錄</td></tr>
                ) : pLedger.map((e) => (
                  <tr key={e.id}>
                    <Td className="text-xs text-zinc-500">{new Date(e.created_at).toLocaleString("zh-TW")}</Td>
                    <Td>{e.source_type}</Td>
                    <Td className={`text-right font-mono ${Number(e.change) >= 0 ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}`}>
                      {Number(e.change) >= 0 ? "+" : ""}{Number(e.change)}
                    </Td>
                    <Td className="text-right font-mono">{Number(e.balance_after)}</Td>
                    <Td className="text-xs text-zinc-500">{e.reason ?? "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : tab === "wallet" ? (
            (() => {
              const reversedIds = new Set(wLedger.map((x) => x.reverses).filter((v): v is number => typeof v === "number"));
              return (
                <table className="min-w-full divide-y divide-zinc-200 text-sm dark:divide-zinc-800">
                  <thead className="sticky top-0 z-10 bg-zinc-50 dark:bg-zinc-900">
                    <tr>
                      <Th>時間</Th><Th>類型</Th><Th>支付</Th><Th className="text-right">變動</Th><Th className="text-right">餘額</Th><Th>備註</Th><Th>動作</Th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-zinc-200 dark:divide-zinc-800">
                    {wLedger.length === 0 ? (
                      <tr><td colSpan={7} className="p-6 text-center text-zinc-500">尚無紀錄</td></tr>
                    ) : wLedger.map((e) => {
                      const reversible =
                        ["topup","spend","refund","adjust"].includes(e.type) &&
                        !reversedIds.has(e.id);
                      return (
                        <tr key={e.id}>
                          <Td className="text-xs text-zinc-500">{new Date(e.created_at).toLocaleString("zh-TW")}</Td>
                          <Td>{walletLedgerTypeLabel(e.type)}{e.reverses ? <span className="ml-1 text-[10px] text-zinc-400">→#{e.reverses}</span> : null}</Td>
                          <Td className="text-xs">{walletPaymentMethodLabel(e.payment_method)}</Td>
                          <Td className={`text-right font-mono ${Number(e.change) >= 0 ? "text-green-700 dark:text-green-400" : "text-red-700 dark:text-red-400"}`}>
                            {Number(e.change) >= 0 ? "+" : ""}{Number(e.change)}
                          </Td>
                          <Td className="text-right font-mono">{Number(e.balance_after)}</Td>
                          <Td className="text-xs text-zinc-500">{e.reason ?? "—"}</Td>
                          <Td className="text-xs">
                            {reversible && tenantId ? (
                              <SpinButton
                                onClick={() => setWalletAction({ mode: "reverse", reverseTarget: e })}
                                title={`沖銷 #${e.id}`}
                                className="rounded-md border border-zinc-300 px-2 py-0.5 text-[11px] hover:bg-zinc-100 dark:border-zinc-600 dark:hover:bg-zinc-800"
                              >↩ 沖銷</SpinButton>
                            ) : reversedIds.has(e.id) ? (
                              <span className="text-[10px] text-zinc-400">已沖銷</span>
                            ) : (
                              <span className="text-[10px] text-zinc-400">—</span>
                            )}
                          </Td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              );
            })()
          ) : (
            <div className="p-6">
              <h4 className="text-sm font-medium text-zinc-900 dark:text-zinc-100 mb-4">PWA 通知測試</h4>
              <p className="text-xs text-zinc-500 mb-4">
                此功能會向該會員所有已訂閱的 PWA 裝置發送一則測試通知。
                請確保會員已在手機/電腦上開啟通知權限。
              </p>
              <SpinButton
                onClick={sendTestNotification}
                disabled={sending}
                className="inline-flex items-center px-4 py-2 border border-transparent text-sm font-medium rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-blue-500 disabled:opacity-50"
              >
                {sending ? "發送中..." : "發送測試通知"}
              </SpinButton>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function AvatarStack({
  main,
  mergedFrom,
}: {
  main: { avatar_url: string | null; name: string | null };
  mergedFrom: MergedFrom[];
}) {
  // 顯示主頭像 + 最多 2 個小覆蓋頭像；3 個以上顯示 +N badge
  const overlays = mergedFrom.slice(0, 2);
  const extra = Math.max(0, mergedFrom.length - 2);
  return (
    <div className="relative h-12 w-12 shrink-0">
      {main.avatar_url ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={main.avatar_url} alt="" className="h-12 w-12 rounded-full object-cover ring-2 ring-white dark:ring-zinc-900" />
      ) : (
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-zinc-200 text-lg text-zinc-500 ring-2 ring-white dark:bg-zinc-800 dark:ring-zinc-900">
          {main.name?.[0] ?? "?"}
        </div>
      )}
      {overlays.map((mf, i) => (
        <span
          key={mf.merge_id}
          className="absolute h-6 w-6"
          style={{ right: i * -10, bottom: -4 }}
          title={`已合併：${mf.guest.name ?? "—"} #${mf.guest.member_no}`}
        >
          {mf.guest.avatar_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={mf.guest.avatar_url} alt="" className="h-6 w-6 rounded-full object-cover ring-2 ring-white dark:ring-zinc-900" />
          ) : (
            <span className="flex h-6 w-6 items-center justify-center rounded-full bg-zinc-300 text-[10px] text-zinc-600 ring-2 ring-white dark:bg-zinc-700 dark:text-zinc-300 dark:ring-zinc-900">
              {mf.guest.name?.[0] ?? "?"}
            </span>
          )}
        </span>
      ))}
      {extra > 0 && (
        <span
          className="absolute flex h-6 w-6 items-center justify-center rounded-full bg-emerald-600 text-[10px] font-bold text-white ring-2 ring-white dark:ring-zinc-900"
          style={{ right: -20, bottom: -4 }}
          title={`另有 ${extra} 個已合併虛擬會員`}
        >
          +{extra}
        </span>
      )}
    </div>
  );
}

function Card({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="rounded-md border border-zinc-200 p-3 dark:border-zinc-800">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className="mt-1">{children}</div>
    </div>
  );
}

function TabBtn({ active, onClick, children }: { active: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <SpinButton
      onClick={onClick}
      className={
        active
          ? "border-b-2 border-zinc-900 px-3 py-2 text-sm font-medium dark:border-zinc-100"
          : "border-b-2 border-transparent px-3 py-2 text-sm text-zinc-500 transition-colors hover:text-zinc-800 dark:hover:text-zinc-200"
      }
    >
      {children}
    </SpinButton>
  );
}

function Th({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <th className={`px-4 py-2 text-left text-xs font-medium uppercase tracking-wide text-zinc-500 ${className}`}>{children}</th>;
}

function Td({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  return <td className={`px-4 py-3 ${className}`}>{children}</td>;
}
