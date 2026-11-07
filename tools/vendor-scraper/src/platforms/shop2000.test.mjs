import { test } from "node:test";
import assert from "node:assert/strict";
import { parseListing, parseDetail, parseCategories, skipCategoryReason, imageList, vdirOf, stripTags } from "./shop2000.mjs";

// 從 2026-11-07 實際頁面截下來、去識別化的最小片段（結構原封不動）。
const LISTING = `
<title>測試店 </title>
<div class=p1_tl >💥本倉現貨💥</div>
<script>var p='1'; var RecordCount='388';</script>
<select name='pc2sn'><option value='all' >所有次分類<option value='1209823' >⚡現貨速發(可下超過)...161<option value='1209824' >待補貨...34</select>
<script>document.form1.pc2sn.value='1209823'</script><script>document.form1.vorder_p.value='依上架日期'</script>
<table id='plist_tb' ><tr><td class=p_td ><div><ul class='p_ul' ><li psn=111 >商品甲 &amp; 乙</li></ul></div>
<Div class=inlineblock ><img class='pimg' imgstr='|2||3|' psn=111  imgPath='https://img2.shop2000.com.tw/1/p9' src=https://img2.shop2000.com.tw/1/p9/111-2.jpg>
<div style='display:none;'><a href='https://www.shop2000.com.tw/測試店/product/p111'>商品甲</a></div></Div>
<div><div class=pd_l >效期28/10<br>\r\n箱規 48入</div></div>
<TABLE class=price_tb><TR><TD>
<div class='prik'><LG>一般價</LG> <span class=price1>89</span> 元</div>
<div class='prik'><LG>會員價</LG> <span class=price1>64</span> 元 <span class='pt9 nowrap' >(<LG>原價</LG>70)</span></div><TD><span class='buy buy_v' psn=111><LG>訂購</LG></span></TD></TR></TABLE>
<span class=tag_br >40件免運</span>
<Div><Div class='stk inblock showOp' spcOp='茶樹;櫻桃' spcStk='0;3' ><LG>庫存</LG> <stkT0>0;3</stkT0><div class='showOpSub' ></div></Div></Div>
<td class=p_td ><div><ul class='p_ul' ><li psn=222 >商品丙</li></ul></div>
<TABLE class=price_tb><TR><TD>
<div class='prik'><LG>會員價</LG> <span class=price1>1150</span> 元</div><TD><div class='buy' onclick="mycar_bk('222');"><LG>訂購</LG></div></TD></TR></TABLE>
<div class='stk' ><LG>庫存</LG> <stkT0>2</stkT0></div>
<td class=p_td ><div><ul class='p_ul' ><li psn=333 >商品丁</li></ul></div>
<TABLE class=price_tb><TR><TD>
<div class='prik'><LG>會員價</LG> <span class=price1>105</span> 元 <span class='pt9 nowrap' >(<LG>原價</LG>169)</span></div></TD></TR></TABLE>
`;

test("parseListing：分頁資訊與三種商品格式", () => {
  const r = parseListing(LISTING, { baseUrl: "https://www.shop2000.com.tw/測試店/product/1" });
  assert.equal(r.category, "💥本倉現貨💥");
  assert.equal(r.recordCount, 388);
  assert.equal(r.sub, "1209823");
  assert.equal(r.subcategory, "⚡現貨速發(可下超過)");
  assert.equal(r.order, "依上架日期");
  assert.equal(r.items.length, 3);

  const [a, b, c] = r.items;
  assert.equal(a.psn, "111");
  assert.equal(a.name, "商品甲 & 乙");
  assert.equal(a.short_desc, "效期28/10\n箱規 48入");
  assert.deepEqual([a.price_general, a.price_member, a.price_original], [89, 64, 70]);
  assert.deepEqual(a.options, [{ name: "茶樹", stock: 0 }, { name: "櫻桃", stock: 3 }]);
  assert.equal(a.stock, 3);
  assert.deepEqual(a.tags, ["40件免運"]);
  assert.deepEqual(a.images, ["https://img2.shop2000.com.tw/1/p9/111-2o.jpg", "https://img2.shop2000.com.tw/1/p9/111-3o.jpg"]);

  assert.deepEqual([b.price_general, b.price_member, b.price_original], [null, 1150, null]);
  assert.equal(b.stock, 2);
  assert.deepEqual(b.options, []);

  assert.equal(c.stock, null); // 沒顯示庫存
  assert.equal(c.price_original, 169);
});

