import { applyDeco, decoPrice, decoStandalonePrices, htmlToText, stripLineDeco } from "./lineNoteDeco.ts";

const eq = (got: unknown, want: unknown, why: string) => {
  if (got !== want) throw new Error(`${why}\n  想要 ${JSON.stringify(want)}\n  拿到 ${JSON.stringify(got)}`);
};

Deno.test("標記過的金額換成 💲＋鍵帽數字，沒標記的一個字不動", () => {
  eq(applyDeco(`一份 ${decoPrice("$120")}`), "一份 💲1️⃣2️⃣0️⃣", "基本");
  eq(applyDeco(`${decoPrice("$30")}（市價$150/盒）`), "💲3️⃣0️⃣（市價$150/盒）", "行內市價維持純文字");
  eq(applyDeco(decoPrice("$99.5")), "💲9️⃣9️⃣.5️⃣", "小數點原樣留著");
  eq(applyDeco("沒標記 $88"), "沒標記 $88", "沒標記就原樣");
});

Deno.test("文案裡自己獨立一行的 $數字才標起來", () => {
  const out = applyDeco(decoStandalonePrices("好兄弟組合10包\n$109\n一盒$85\n（市價$150/盒）"));
  eq(out, "好兄弟組合10包\n💲1️⃣0️⃣9️⃣\n一盒$85\n（市價$150/盒）", "只動獨立一行的");
});

Deno.test("富文字 HTML 轉純文字：段落換行、粗體拿掉、實體字元還原", () => {
  eq(htmlToText("<p>測試</p><p></p><p><strong>$100</strong></p>"), "測試\n\n$100", "段落＋空段落＋粗體");
  eq(htmlToText("<p>A. 原味 💰195<br>B. 辣味 💰205</p><p>📦15-25天貨到通知</p>"), "A. 原味 💰195\nB. 辣味 💰205\n📦15-25天貨到通知", "<br> 換行");
  eq(htmlToText("<ul><li><p>甲</p></li><li><p>乙</p></li></ul>"), "• 甲\n• 乙", "清單項目");
  eq(htmlToText("<p>Tom&nbsp;&amp;&nbsp;Jerry &lt;3 &amp;lt;</p>"), "Tom & Jerry <3 &lt;", "實體字元，&amp; 最後才還原");
  eq(htmlToText("純文字 <3 沒有標籤\n第二行"), "純文字 <3 沒有標籤\n第二行", "不像 HTML 的原樣回傳");
});

Deno.test("HTML 說明裡獨立一行的粗體金額，轉完會被凸顯", () => {
  const text = applyDeco(decoStandalonePrices(htmlToText("<p>測試</p><p><strong>$100</strong></p>")));
  eq(text, "測試\n💲1️⃣0️⃣0️⃣", "整條管線");
});

Deno.test("記事本抓回來的佔位字：金額還原成 emoji、日期還原成純文字、貼圖拿掉", () => {
  const out = applyDeco(stripLineDeco("一個($)(1)(2)(5)\n(emoji)15-25天貨到通知\n(9)(/)(9)(emoji)(emoji)"));
  eq(out, "一個💲1️⃣2️⃣5️⃣\n15-25天貨到通知\n9/9", "行內金額也凸顯，日期不動");
});
