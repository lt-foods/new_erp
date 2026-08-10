"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner, { LoadingScreen } from "@/components/Spinner";
import { PushNotificationManager } from "@/components/PushNotificationManager";
import { usePushNotification } from "@/lib/usePushNotification";
import { useUnreadNotifications } from "@/lib/useUnreadNotifications";

type MemberData = {
  member_id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  email: string | null;
  birthday: string | null;
  gender: string | null;
  home_store_id: number | null;
  home_store_name: string | null;
  avatar_url: string | null;
  status: string;
};

type Overview = {
  store: {
    id: number;
    code: string;
    name: string;
    banner_url: string | null;
    description: string | null;
    payment_methods_text: string | null;
    shipping_methods_text: string | null;
  };
  receivable_amount: number;
  active_orders_count: number;
};

type WalletInfo = {
  balance: number;
  last_movement_at: string | null;
};

export default function MePage() {
  const router = useRouter();
  const [loading, setLoading] = useState(true);
  const [me, setMe] = useState<MemberData | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
  const [wallet, setWallet] = useState<WalletInfo | null>(null);
  const [isPWA, setIsPWA] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [lineName, setLineName] = useState<string | null>(null);
  const [linePicture, setLinePicture] = useState<string | null>(null);
  const [lineUserId, setLineUserId] = useState<string | null>(null);
  const [storeId, setStoreId] = useState<string | null>(null);

  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [form, setForm] = useState({ name: "", phone: "", birthday: "", email: "" });

  // 推播訂閱狀態 lift 到頁面層,頭像區跟底部 PushNotificationManager 共用
  const pushState = usePushNotification(getSession()?.token ?? null);

  // 已安裝 App 才在頭像上掛通知鈴鐺,沿用 tab bar 同一份未讀數
  const { count: unreadCount } = useUnreadNotifications();

  // PWA share code
  const [pwaCode, setPwaCode] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [generating, setGenerating] = useState(false);

  async function generatePwaCode() {
    const s = getSession();
    if (!s) {
      setError("session 失效，請重新登入");
      return;
    }
    setGenerating(true);
    setError(null);
    setCopied(false);
    try {
      const data = await callLiffApi<{ code: string }>(s.token, {
        action: "generate_pwa_auth_code",
        line_name: lineName,
        line_picture: linePicture,
      });
      setPwaCode(data.code);
      try {
        await navigator.clipboard.writeText(data.code);
        setCopied(true);
      } catch {
        // 部分情境（非 https / 沒 user gesture）會失敗，碼仍會顯示給使用者手動複製
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setGenerating(false);
    }
  }

  useEffect(() => {
    if (typeof window !== "undefined") {
      setIsPWA(
        (window.navigator as { standalone?: boolean }).standalone === true ||
        window.matchMedia("(display-mode: standalone)").matches,
      );
    }

    consumeFragmentToSession();
    const s = getSession();
    if (!s) {
      setError("尚未登入");
      setLoading(false);
      return;
    }
    setLineName(s.lineName);
    setLinePicture(s.linePicture);
    setLineUserId(s.lineUserId);
    setStoreId(s.storeId);

    (async () => {
      try {
        const [meData, ovData, wData] = await Promise.all([
          callLiffApi<MemberData>(s.token, { action: "get_me" }),
          callLiffApi<Overview>(s.token, { action: "get_overview" }).catch(() => null),
          callLiffApi<WalletInfo>(s.token, { action: "get_wallet" }).catch((e) => {
            console.warn("[liff] get_wallet failed; wallet card hidden:", e);
            return null;
          }),
        ]);
        setMe(meData);
        if (ovData) setOverview(ovData);
        if (wData) setWallet(wData);
        setForm({
          name: meData.name ?? "",
          phone: meData.phone ?? "",
          birthday: meData.birthday ?? "",
          email: meData.email ?? "",
        });
      } catch (e) {
        setError(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, []);

  async function onSave() {
    const s = getSession();
    if (!s) return setError("session 失效");
    setSaving(true);
    setError(null);
    try {
      await callLiffApi(s.token, {
        action: "update_me",
        name: form.name,
        phone: form.phone,
        birthday: form.birthday,
        email: form.email,
      });
      const data = await callLiffApi<MemberData>(s.token, { action: "get_me" });
      setMe(data);
      setEditing(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return (
      <PageShell title="會員中心">
        <LoadingScreen />
      </PageShell>
    );
  }

  if (!me) {
    return (
      <PageShell title="會員中心">
        <div className="px-5 pt-6 text-center">
          <p className="text-[15px] text-[var(--secondary-label)]">{error ?? "尚未登入，請回首頁。"}</p>
          <a href="/" className="mt-4 inline-block text-[15px] text-[var(--ios-blue)]">回首頁</a>
        </div>
      </PageShell>
    );
  }

  const avatarSrc = me.avatar_url ?? linePicture;
  const displayName = me.name ?? lineName ?? "(未提供)";

  const rightAction = !editing ? (
    <button
      onClick={() => setEditing(true)}
      className="text-[17px] text-[var(--ios-blue)] active:opacity-60"
    >
      編輯
    </button>
  ) : null;

  return (
    <PageShell title="會員中心" rightAction={rightAction}>
      <div className="space-y-4 px-4 pt-2 pb-6">
        {error && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[14px] text-[#c4271d]">
            {error}
          </div>
        )}

        {/* LINE 綁定卡片 */}
        <section className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
          <div className="flex items-start gap-3 px-4 py-4">
            <div className="relative flex-shrink-0">
              {avatarSrc ? (
                // eslint-disable-next-line @next/next/no-img-element
                <img src={avatarSrc} alt="" className="h-16 w-16 rounded-full object-cover" />
              ) : (
                <div className="flex h-16 w-16 items-center justify-center rounded-full bg-[#7676801a] text-2xl text-[var(--secondary-label)]">
                  {displayName[0]}
                </div>
              )}
              {/* 已安裝 App(standalone)的使用者才在頭像旁顯示通知鈴鐺,點擊進通知頁 */}
              {isPWA && (
                <Link
                  href="/notifications"
                  aria-label={unreadCount > 0 ? `通知,${unreadCount} 則未讀` : "通知"}
                  className="absolute -bottom-1 -right-1 flex h-7 w-7 items-center justify-center rounded-full bg-[var(--card-bg)] text-[var(--ios-blue)] shadow-[0_1px_4px_rgba(0,0,0,0.18)] active:opacity-70"
                >
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} className="h-4 w-4">
                    <path strokeLinecap="round" strokeLinejoin="round" d="M6 16V11a6 6 0 1 1 12 0v5l1.5 2H4.5L6 16Z" />
                    <path strokeLinecap="round" strokeLinejoin="round" d="M10 20a2 2 0 0 0 4 0" />
                  </svg>
                  {unreadCount > 0 && (
                    <span className="absolute -right-0.5 -top-0.5 h-2.5 w-2.5 rounded-full bg-[var(--ios-red)] ring-2 ring-[var(--card-bg)]" />
                  )}
                </Link>
              )}
            </div>
            <div className="min-w-0 flex-1">
              <div className="text-[20px] font-semibold text-[var(--foreground)]">{displayName}</div>
              <div className="font-mono text-[13px] text-[var(--secondary-label)]">{me.member_no}</div>
              <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
                <span className="inline-flex items-center gap-1 rounded-full bg-[#06C755]/15 px-2.5 py-[3px] text-[12px] font-medium text-[#067a37]">
                  ✓ 已綁定 LINE
                </span>
                {pushState.subscription && (
                  <span className="inline-flex items-center gap-1 rounded-full bg-[var(--ios-blue)]/15 px-2.5 py-[3px] text-[12px] font-medium text-[var(--ios-blue)]">
                    🔔 已啟用通知
                  </span>
                )}
                {/* 取貨店 = members.home_store_id（admin 設、place_member_order 實際取貨依據）。
                    刻意不用 overview/JWT store：那是「這次從哪個 OA 進來」，跟實際取貨店常不一致，
                    且 admin 改店後永遠不同步、反而誤導會員。改抓 home_store_name 後，admin 改店、
                    會員重開 /me（get_me 即時讀）就同步。 */}
                {me.home_store_name && (
                  <span className="inline-flex items-center gap-1 rounded-full bg-[#7676801f] px-2.5 py-[3px] text-[12px] font-medium text-[var(--secondary-label)]">
                    📍 取貨 {me.home_store_name}
                  </span>
                )}
              </div>
            </div>
            {/* 右上角動作:
                 - 非 PWA → 「PWA 碼」(把 session 帶到 PWA)
                 - PWA + 還沒訂閱 → 「開啟通知」
                 - 其他狀態不顯示 */}
            {!isPWA ? (
              <button
                onClick={generatePwaCode}
                disabled={generating}
                className="flex flex-shrink-0 items-center gap-1.5 rounded-full bg-[var(--ios-blue)] px-3 py-1.5 text-[13px] font-medium text-white active:opacity-80 disabled:opacity-50"
              >
                {generating ? <Spinner size={15} onColor /> : "PWA 碼"}
              </button>
            ) : pushState.isSupported && !pushState.subscription ? (
              <button
                onClick={pushState.subscribe}
                className="flex-shrink-0 rounded-full bg-[var(--ios-blue)] px-3 py-1.5 text-[13px] font-medium text-white active:opacity-80"
              >
                開啟通知
              </button>
            ) : null}
          </div>

          {pwaCode && (
            <div className="border-t border-[var(--separator)] bg-[#7676800a] px-4 py-3 text-center">
              <div className="text-[12px] text-[var(--secondary-label)]">
                {copied ? "✓ 已複製到剪貼簿" : "請手動複製"}　·　5 分鐘內有效
              </div>
              <div className="mt-1 select-all font-mono text-[28px] font-bold tracking-[0.4em] text-[var(--foreground)]">
                {pwaCode}
              </div>
              <p className="mt-1 text-[11px] text-[var(--tertiary-label)]">
                到 PWA App 首頁的「6 位數驗證碼」欄位貼上
              </p>
            </div>
          )}
        </section>

        {/* 在 LINE 內 → 引導去裝 PWA。在 PWA 內已有 bar tab「商品」可進,不再重複 CTA */}
        {!isPWA && (
          <a
            href="/install"
            className="block overflow-hidden rounded-2xl bg-gradient-to-r from-[var(--brand-strong)] to-[#ff9500] p-5 text-left text-white shadow-[0_2px_8px_rgba(0,0,0,0.08)] active:opacity-90"
          >
            <div className="flex items-center justify-between gap-3">
              <div>
                <div className="text-[14px] font-medium opacity-90">行動下單更方便</div>
                <div className="mt-0.5 text-[22px] font-bold leading-tight">安裝 App →</div>
                <div className="mt-1 text-[13px] opacity-85">加入主畫面後可離線、推播、一鍵下單</div>
              </div>
              <div className="text-5xl">📱</div>
            </div>
          </a>
        )}

        {/* 未結金額 + 進行中訂單 */}
        {overview && (
          <section className="rounded-2xl bg-[var(--card-bg)] px-5 py-4 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
            <div className="text-[14px] text-[var(--secondary-label)]">未結單金額</div>
            <div className="mt-1 flex items-baseline gap-1">
              <span className="text-[34px] font-semibold tabular-nums text-[var(--brand-strong)] leading-none">
                ${Number(overview.receivable_amount).toLocaleString()}
              </span>
            </div>
            <div className="mt-1 text-[12px] text-[var(--tertiary-label)]">
              已訂購但還沒領走的金額；取貨時付款，領完就不再計入
            </div>
            <a
              href="/orders"
              className="mt-3 flex w-full items-center justify-between rounded-xl bg-[#7676801a] px-3 py-3 text-[16px] text-[var(--foreground)] active:bg-[#76768033]"
            >
              <span>
                {overview.active_orders_count > 0
                  ? `進行中訂單 ${overview.active_orders_count} 筆`
                  : "查看我的訂單"}
              </span>
              <span className="text-[var(--ios-gray)]">›</span>
            </a>
          </section>
        )}

        {/* 儲值金餘額卡 — 永遠顯示（即便為 0，讓客人知道有此功能 + 可在門市加值） */}
        {wallet && (
          <section className="rounded-2xl bg-[var(--card-bg)] px-5 py-4 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
            <div className="text-[14px] text-[var(--secondary-label)]">💰 儲值金餘額</div>
            <div className="mt-1 flex items-baseline gap-1">
              <span className="text-[34px] font-semibold tabular-nums leading-none text-[var(--foreground)]">
                ${Number(wallet.balance).toLocaleString()}
              </span>
            </div>
            <a
              href="/wallet"
              className="mt-3 flex w-full items-center justify-between rounded-xl bg-[#7676801a] px-3 py-3 text-[16px] text-[var(--foreground)] active:bg-[#76768033]"
            >
              <span>查看儲值金明細</span>
              <span className="text-[var(--ios-gray)]">›</span>
            </a>
            <div className="mt-2 text-[12px] text-[var(--tertiary-label)]">
              儲值金不可退現；可在門市加值或結帳時抵扣
            </div>
          </section>
        )}

        {/* 店家資訊 — 店名已在頭像 chip 顯示,這裡只展開 banner / 賣場介紹 / 付款 / 出貨 */}
        {overview && (overview.store.banner_url || overview.store.description || overview.store.payment_methods_text || overview.store.shipping_methods_text) && (
          <section>
            <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
              店家資訊
            </div>
            <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
              {overview.store.banner_url && (
                // eslint-disable-next-line @next/next/no-img-element
                <img
                  src={overview.store.banner_url}
                  alt=""
                  className="h-36 w-full object-cover"
                />
              )}
              {overview.store.description && (
                <div className="border-b border-[var(--separator)] px-4 py-3.5">
                  <div className="text-[13px] text-[var(--secondary-label)]">賣場介紹</div>
                  <p className="mt-0.5 whitespace-pre-wrap text-[15px] text-[var(--foreground)]">
                    {overview.store.description}
                  </p>
                </div>
              )}
              {overview.store.payment_methods_text && (
                <div className="border-b border-[var(--separator)] px-4 py-3.5">
                  <div className="text-[13px] text-[var(--secondary-label)]">付款</div>
                  <p className="mt-0.5 whitespace-pre-wrap text-[15px] text-[var(--foreground)]">
                    {overview.store.payment_methods_text}
                  </p>
                </div>
              )}
              {overview.store.shipping_methods_text && (
                <div className="px-4 py-3.5">
                  <div className="text-[13px] text-[var(--secondary-label)]">出貨</div>
                  <p className="mt-0.5 whitespace-pre-wrap text-[15px] text-[var(--foreground)]">
                    {overview.store.shipping_methods_text}
                  </p>
                </div>
              )}
            </div>
          </section>
        )}

        {!editing ? (
          /* 檢視模式 — iOS settings-style */
          <section>
            <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
              個人資料
            </div>
            <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
              <InfoRow label="手機" value={me.phone ?? null} mono />
              <InfoRow label="生日" value={me.birthday ?? null} />
              <InfoRow label="Email" value={me.email ?? null} breakAll />
              {/* 取貨店已在頭像旁 chip 顯示，這裡不重複 */}
              {lineUserId && (
                <InfoRow label="LINE ID" value={lineUserId} mono breakAll small />
              )}
            </div>
          </section>
        ) : (
          /* 編輯模式 */
          <form
            onSubmit={(e) => { e.preventDefault(); onSave(); }}
            className="space-y-4"
          >
            <section>
              <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
                個人資料
              </div>
              <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
                <FormField label="姓名" required>
                  <input
                    type="text"
                    value={form.name}
                    onChange={(e) => setForm({ ...form, name: e.target.value })}
                    className="w-full bg-transparent text-right text-[17px] text-[var(--foreground)] outline-none placeholder:text-[var(--tertiary-label)]"
                    placeholder="請輸入"
                    required
                  />
                </FormField>
                <FormField label="手機" hint="台灣 09xxxxxxxx">
                  <input
                    type="tel"
                    inputMode="numeric"
                    value={form.phone}
                    onChange={(e) => setForm({ ...form, phone: e.target.value })}
                    placeholder="0912345678"
                    className="w-full bg-transparent text-right font-mono text-[17px] text-[var(--foreground)] outline-none placeholder:text-[var(--tertiary-label)]"
                  />
                </FormField>
                <FormField label="生日">
                  <input
                    type="date"
                    value={form.birthday}
                    onChange={(e) => setForm({ ...form, birthday: e.target.value })}
                    className="w-full bg-transparent text-right text-[17px] text-[var(--foreground)] outline-none"
                  />
                </FormField>
                <FormField label="Email">
                  <input
                    type="email"
                    value={form.email}
                    onChange={(e) => setForm({ ...form, email: e.target.value })}
                    placeholder="you@example.com"
                    className="w-full bg-transparent text-right text-[17px] text-[var(--foreground)] outline-none placeholder:text-[var(--tertiary-label)]"
                  />
                </FormField>
              </div>
              <p className="px-4 pt-2 text-[12px] text-[var(--tertiary-label)]">
                取貨店請聯絡店家調整。
              </p>
            </section>

            <div className="flex gap-2 px-1 pt-1">
              <button
                type="button"
                onClick={() => {
                  setEditing(false);
                  setError(null);
                  setForm({
                    name: me.name ?? "",
                    phone: me.phone ?? "",
                    birthday: me.birthday ?? "",
                    email: me.email ?? "",
                  });
                }}
                disabled={saving}
                className="flex-1 rounded-xl bg-[#7676801f] py-3 text-[16px] font-medium text-[var(--foreground)] active:bg-[#76768033] disabled:opacity-50"
              >
                取消
              </button>
              <button
                type="submit"
                disabled={saving}
                className="flex flex-1 items-center justify-center gap-2 rounded-xl bg-[var(--ios-blue)] py-3 text-[16px] font-semibold text-white active:opacity-80 disabled:opacity-50"
              >
                {saving ? <Spinner size={18} onColor /> : "儲存"}
              </button>
            </div>
          </form>
        )}

        {/* 推播設定 — 通知狀態已在頭像 chip 顯示,這裡留 重新連動 LINE + debug */}
        <PushNotificationManager state={pushState} />

        <p className="px-4 pt-2 text-[12px] text-[var(--tertiary-label)]">
          會員卡 QR、點數等更多功能持續開發中。
        </p>

        {/* 登出仍放最下面（少數人偶爾才需要），但要點得到：
            原本的 mx-auto 對全寬 block 不生效，變成靠左的一行小字，
            又緊貼底部 tab bar，實際上很難按。改成明確的按鈕。
            用外框而非實心紅 —— 要好按，但不該比頁面主要動作更搶眼。 */}
        <a
          href="/logout"
          className="mt-2 block w-full rounded-xl border border-[var(--ios-red)]/35 bg-[var(--ios-red)]/[0.06] px-4 py-3.5 text-center text-[16px] font-semibold text-[var(--ios-red)] transition active:scale-[0.98]"
        >
          登出
        </a>
      </div>
    </PageShell>
  );
}

function InfoRow({
  label,
  value,
  mono,
  breakAll,
  small,
}: {
  label: string;
  value: string | null;
  mono?: boolean;
  breakAll?: boolean;
  small?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-3 border-t border-[var(--separator)] px-4 py-3.5 first:border-t-0">
      <span className="text-[17px] text-[var(--foreground)]">{label}</span>
      <span
        className={`max-w-[60%] text-right ${small ? "text-[14px]" : "text-[17px]"} ${
          mono ? "font-mono" : ""
        } ${breakAll ? "break-all" : ""} ${
          value ? "text-[var(--secondary-label)]" : "text-[var(--tertiary-label)]"
        }`}
      >
        {value ?? "未填"}
      </span>
    </div>
  );
}

function FormField({
  label,
  hint,
  required,
  children,
}: {
  label: string;
  hint?: string;
  required?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label className="flex items-center gap-3 border-t border-[var(--separator)] px-4 py-3 first:border-t-0">
      <div className="w-[96px] flex-shrink-0">
        <div className="text-[17px] text-[var(--foreground)]">
          {label}
          {required && <span className="ml-0.5 text-[var(--ios-red)]">*</span>}
        </div>
        {hint && <div className="text-[12px] text-[var(--tertiary-label)]">{hint}</div>}
      </div>
      <div className="flex-1">{children}</div>
    </label>
  );
}