const DETAIL = `
<meta property="og:image" content="https://img2.shop2000.com.tw/1/p9/111-2o.jpg" />
<span id=product_name>商品甲 &amp; 乙</span></div><table border=0 style='width:100%;' >
<tr><td class=p_tiemH ><LG>分類位置</LG>：<td class=p_tiem ><span class=A_add onclick=topcls('645845',''); >💥本倉現貨💥</span> / <span class=A_add onclick=topcls('645845','1374578'); >美妝保養</span>
<tr><td class=p_tiemH ><LG>商品代碼</LG>：<td class=p_tiem >FR2C20075
<tr><td class=p_tiemH ><LG>簡要說明</LG>：<td class=p_tiem style='line-height:25px;'>效期28/10   禁止公開平台
<tr><td class=p_tiemH ><LG>庫存</LG>：<td class=p_tiem ><stkT0>3</stkT0><span class=pt9 style='margin-left:40px;'>※ <LG>不可買超過庫存</LG></span>
<tr><td class=p_tiemH><LG>規格</LG>：<td class=p_tiem ><div style='border-left:solid 4px #C2CE99;' ><div class=pt11g >規格：</div><div style='padding:5px 10px 10px 40px;'><Div class=spc_div><input type=radio name='FIELD0' value='茶樹舒緩'  onclick=gen_option('0'); > 茶樹舒緩<div class=pt9 style='margin-left:25px;' ><LG>庫存</LG>：<stkT0>0</stkT0> <span class='saleout'>*已售完</span></div><div id='spcPriceVir0'></div></Div><Div class=spc_div><input type=radio name='FIELD0' value='櫻桃亮采'  onclick=gen_option('3'); > 櫻桃亮采<div class=pt9 style='margin-left:25px;' ><LG>庫存</LG>：<stkT0>3</stkT0></div><div id='spcPriceVir3'></div></Div></div></div></table>
<table style='width:100%;' ><tr><td style='line-height:25px;padding:10px 0px;' ><TABLE class=price_tb><TR><TD>
<div class='prik'><LG>一般價</LG> <span class=price1>89</span> 元</div>
<div class='prik'><LG>會員價</LG> <span class=price1>64</span> 元 <span class='pt9 nowrap' >(<LG>原價</LG>70)</span></div><TD>
<table><tr><td class=pt13 ><LG>件數</LG>：<select name='buyct' id='buyct' class=pt13 ></select><td><div class='buy' onclick="mycar_bk('111');"><LG>訂購</LG></div></table>
</TD></TR></TABLE><div class='dis_mem' >※ 本商品買 <span class=tag_br >40 件</span> 免運費</div></table>
<table style='width:100%;' ><tr><td class=p_tiemH> 貨運方式：<td style='padding:10px 0px;'><div class=tag_br style='margin-right:5px;'>低溫宅配</div><div class=tag_br style='margin-right:5px;'>來店自取 <span class=pt9>(可選貨到付款)</span></div></table>
<table style='width:100%;' ><tr><td class=p_tiemH> 付款方式：<td style='padding:10px 0px;'><div class=tag_y style='margin-right:5px;' >金融匯款</div></table></TD></TR></TABLE>
<script> imgHtml=imgHtml+'<br><img class=shadow8 src=https://img2.shop2000.com.tw/1/p9/111-'+gno+ 'o.jpg >'; var imgstr = '|2||3|';</script>
<div class=shadow8 style='padding:30px 0px;' ><table class=tbFix100 style='width:95%;margin:auto;' border=0 ><tr><td class='txtl' ><div>第一行</div><div><br></div><div>第二行 &lt;3</div></table>
`;

