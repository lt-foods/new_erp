import { renderPostText } from "./lineNoteRender.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (got !== want) throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
};
const HOWTO_MULTI = "📝 留言「品項代碼＋數量」，例：A+1 B+2";
const HOWTO_SINGLE = "📝 留言「數量」，例：+1";
const tag = "🔖 團號 GRP-1";
const DL = "⏰ 9/13 23:59 結單";   // payload 預設 end_at = 2026-09-13T15:59Z（台北 23:59）
const payload = (campaign: Record<string, unknown>, items: Record<string, unknown>[], post_template: string | null = null) =>
  ({ post_template, campaign: { campaign_no: "GRP-1", end_at: "2026-09-13T15:59:00Z", ...campaign }, items });

Deno.test("預設版型：先團名、再金額、再結單時間、再文案；單品不印品名", () => {
  const text = renderPostText(payload({ name: "梨山高麗菜", description: "包子媽朋友自己種的" }, [{ code: "A", name: "梨山高麗菜 (A) 半顆", unit_price: 69 }]));
  eq(text, `梨山高麗菜\n\n💰６９ 元\n\n${DL}\n\n包子媽朋友自己種的\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "單品");
});

Deno.test("多品項才列 (A) 品名 ＋ 同一行金額，教學帶代碼", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "超入味" },
    [{ code: "A", name: "所長茶葉蛋 (A) 原味", unit_price: 195 }, { code: "B", name: "所長茶葉蛋 (B) 辣味", unit_price: 205 }]));
  eq(text, `所長茶葉蛋\n\n(A) 原味 💰１９５ 元\n(B) 辣味 💰２０５ 元\n\n${DL}\n\n超入味\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "多品項");
});

Deno.test("文案第一行就是團名 → 拿掉那一行，標題一律印團名", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "<p>⭐️ <strong>所長茶葉蛋</strong></p><p>超入味</p>" },
    [{ code: "A", name: "原味", unit_price: 195 }]));
  eq(text, `所長茶葉蛋\n\n💰１９５ 元\n\n${DL}\n\n超入味\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "標題印團名、HTML 也轉好");
});

Deno.test("記事本匯進來的單品文案已經寫了同一個金額 → 不再多印一行", () => {
  const text = renderPostText(payload({ name: "梨山高麗菜", description: "梨山高麗菜\n半顆($)(6)(9)\n(emoji)9/9到貨" }, [{ code: "A", name: "半顆", unit_price: 69 }]));
  eq(text, `梨山高麗菜\n\n半顆💲６９\n\n${DL}\n\n9/9到貨\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "金額只出現一次、結單插在金額後面");
  const diff = renderPostText(payload({ name: "梨山高麗菜", description: "梨山高麗菜\n半顆($)(6)(9)" }, [{ code: "A", name: "半顆", unit_price: 75 }]));
  eq(diff.includes("💰７５ 元") && diff.includes("半顆💲６９"), true, "金額不一樣就兩個都印，讓人看得出來要改");
});

