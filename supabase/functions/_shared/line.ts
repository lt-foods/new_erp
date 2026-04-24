// LINE Login OAuth helpers
// https://developers.line.biz/en/docs/line-login/integrate-line-login/

const LINE_TOKEN_URL  = "https://api.line.me/oauth2/v2.1/token";
const LINE_VERIFY_URL = "https://api.line.me/oauth2/v2.1/verify";

export type LineTokenResponse = {
  access_token: string;
  expires_in: number;
  id_token: string;
  refresh_token: string;
  scope: string;
  token_type: "Bearer";
};

export type LineIdTokenPayload = {
  iss: string;
  sub: string;        // line_user_id (U + 32 hex)
  aud: string;        // channel_id
  exp: number;
  iat: number;
  nonce?: string;
  amr?: string[];
  name?: string;
  picture?: string;
  email?: string;
};

/**
 * Exchange authorization code for tokens.
 */
export async function exchangeCode(params: {
  code: string;
  redirectUri: string;
  channelId: string;
  channelSecret: string;
}): Promise<LineTokenResponse> {
  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code: params.code,
    redirect_uri: params.redirectUri,
    client_id: params.channelId,
    client_secret: params.channelSecret,
  });

  const resp = await fetch(LINE_TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`LINE token exchange failed ${resp.status}: ${text}`);
  }
  return await resp.json() as LineTokenResponse;
}

/**
 * Verify an ID token via LINE's verify endpoint.
 * This is simpler than doing JWKS verification ourselves.
 */
export async function verifyIdToken(params: {
  idToken: string;
  channelId: string;
  nonce?: string;
}): Promise<LineIdTokenPayload> {
  const body = new URLSearchParams({
    id_token: params.idToken,
    client_id: params.channelId,
  });
  if (params.nonce) body.set("nonce", params.nonce);

  const resp = await fetch(LINE_VERIFY_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!resp.ok) {
    const text = await resp.text();
    throw new Error(`LINE id_token verify failed ${resp.status}: ${text}`);
  }
  return await resp.json() as LineIdTokenPayload;
}
