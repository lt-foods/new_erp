import { normalizePiaopiaoLoginId, piaopiaoLoginEmail } from "./piaopiaoPublisherAccount.ts";

Deno.test("漂漂館帳號只接受公司指派的帳號格式", () => {
  if (normalizePiaopiaoLoginId("  Piao.Tong ") !== "piao.tong") throw new Error("應正規化帳號");
  if (normalizePiaopiaoLoginId("a") !== null) throw new Error("過短帳號不可用");
  if (normalizePiaopiaoLoginId("piao tong") !== null) throw new Error("空白帳號不可用");
  if (piaopiaoLoginEmail("piao.tong") !== "piao.tong@piaopiao.local") throw new Error("登入識別不一致");
});
