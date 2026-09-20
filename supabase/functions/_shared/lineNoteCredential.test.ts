// 憑證保存：這裡壞掉的症狀是「每 7 天整組停擺、要人重新掃 QR」，而且只會在
// access token 到期那一天才看得出來 —— 所以用測試把行為釘住，不要等使用者回報。
// 背景見 supabase/migrations/20260920000000_line_note_refresh_token.sql 檔頭。
import { PersistingStorage, readCredential } from "./lineNote.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
  }
};

Deno.test("linejs 輪替 refreshToken / expire 時要通知外面（不接這條線＝新 token 蒸發）", async () => {
  const seen: Record<string, unknown>[] = [];
  const st = new PersistingStorage();
  st.onCredential = (c) => seen.push(c);

  await st.set("refreshToken", "rt-new");
  await st.set("expire", 1789826991);
  await st.set("cert", "不相干的東西不要回報");

  eq(seen, [{ refreshToken: "rt-new" }, { expire: 1789826991 }], "只回報 refreshToken / expire");
  eq(await st.get("refreshToken"), "rt-new", "值本身還是要存進 storage 給 linejs 用");
});

Deno.test("登入時自己餵進去的值不算換新（不然每次冷啟動都白寫一次 DB）", async () => {
  const seen: Record<string, unknown>[] = [];
  const st = new PersistingStorage();
  st.seeded = { refreshToken: "rt-old", expire: 111 };
  st.onCredential = (c) => seen.push(c);

  await st.set("refreshToken", "rt-old");   // loginWithAuthToken 的回音
  await st.set("expire", 111);
  eq(seen, [], "回音不回報");

  await st.set("refreshToken", "rt-rotated");
  eq(seen, [{ refreshToken: "rt-rotated" }], "真的換了才回報");
});

Deno.test("readCredential 把三樣一起撿出來；storage 壞掉不要整支炸掉", async () => {
  const st = new PersistingStorage();
  await st.set("refreshToken", "rt");
  await st.set("expire", 999);
  eq(await readCredential({ base: { authToken: "at", storage: st } }),
    { accessToken: "at", refreshToken: "rt", expire: 999 }, "三樣都在");

  eq(await readCredential({ base: { authToken: "at" } }),
    { accessToken: "at", refreshToken: null, expire: null }, "沒有 storage 也要回得出 access token");

  const broken = { get: () => { throw new Error("boom"); } };
  eq(await readCredential({ base: { authToken: "at", storage: broken } }),
    { accessToken: "at", refreshToken: null, expire: null }, "storage 丟例外不要往上炸");
});
