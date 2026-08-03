"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { consumeFragmentToSession, getSession, loginPath } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import PageShell from "@/components/PageShell";
import Spinner, { LoadingScreen } from "@/components/Spinner";

type WalletInfo = {
  balance: number;
  last_movement_at: string | null;
};

type LedgerRow = {
  id: number;
  change: number;
  balance_after: number;
  type: "topup" | "spend" | "refund" | "adjust" | "reversal";
  source_type: string | null;
  source_id: number | null;
  payment_method: string | null;
  reverses: number | null;
  reason: string | null;
  created_at: string;
};

const TYPE_LABEL: Record<string, string> = {
  topup:    "加值",
  spend:    "扣款",
  refund:   "退款",
  adjust:   "調整",
  reversal: "反向",
};

const PAYMENT_LABEL: Record<string, string> = {
  cash:        "現金",
  credit_card: "信用卡",
  transfer:    "轉帳",
};

export default function WalletPage() {
  const router = useRouter();
  const [wallet, setWallet] = useState<WalletInfo | null>(null);
  const [ledger, setLedger] = useState<LedgerRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [hasMore, setHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    consumeFragmentToSession();
    const s = getSession();
    if (!s || !s.memberId) {
      router.replace(loginPath());
      return;
    }
    (async () => {
      try {
        const [w, l] = await Promise.all([
          callLiffApi<WalletInfo>(s.token, { action: "get_wallet" }),
          callLiffApi<{ ledger: LedgerRow[]; has_more: boolean }>(s.token, {
            action: "list_wallet_ledger",
            limit: 30,
          }),
        ]);
        setWallet(w);
        setLedger(l.ledger);
        setHasMore(l.has_more);
      } catch (e) {
        setErr(e instanceof Error ? e.message : String(e));
      } finally {
        setLoading(false);
      }
    })();
  }, [router]);

  async function loadMore() {
    if (loadingMore || ledger.length === 0) return;
    const s = getSession();
    if (!s) return;
    setLoadingMore(true);
    try {
      const beforeId = ledger[ledger.length - 1].id;
      const r = await callLiffApi<{ ledger: LedgerRow[]; has_more: boolean }>(s.token, {
        action: "list_wallet_ledger",
        limit: 30,
        before_id: beforeId,
      });
      setLedger((prev) => [...prev, ...r.ledger]);
      setHasMore(r.has_more);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setLoadingMore(false);
    }
  }

  return (
    <PageShell title="儲值金">
      <div className="space-y-4 px-4 pt-3 pb-6">
        {loading && <LoadingScreen />}

        {err && (
          <div className="rounded-2xl bg-[#ff3b30]/10 p-3 text-[14px] text-[#c4271d]">{err}</div>
        )}

        {wallet && (
          <section className="rounded-2xl bg-[var(--card-bg)] px-5 py-4 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
            <div className="text-[14px] text-[var(--secondary-label)]">目前餘額</div>
            <div className="mt-1 flex items-baseline gap-1">
              <span className="text-[40px] font-semibold tabular-nums leading-none text-[var(--foreground)]">
                ${Number(wallet.balance).toLocaleString()}
              </span>
            </div>
            <div className="mt-2 text-[12px] text-[var(--tertiary-label)]">
              儲值金不可退現；門市加值、結帳抵扣
            </div>
          </section>
        )}

        <section>
          <div className="px-4 pb-1 pt-2 text-[12px] uppercase tracking-wide text-[var(--tertiary-label)]">
            交易紀錄
          </div>
          <div className="overflow-hidden rounded-2xl bg-[var(--card-bg)] shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
            {ledger.length === 0 && !loading ? (
              <div className="px-4 py-12 text-center text-[14px] text-[var(--tertiary-label)]">
                尚無紀錄
              </div>
            ) : (
              <ul className="divide-y divide-[var(--separator)]">
                {ledger.map((row) => {
                  const sign = row.change >= 0 ? "+" : "";
                  const amountColor = row.change >= 0 ? "text-[#34c759]" : "text-[#ff3b30]";
                  return (
                    <li key={row.id} className="px-4 py-3">
                      <div className="flex items-baseline justify-between gap-3">
                        <div className="min-w-0 flex-1">
                          <div className="flex flex-wrap items-baseline gap-2 text-[15px] font-medium">
                            <span>{TYPE_LABEL[row.type] ?? row.type}</span>
                            {row.payment_method && (
                              <span className="text-[12px] font-normal text-[var(--secondary-label)]">
                                ({PAYMENT_LABEL[row.payment_method] ?? row.payment_method})
                              </span>
                            )}
                            {row.source_type === "customer_order" && row.source_id && (
                              <span className="text-[11px] font-normal text-[var(--tertiary-label)]">
                                訂單 #{row.source_id}
                              </span>
                            )}
                          </div>
                          <div className="mt-0.5 text-[12px] text-[var(--tertiary-label)]">
                            {new Date(row.created_at).toLocaleString("zh-TW", { hour12: false })}
                          </div>
                          {row.reason && (
                            <div className="mt-0.5 text-[13px] text-[var(--secondary-label)]">
                              {row.reason}
                            </div>
                          )}
                        </div>
                        <div className="text-right">
                          <div className={`font-mono text-[17px] font-semibold ${amountColor}`}>
                            {sign}{Number(row.change).toLocaleString()}
                          </div>
                          <div className="text-[11px] text-[var(--tertiary-label)]">
                            餘 ${Number(row.balance_after).toLocaleString()}
                          </div>
                        </div>
                      </div>
                    </li>
                  );
                })}
              </ul>
            )}
            {hasMore && (
              <button
                onClick={loadMore}
                disabled={loadingMore}
                className="flex w-full items-center justify-center gap-2 border-t border-[var(--separator)] px-4 py-3 text-center text-[15px] text-[var(--brand-strong)] active:bg-[#76768033] disabled:opacity-50"
              >
                {loadingMore ? <Spinner size={18} /> : "載入更多"}
              </button>
            )}
          </div>
        </section>
      </div>
    </PageShell>
  );
}