Deno.test("文案自己列了 (A)(B) 品項 → 商品段留空；記事本「價格在下一行」的寫法併成同一行", () => {
  const text = renderPostText(payload({ name: "阿土伯", description: "阿土伯\n(A)空心菜\n($)(3)(5)\n(B)小白菜\n($)(3)(5)" },
    [{ code: "A", name: "空心菜", unit_price: 35 }, { code: "B", name: "小白菜", unit_price: 35 }]));
  eq(text, `阿土伯\n\n(A)空心菜 💰３５ 元\n(B)小白菜 💰３５ 元\n\n${DL}\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "不重複列品項、併成一行、結單接在品項後面");
  const diff = renderPostText(payload({ name: "阿土伯", description: "阿土伯\n(A)空心菜\n($)(3)(0)\n(B)小白菜\n($)(3)(5)" },
    [{ code: "A", name: "空心菜", unit_price: 35 }, { code: "B", name: "小白菜", unit_price: 35 }]));
  eq(diff.includes("(A)空心菜\n💲３０\n(B)小白菜 💰３５ 元"), true, "小幫手寫的價格跟零售價不一樣 → 那一組兩行都不動、也不拆開");
});

Deno.test("自訂模板：{{deadline}} / {{end_at}} 照舊可用，沒寫 {{tag}} 也會補章", () => {
  const text = renderPostText(payload({ name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 100 }], "{{name}}\n{{items}}\n{{deadline}}"));
  eq(text, `測試\n💰１００ 元\n⏰ 9/13 23:59 結單\n${tag}`, "自訂模板");
});

Deno.test("文案用 A. B. 列品項（品名裡也帶 A.）→ 商品段留空，💰 價格照樣凸顯；口號在前、品名在第二行也認得出標題", () => {
  const text = renderPostText(payload({ name: "所長茶葉蛋", description: "<p>買一送一！</p><p>⭐️ <strong>所長茶葉蛋</strong></p><p>A. 經典原味 💰195<br>B. 麻香辣味 💰205</p>" },
    [{ code: "A", name: "A. 經典原味", unit_price: 195 }, { code: "B", name: "B. 麻香辣味", unit_price: 205 }]));
  eq(text, `所長茶葉蛋\n\n買一送一！\nA. 經典原味 💰１９５\nB. 麻香辣味 💰２０５\n\n${DL}\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "A. 列表，結單接在後面");
  const own = renderPostText(payload({ name: "所長茶葉蛋", description: "超入味" }, [{ code: "A", name: "A. 經典原味", unit_price: 195 }, { code: "B", name: "B. 麻香辣味", unit_price: 205 }]));
  eq(own.includes("(A) 經典原味 💰１９５ 元\n(B) 麻香辣味 💰２０５ 元"), true, "品名裡的 A. 不印兩次");
});

