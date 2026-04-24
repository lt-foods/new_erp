// JWT sign/verify helpers (Supabase-compatible HS256)
// 用 Deno 原生 WebCrypto，避免外部相依

function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function b64urlDecode(s: string): Uint8Array {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replaceAll("-", "+").replaceAll("_", "/") + pad;
  const bin = atob(b64);
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}

function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    utf8(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export type JwtClaims = {
  iss?: string;
  sub?: string;
  aud?: string;
  exp?: number;   // seconds
  iat?: number;
  nbf?: number;
  role?: string;
  [k: string]: unknown;
};

export async function signJwtHs256(
  claims: JwtClaims,
  secret: string,
): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const now = Math.floor(Date.now() / 1000);
  const body: JwtClaims = { iat: now, ...claims };

  const h = b64urlEncode(utf8(JSON.stringify(header)));
  const p = b64urlEncode(utf8(JSON.stringify(body)));
  const data = `${h}.${p}`;
  const key = await hmacKey(secret);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, utf8(data)));
  return `${data}.${b64urlEncode(sig)}`;
}

export async function verifyJwtHs256(
  token: string,
  secret: string,
): Promise<JwtClaims> {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("invalid jwt format");
  const [h, p, s] = parts;
  const data = `${h}.${p}`;
  const key = await hmacKey(secret);
  const ok = await crypto.subtle.verify(
    "HMAC",
    key,
    b64urlDecode(s),
    utf8(data),
  );
  if (!ok) throw new Error("invalid jwt signature");
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(p))) as JwtClaims;
  const now = Math.floor(Date.now() / 1000);
  if (claims.exp && claims.exp < now) throw new Error("jwt expired");
  if (claims.nbf && claims.nbf > now) throw new Error("jwt not yet valid");
  return claims;
}

/**
 * Sign a short-lived state token for OAuth CSRF protection.
 * Payload: { nonce, store_id, iat, exp }
 */
export async function signStateToken(
  storeId: string,
  secret: string,
  ttlSeconds = 600,
): Promise<string> {
  const nonce = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1000);
  return await signJwtHs256(
    { nonce, store_id: storeId, exp: now + ttlSeconds },
    secret,
  );
}

export async function verifyStateToken(
  token: string,
  secret: string,
): Promise<{ nonce: string; store_id: string }> {
  const claims = await verifyJwtHs256(token, secret);
  if (!claims.store_id || !claims.nonce) throw new Error("invalid state");
  return {
    nonce: String(claims.nonce),
    store_id: String(claims.store_id),
  };
}
