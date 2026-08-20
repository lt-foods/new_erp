import { isMissingSalesChannelColumn } from "./salesChannelGuard.ts";

Deno.test("只接受 sales_channel 欄位不存在的 SQLSTATE 42703", () => {
  if (!isMissingSalesChannelColumn({ code: "42703", message: "column group_buy_campaigns.sales_channel does not exist" })) throw new Error("應回退");
  if (isMissingSalesChannelColumn({ code: "PGRST204", message: "Could not find the sales_channel column" })) throw new Error("快取錯誤不可回退");
  if (isMissingSalesChannelColumn({ code: "42703", message: "column foo does not exist" })) throw new Error("其他欄位不可回退");
});
