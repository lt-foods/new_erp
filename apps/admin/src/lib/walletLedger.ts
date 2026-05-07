// ============================================================
// 儲值金 ledger 中央定義
//
// Single source of truth for:
//   - wallet_ledger.type 中文 label (對應 supabase migrations 內 CHECK)
//   - wallet_ledger.payment_method 中文 label (topup 用)
// ============================================================

export const WALLET_LEDGER_TYPES = [
  "topup",
  "spend",
  "refund",
  "adjust",
  "reversal",
] as const;

export type WalletLedgerType = (typeof WALLET_LEDGER_TYPES)[number];

export const WALLET_LEDGER_TYPE_LABEL: Record<WalletLedgerType, string> = {
  topup:    "加值",
  spend:    "扣款",
  refund:   "退款",
  adjust:   "調整",
  reversal: "沖銷",
};

export function walletLedgerTypeLabel(t: string | null | undefined): string {
  if (!t) return "—";
  return WALLET_LEDGER_TYPE_LABEL[t as WalletLedgerType] ?? t;
}

// ============================================================
// payment_method (主要 topup 時記錄)
// ============================================================

export const WALLET_PAYMENT_METHODS = [
  "cash",
  "credit_card",
  "transfer",
] as const;

export type WalletPaymentMethod = (typeof WALLET_PAYMENT_METHODS)[number];

export const WALLET_PAYMENT_METHOD_LABEL: Record<WalletPaymentMethod, string> = {
  cash:        "現金",
  credit_card: "信用卡",
  transfer:    "轉帳",
};

export function walletPaymentMethodLabel(m: string | null | undefined): string {
  if (!m) return "—";
  return WALLET_PAYMENT_METHOD_LABEL[m as WalletPaymentMethod] ?? m;
}