Deno.test("金額一律用零售價；沒設零售價（NULL / 0）才退回團購價", () => {
  const text = renderPostText(payload({ name: "港點", description: "好吃" },
    [{ code: "A", name: "蝦餃", unit_price: 168, retail_price: 249 }, { code: "B", name: "燒賣", unit_price: 69, retail_price: 0 }, { code: "C", name: "腸粉", unit_price: 88 }]));
  eq(text.includes("(A) 蝦餃 💰２４９ 元\n(B) 燒賣 💰６９ 元\n(C) 腸粉 💰８８ 元"), true, "零售價優先");
  const single = renderPostText(payload({ name: "高麗菜", description: "高麗菜\n半顆($)(6)(9)" }, [{ code: "A", name: "半顆", unit_price: 60, retail_price: 69 }]));
  eq(single, `高麗菜\n\n半顆💲６９\n\n${DL}\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "單品去重也是拿零售價比");
});

Deno.test("{{deadline}} / {{end_at}} 印客人收單；沒設客人收單就印店家收單", () => {
  const tpl = "{{name}}\n{{deadline}}\n{{end_at}}";
  const both = renderPostText(payload({ name: "測試", description: "", customer_end_at: "2026-09-12T10:00:00Z" }, [{ code: "A", name: "x", unit_price: 1 }], tpl));
  eq(both, `測試\n⏰ 9/12 18:00 結單\n9/12 18:00\n${tag}`, "客人收單優先");
  const only = renderPostText(payload({ name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 1 }], tpl));
  eq(only, `測試\n⏰ 9/13 23:59 結單\n9/13 23:59\n${tag}`, "退回店家收單");
});

Deno.test("預設版型的結單時間印客人收單；文案自己寫的「⏰9/12結單」換成系統的", () => {
  const cust = renderPostText(payload({ name: "測試", description: "好吃", customer_end_at: "2026-09-12T10:00:00Z" }, [{ code: "A", name: "x", unit_price: 50 }]));
  eq(cust, `測試\n\n💰５０ 元\n\n⏰ 9/12 18:00 結單\n\n好吃\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "客人收單");
  const own = renderPostText(payload({ name: "測試", description: "⏰9/12結單\n好吃" }, [{ code: "A", name: "x", unit_price: 50 }]));
  eq(own, `測試\n\n💰５０ 元\n\n${DL}\n\n好吃\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "小幫手寫的結單行拿掉、印系統的");
});

Deno.test("文案列了 (A)(B) 但沒寫價格 → 金額接在同一行，整行只有金額的「💰一袋189元」拿掉", () => {
  const text = renderPostText(payload({ name: "杰哥爆餡韭菜盒 675g", description: "🔥囤起來\n【杰哥爆餡盒子】\n💰一袋189元\n\n(A) 韭菜盒\n(B) 高麗菜盒（全素🌱）\n\n⏰9/14結單\n口味：(A)韭菜盒／(B)高麗菜盒" },
    [{ code: "A", name: "韭菜盒", unit_price: 189, retail_price: 189 }, { code: "B", name: "高麗菜盒", unit_price: 189, retail_price: 189 }]));
  eq(text, `杰哥爆餡韭菜盒 675g\n\n🔥囤起來\n【杰哥爆餡盒子】\n\n(A) 韭菜盒 💰１８９ 元\n(B) 高麗菜盒（全素🌱） 💰１８９ 元\n\n${DL}\n\n口味：(A)韭菜盒／(B)高麗菜盒\n\n${HOWTO_MULTI}\n#開團\n${tag}`, "接價格、拿掉多的那行、結單換成系統的接在品項後面");
  const keep = renderPostText(payload({ name: "杰哥", description: "杰哥\n💰滿1000免運\n(A) 韭菜盒 189元\n(B) 高麗菜盒" }, [{ code: "A", name: "韭菜盒", unit_price: 189 }, { code: "B", name: "高麗菜盒", unit_price: 199 }]));
  eq(keep.includes("💰滿１０００免運\n(A) 韭菜盒 189元\n(B) 高麗菜盒 💰１９９ 元"), true, "已有價格的行不動、不是純金額的 💰 行不拿");
});

Deno.test("整行只有金額的那一行，跟上一行之間空一行", () => {
  const text = renderPostText(payload({ name: "磁吸迷你拆信刀(顏色隨機)", description: "✉️網購族一定懂\n【磁吸迷你拆信刀｜顏色隨機】\n💰105元\n\n🚚15～25天貨到通知\n⏰9/14結單" }, [{ code: "A", name: "拆信刀", unit_price: 105, retail_price: 105 }]));
  eq(text, `磁吸迷你拆信刀(顏色隨機)\n\n✉️網購族一定懂\n\n💰１０５元\n\n${DL}\n\n🚚15～25天貨到通知\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "金額行上面補空行、結單接在金額後面、標題印團名");
});

Deno.test("文案裡老闆用全形打的「💰＄９９」就是這團的價 → 不再多印一行金額", () => {
  const text = renderPostText(payload({ name: "JP日本大昌 DAISHO 胡椒鹽", description: "🚚10-30天貨到通知\n💰＄９９\n✨這罐真的不是普通胡椒鹽！" }, [{ code: "A", name: "胡椒鹽", unit_price: 99, retail_price: 99 }]));
  eq(text, `JP日本大昌 DAISHO 胡椒鹽\n\n🚚10-30天貨到通知\n\n💰💲９９\n\n${DL}\n\n✨這罐真的不是普通胡椒鹽！\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "金額只出現一次、結單接在後面");
});

Deno.test("沒有結單時間（無到期日）就不印結單那一行", () => {
  const none = renderPostText(payload({ name: "測試", description: "好吃", end_at: null }, [{ code: "A", name: "x", unit_price: 50 }]));
  eq(none, `測試\n\n💰５０ 元\n\n好吃\n\n${HOWTO_SINGLE}\n#開團\n${tag}`, "無到期日");
});

// ── 商城連結（老闆 2026-09-22） ──────────────────────────────────────────────
const SITE = "https://shop.example.com";
const linked = (campaign: Record<string, unknown>, items: Record<string, unknown>[], post_template: string | null = null) =>
  ({ ...payload(campaign, items, post_template), site_url: SITE });

Deno.test("預設版型：教學下面接商城連結，團號章還是在最後一行", () => {
  const text = renderPostText(linked({ id: 42, name: "測試", description: "好吃" }, [{ code: "A", name: "x", unit_price: 50 }]));
  eq(text, `測試\n\n💰５０ 元\n\n${DL}\n\n好吃\n\n${HOWTO_SINGLE}\n🛒 商城下單：${SITE}/shop/c/42\n#開團\n${tag}`, "主商城");
});

Deno.test("漂漂館的團連到 /piaopiao/c/<id>", () => {
  const text = renderPostText(linked({ id: 7, name: "測試", description: "好吃", sales_channel: "piaopiao" }, [{ code: "A", name: "x", unit_price: 50 }]));
  eq(text.includes(`🛒 商城下單：${SITE}/piaopiao/c/7`), true, "漂漂館專區");
});

Deno.test("沒上架商城 / 沒帶站台網址 / localhost → 整行不印，版面跟以前一樣", () => {
  const body = `測試\n\n💰５０ 元\n\n${DL}\n\n好吃\n\n${HOWTO_SINGLE}\n#開團\n${tag}`;
  eq(renderPostText(linked({ id: 42, name: "測試", description: "好吃", is_for_shop: false }, [{ code: "A", name: "x", unit_price: 50 }])), body, "沒上架商城");
  eq(renderPostText(payload({ id: 42, name: "測試", description: "好吃" }, [{ code: "A", name: "x", unit_price: 50 }])), body, "沒帶 site_url");
  eq(renderPostText({ ...payload({ id: 42, name: "測試", description: "好吃" }, [{ code: "A", name: "x", unit_price: 50 }]), site_url: "http://localhost:3001" }), body, "localhost 是死連結");
});

Deno.test("自訂模板沒寫 {{link}} 也會補；寫了就不重複", () => {
  const auto = renderPostText(linked({ id: 9, name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 1 }], "{{name}}\n{{tag}}"));
  eq(auto, `測試\n🛒 商城下單：${SITE}/shop/c/9\n${tag}`, "補在團號章前面");
  const noTag = renderPostText(linked({ id: 9, name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 1 }], "{{name}}"));
  eq(noTag, `測試\n🛒 商城下單：${SITE}/shop/c/9\n${tag}`, "模板沒有團號章時兩個都補在後面");
  const own = renderPostText(linked({ id: 9, name: "測試", description: "" }, [{ code: "A", name: "x", unit_price: 1 }], "{{name}}\n自己去 {{link}} 下單\n{{tag}}"));
  eq(own, `測試\n自己去 🛒 商城下單：${SITE}/shop/c/9 下單\n${tag}`, "模板自己寫了就不再補一行");
});

Deno.test("多品項、文案裡單獨一行的同一個金額（💰 $295）→ 拿掉，不要在 (A)(B)(C) 之後又印一次", () => {
  const out = renderPostText(payload(
    { name: "森林雪霜蛋糕捲", description: "A｜檸檬\nB｜黑森林\n💰 $295\n好吃" },
    [{ code: "A", name: "檸檬", unit_price: 295 }, { code: "B", name: "黑森林", unit_price: 295 }],
  ));
  eq(out.includes("💰 💲２９５"), false, "文案裡的 💰 $295 要拿掉");
  eq((out.match(/２９５/g) ?? []).length, 2, "金額只出現在 (A)(B) 兩行");
});
