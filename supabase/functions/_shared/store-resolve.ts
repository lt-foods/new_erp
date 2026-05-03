// ─────────────────────────────────────────────────────────────────────────────
// store-resolve: 把使用者帶進來的 store key (可能是 code "S001" 或 numeric "1")
// 解析成 canonical { id, code }。給 OAuth callback / LIFF session 在打 DB 前
// 統一轉成數字 ID，避免 BIGINT 欄位收到 code 字串爆 PostgREST 400。
// ─────────────────────────────────────────────────────────────────────────────

export async function resolveStore(
  supabaseUrl: string,
  serviceKey: string,
  tenantId: string,
  storeKey: string,
): Promise<{ id: number; code: string } | null> {
  const trimmed = (storeKey ?? "").trim();
  if (!trimmed) return null;

  const authHeaders = {
    apikey: serviceKey,
    Authorization: `Bearer ${serviceKey}`,
  };

  // 1) 先當 code 查（最常見：使用者用下拉或舊 URL `?store=S001`）
  const byCodeUrl =
    `${supabaseUrl}/rest/v1/stores` +
    `?select=id,code` +
    `&tenant_id=eq.${encodeURIComponent(tenantId)}` +
    `&code=eq.${encodeURIComponent(trimmed)}` +
    `&is_active=eq.true&limit=1`;
  const byCodeResp = await fetch(byCodeUrl, { headers: authHeaders });
  if (byCodeResp.ok) {
    const rows = await byCodeResp.json() as Array<{ id: number; code: string }>;
    if (rows.length > 0) return { id: rows[0].id, code: rows[0].code };
  }

  // 2) 純數字 → 改用 id 查（向後相容舊 URL `?store=1`）
  if (/^\d+$/.test(trimmed)) {
    const byIdUrl =
      `${supabaseUrl}/rest/v1/stores` +
      `?select=id,code` +
      `&tenant_id=eq.${encodeURIComponent(tenantId)}` +
      `&id=eq.${trimmed}` +
      `&is_active=eq.true&limit=1`;
    const byIdResp = await fetch(byIdUrl, { headers: authHeaders });
    if (byIdResp.ok) {
      const rows = await byIdResp.json() as Array<{ id: number; code: string }>;
      if (rows.length > 0) return { id: rows[0].id, code: rows[0].code };
    }
  }

  return null;
}