test("parseDetail：欄位、規格庫存、運送、圖片、說明", () => {
  const d = parseDetail(DETAIL, { url: "http://www.example.com/product/p111" });
  assert.equal(d.psn, "111");
  assert.equal(d.name, "商品甲 & 乙");
  assert.equal(d.product_code, "FR2C20075");
  assert.equal(d.category, "💥本倉現貨💥");
  assert.equal(d.subcategory, "美妝保養");
  assert.deepEqual(d.breadcrumb[1], { pc1sn: "645845", pc2sn: "1374578", name: "美妝保養" });
  assert.equal(d.short_desc, "效期28/10 禁止公開平台");
  assert.equal(d.stock, 3);
  assert.deepEqual(d.spec_groups, [
    { name: "規格", options: [{ name: "茶樹舒緩", stock: 0, sold_out: true }, { name: "櫻桃亮采", stock: 3, sold_out: false }] },
  ]);
  assert.deepEqual([d.price_general, d.price_member, d.price_original], [89, 64, 70]);
  assert.equal(d.free_shipping, "※ 本商品買 40 件 免運費");
  assert.deepEqual(d.shipping_methods, ["低溫宅配", "來店自取 (可選貨到付款)"]);
  assert.deepEqual(d.payment_methods, ["金融匯款"]);
  assert.deepEqual(d.images, ["https://img2.shop2000.com.tw/1/p9/111-2o.jpg", "https://img2.shop2000.com.tw/1/p9/111-3o.jpg"]);
  assert.equal(d.description, "第一行\n\n第二行 <3");
  assert.match(d.description_html, /^<div>第一行<\/div>/);
});

test("parseDetail：沒有規格、沒有庫存、沒有免運的商品", () => {
  const d = parseDetail("<span id=product_name>x</span><TABLE class=price_tb><TR><TD><div class='prik'><LG>會員價</LG> <span class=price1>5</span> 元</div></TD></TR></TABLE>", { url: "http://a/product/p9" });
  assert.equal(d.psn, "9");
  assert.equal(d.price_member, 5);
  assert.equal(d.stock, null);
  assert.deepEqual(d.spec_groups, []);
  assert.equal(d.free_shipping, null);
  assert.deepEqual(d.images, []);
  assert.equal(d.description, "");
});

test("vdirOf / imageList / stripTags", () => {
  assert.equal(vdirOf(new URL("https://www.shop2000.com.tw/%E6%9C%89%E9%AE%AE/product/683418")), "/%E6%9C%89%E9%AE%AE");
  assert.equal(vdirOf(new URL("http://www.simpsons.com.tw/product/645845")), "");
  assert.deepEqual(imageList("https://x/p1", "7", "|1||10|"), ["https://x/p1/7-1o.jpg", "https://x/p1/7-10o.jpg"]);
  assert.deepEqual(imageList(null, "7", "|1|"), []);
  assert.equal(stripTags("a&nbsp;b<br>c\r\n<div>d</div>"), "a b\nc\nd");
});

test("parseCategories：首頁左側選單", () => {
  const html = `<div class='pc1_nr' onclick=topcls('625828','') >魚類<span class=pt9 >...25</span></div></DIV>
<a style='display:none;'  href='https://www.shop2000.com.tw/全富水產/product/625828'>魚類</a>
<div class='pc1_nr' onclick=topcls('632052','') >廠商直送(預購團)<span class=pt9 >...150</span></div>
<a style='display:none;'  href='https://www.shop2000.com.tw/全富水產/product/632052'>廠商直送(預購團)</a>
<div onclick=topcls('625828','1374578') >/ 次分類</div>`;
  assert.deepEqual(parseCategories(html), [
    { pc1sn: "625828", name: "魚類", count: 25 },
    { pc1sn: "632052", name: "廠商直送(預購團)", count: 150 },
  ]);
});

test("skipCategoryReason：下架 / 待處理 / 已過收單日 / 過去月份", () => {
  const now = new Date("2026-11-07T04:00:00Z"); // 台北 11/7 中午
  for (const n of ["預定下架商品", "下架區(要追加請先詢問區)", "不上架區", "【待處理】", "💛待重盤", "🖤重盤後有欠", "【會員需知】", "批發守則~"]) {
    assert.ok(skipCategoryReason(n, now), n);
  }
  assert.match(skipCategoryReason("❤️11/4 收單 預購", now), /已過收單日/);
  assert.match(skipCategoryReason("9/3結單商品", now), /已過收單日/);
  assert.match(skipCategoryReason("2026年9月商品", now), /已過/);
  for (const n of ["❤️11/8 收單 預購", "11/7 收單", "2026年11月商品", "2026年12月商品", "現貨出清區", "🔥出清甩貨亂賣", "魚類", "", null]) {
    assert.equal(skipCategoryReason(n, now), null, String(n));
  }
  // 跨年：12 月看到「1/5 收單」是明年，不跳過
  assert.equal(skipCategoryReason("1/5 收單", new Date("2026-12-20T04:00:00Z")), null);
});
