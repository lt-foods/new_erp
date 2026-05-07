// LINE User ID 馬賽克：取前 5 + ... + 後 5
// 用於 admin / LIFF 任何顯示 LINE User ID 的 UI；完整字串只留在 DB / RPC 內部
export function maskLineUserId(s: string | null | undefined): string {
  if (!s) return "—";
  if (s.length <= 12) return s; // 短到沒辦法遮就原樣回（避免遮太多反而看不出）
  return `${s.slice(0, 5)}...${s.slice(-5)}`;
}
