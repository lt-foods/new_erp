import { renderPostText } from "./lineNoteRender.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (got !== want) throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
};
const HOWTO_MULTI = "📝 留言「會員編號 6 碼 ＋ 品項代碼＋數量」，例：123456 A+1 B+2";
const HOWTO_SINGLE = "📝 留言「會員編號 6 碼 ＋ 數量」，例：123456 +1";
const tag = "🔖 團號 GRP-1";
const payload = (campaign: Record<string, unknown>, items: Record<string, unknown>[], post_template: string | null = null) =>
  ({ post_template, campaign: { campaign_no: "GRP-1", end_at: "2026-09-13T15:59:00Z", ...campaign }, items });

Deno.test("預設版型：先團名、再金額、再文案；單品不印品名，結單時間不印", () => {
  const text = renderPostText(payload({ name: "梨山高麗菜", description: "包子媽朋友自己種的" }, [{ code: "A", name: "梨山高麗菜 (A) 半顆", unit_price: 69 }]));
  eq(text, `梨山高麗菜\n\n💲6️⃣9️⃣\n\n包子媽朋友自己種的\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "單品");
});

Deno.test("多品項才列 (A) 品名 ＋ 下一行金額，教學帶代碼", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "超入味" },
    [{ code: "A", name: "所長茶葉蛋 (A) 原味", unit_price: 195 }, { code: "B", name: "所長茶葉蛋 (B) 辣味", unit_price: 205 }]));
  eq(text, `所長茶葉蛋\n\n(A) 原味\n💲1️⃣9️⃣5️⃣\n(B) 辣味\n💲2️⃣0️⃣5️⃣\n\n超入味\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "多品項");
});

Deno.test("文案第一行就是團名 → 搬到最上面當標題（留住表情符號），不印兩次", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "<p>⭐️ <strong>所長茶葉蛋</strong></p><p>超入味</p>" },
    [{ code: "A", name: "原味", unit_price: 195 }]));
  eq(text, `⭐️ 所長茶葉蛋\n\n💲1️⃣9️⃣5️⃣\n\n超入味\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "標題搬上去、HTML 也轉好");
});

Deno.test("記事本匯進來的單品文案已經寫了同一個金額 → 不再多印一行", () => {
  const text = renderPostText(payload({ name: "梨山高麗菜", description: "梨山高麗菜\n半顆($)(6)(9)\n(emoji)9/9到貨" }, [{ code: "A", name: "半顆", unit_price: 69 }]));
  eq(text, `梨山高麗菜\n\n半顆💲6️⃣9️⃣\n9/9到貨\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "金額只出現一次");
  const diff = renderPostText(payload({ name: "梨山高麗菜", description: "梨山高麗菜\n半顆($)(6)(9)" }, [{ code: "A", name: "半顆", unit_price: 75 }]));
  eq(diff.includes("💲7️⃣5️⃣") && diff.includes("半顆💲6️⃣9️⃣"), true, "金額不一樣就兩個都印，讓人看得出來要改");
});

Deno.test("文案自己列了 (A)(B) 品項 → 商品段留空", () => {
  const text = renderPostText(payload({ name: "阿土伯", description: "阿土伯\n(A)空心菜\n($)(3)(5)\n(B)小白菜\n($)(3)(5)" },
    [{ code: "A", name: "空心菜", unit_price: 35 }, { code: "B", name: "小白菜", unit_price: 35 }]));
  eq(text, `阿土伯\n\n(A)空心菜\n💲3️⃣5️⃣\n(B)小白菜\n💲3️⃣5️⃣\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "不重複列品項");
});

Deno.test("自訂模板：{{deadline}} / {{end_at}} 照舊可用，沒寫 {{tag}} 也會補章", () => {
  const text = renderPostText(payload({ name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 100 }], "{{name}}\n{{items}}\n{{deadline}}"));
  eq(text, `測試\n💲1️⃣0️⃣0️⃣\n⏰ 9/13 23:59 結單\n${tag}`, "自訂模板");
});

Deno.test("文案用 A. B. 列品項（品名裡也帶 A.）→ 商品段留空，💰 價格照樣凸顯；口號在前、品名在第二行也認得出標題", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "<p>買一送一！</p><p>⭐️ <strong>所長茶葉蛋</strong></p><p>A. 經典原味 💰195<br>B. 麻香辣味 💰205</p>" },
    [{ code: "A", name: "A. 經典原味", unit_price: 195 }, { code: "B", name: "B. 麻香辣味", unit_price: 205 }]));
  eq(text, `⭐️ 所長茶葉蛋\n\n買一送一！\nA. 經典原味 💰1️⃣9️⃣5️⃣\nB. 麻香辣味 💰2️⃣0️⃣5️⃣\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "A. 列表");
  const own = renderPostText(payload({ name: "所長茶葉蛋", description: "超入味" }, [{ code: "A", name: "A. 經典原味", unit_price: 195 }, { code: "B", name: "B. 麻香辣味", unit_price: 205 }]));
  eq(own.includes("(A) 經典原味\n💲1️⃣9️⃣5️⃣\n(B) 麻香辣味"), true, "品名裡的 A. 不印兩次");
});

Deno.test("金額一律用零售價；沒設零售價（NULL / 0）才退回團購價", () => {
  const text = renderPostText(payload({ name: "港點", description: "好吃" },
    [{ code: "A", name: "蝦餃", unit_price: 168, retail_price: 249 }, { code: "B", name: "燒賣", unit_price: 69, retail_price: 0 }, { code: "C", name: "腸粉", unit_price: 88 }]));
  eq(text.includes("(A) 蝦餃\n💲2️⃣4️⃣9️⃣\n(B) 燒賣\n💲6️⃣9️⃣\n(C) 腸粉\n💲8️⃣8️⃣"), true, "零售價優先");
  const single = renderPostText(payload({ name: "高麗菜", description: "高麗菜\n半顆($)(6)(9)" }, [{ code: "A", name: "半顆", unit_price: 60, retail_price: 69 }]));
  eq(single, `高麗菜\n\n半顆💲6️⃣9️⃣\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "單品去重也是拿零售價比");
});

Deno.test("{{deadline}} / {{end_at}} 印客人收單；沒設客人收單就印店家收單", () => {
  const tpl = "{{name}}\n{{deadline}}\n{{end_at}}";
  const both = renderPostText(payload({ name: "測試", description: "", customer_end_at: "2026-09-12T10:00:00Z" }, [{ code: "A", name: "x", unit_price: 1 }], tpl));
  eq(both, `測試\n⏰ 9/12 18:00 結單\n9/12 18:00\n${tag}`, "客人收單優先");
  const only = renderPostText(payload({ name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 1 }], tpl));
  eq(only, `測試\n⏰ 9/13 23:59 結單\n9/13 23:59\n${tag}`, "退回店家收單");
});
