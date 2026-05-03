"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import { PushNotificationManager } from "@/components/PushNotificationManager";
import { usePushNotification } from "@/lib/usePushNotification";

type MemberData = {
  member_id: number;
  member_no: string;
  name: string | null;
  phone: string | null;
  email: string | null;
  birthday: string | null;
  gender: string | null;
  home_store_id: number | null;
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

export default function MePage() {
  const router = useRouter();
  const [loading, setLoading] = useState(true);
  const [me, setMe] = useState<MemberData | null>(null);
  const [overview, setOverview] = useState<Overview | null>(null);
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
        const [meData, ovData] = await Promise.all([
          callLiffApi<MemberData>(s.token, { action: "get_me" }),
          callLiffApi<Overview>(s.token, { action: "get_overview" }).catch(() => null),
        ]);
        setMe(meData);
        if (ovData) setOverview(ovData);
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
        <p className="px-5 pt-4 text-[15px] text-[var(--tertiary-label)]">載入中…</p>
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
            {avatarSrc ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={avatarSrc} alt="" className="h-16 w-16 flex-shrink-0 rounded-full object-cover" />
            ) : (
              <div className="flex h-16 w-16 flex-shrink-0 items-center justify-center rounded-full bg-[#7676801a] text-2xl text-[var(--secondary-label)]">
                {displayName[0]}
              </div>
            )}
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
                {overview?.store.name && (
                  <span className="inline-flex items-center gap-1 rounded-full bg-[#7676801f] px-2.5 py-[3px] text-[12px] font-medium text-[var(--secondary-label)]">
                    📍 {overview.store.name}
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
                className="flex-shrink-0 rounded-full bg-[var(--ios-blue)] px-3 py-1.5 text-[13px] font-medium text-white active:opacity-80 disabled:opacity-50"
              >
                {generating ? "..." : "PWA 碼"}
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
            {overview.active_orders_count > 0 && (
              <a
                href="/orders"
                className="mt-3 flex w-full items-center justify-between rounded-xl bg-[#7676801a] px-3 py-3 text-[16px] text-[var(--foreground)] active:bg-[#76768033]"
              >
                <span>進行中訂單 {overview.active_orders_count} 筆</span>
                <span className="text-[var(--ios-gray)]">›</span>
              </a>
            )}
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
              <InfoRow label="門市" value={storeId ?? null} />
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
                className="flex-1 rounded-xl bg-[var(--ios-blue)] py-3 text-[16px] font-semibold text-white active:opacity-80 disabled:opacity-50"
              >
                {saving ? "儲存中…" : "儲存"}
              </button>
            </div>
          </form>
        )}

        {/* 推播設定 — 通知狀態已在頭像 chip 顯示,這裡留 重新連動 LINE + debug */}
        <PushNotificationManager state={pushState} />

        <p className="px-4 pt-2 text-[12px] text-[var(--tertiary-label)]">
          會員卡 QR、點數等更多功能持續開發中。
        </p>
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
