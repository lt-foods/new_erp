// 開機守門員 —— 「整支 bundle 根本沒跑起來」時的最後一道防線。
//
// 為什麼需要：會員端每一頁都是 client component，SSR 吐出來的 HTML 就是
// `loading = true` 的骨架（頁首 + 分頁列 + 轉圈）。所以 JS 只要在載入或解析
// 階段死掉，畫面會**完美地停在轉圈那一格**，看起來跟「一直在載入」一模一樣：
// 沒有錯誤訊息、沒有紅字、什麼都不會發生。2026-08-18 忠順 992831 的 iPhone 7
// 就是這樣 —— Next.js 16 預設把 JS 編到 `safari 16.4`，產出的 chunk 帶 ES2022
// 的 class static block，而 iPhone 7 最高只能升到 iOS 15.8（Safari 15.6），
// 一個 SyntaxError 就讓整個 App Router 停擺。
//
// 那次的根因已經用 package.json 的 browserslist 修掉了，但這一類故障的共同點是
// **我們什麼都收不到**：ErrorLogger 自己也在那包沒跑起來的 bundle 裡，
// client_error_logs 一筆都不會進來，只能等店家傳照片來問。所以這支腳本：
//
//   1. 直接內嵌進 HTML，**不屬於任何 chunk**，bundle 全滅時它照樣會執行。
//   2. 全程 ES5（沒有箭頭函式 / let / 樣板字串 / 選擇性串連），不然守門員自己
//      會在要守的那種舊瀏覽器上噴 SyntaxError。改完請跑
//      `node scripts/check-boot-guard-es5.mjs` 驗一次。
//   3. 沒等到 hydration 就把轉圈換成看得懂的訊息，並回報一筆 `boot_no_hydration`。
//
// 對應的存活訊號由 ErrorLogger 在 useEffect 裡設（見 components/ErrorLogger.tsx）。
// 兩邊的旗標名稱要一致，改名記得一起改。

/** hydration 成功的訊號；client 端掛載後設成 true，守門員看到就收工 */
export const BOOT_OK_FLAG = "__memberBootOk";

/** 沒等到 hydration 就放棄的上限。慢速 4G 上冷啟動實測 3～5 秒，抓 12 秒留足餘裕 */
const GIVE_UP_MS = 12000;

/**
 * `load` 之後再等多久就放棄。
 *
 * `load` 代表所有 script 都下載完了（含掛在 head 的 async chunk），正常情況下
 * hydration 緊接著就會發生 —— 所以這條路徑能在**幾秒內**給使用者訊息，而不是
 * 傻等上面那個為了慢網路而抓寬的上限。網路慢只會讓 `load` 晚來，不會誤判。
 */
const SETTLE_AFTER_LOAD_MS = 4000;

/**
 * 已經收到 chunk 的錯誤事件（＝確定壞了）之後的緩衝。
 * 不立刻跳訊息是因為 Next.js 對「網路抖一下」的 chunk 有自己的重試，
 * 真的沒救才讓使用者看到，避免閃一下嚇人。
 */
const FATAL_GRACE_MS = 1500;

/** 抓現場的 chunk 最多等多久（超時就用手上有的東西回報，不要讓使用者一直看轉圈） */
const PROBE_TIMEOUT_MS = 3000;

/**
 * 產生要內嵌的腳本內容。
 *
 * @param apiBase Supabase 專案網址（`NEXT_PUBLIC_SUPABASE_URL`）。沒有就只顯示
 *                訊息、不回報 —— 拿不到後端位址時無聲失敗，不要再炸一次。
 */
export function bootGuardScript(apiBase: string | undefined): string {
  const api = JSON.stringify(apiBase ?? "");
  const okFlag = JSON.stringify(BOOT_OK_FLAG);

  return `(function(){
var W=window,D=document;
if(W.__bootGuardOn){return}
W.__bootGuardOn=1;
var API=${api},FLAG=${okFlag};
var errs=[],kind="",shown=0,fatalAt=0,loadedAt=0,t0=+new Date();

function note(msg,src){
  if(errs.length<6){errs.push({m:String(msg).slice(0,300),s:String(src||"").slice(0,200)})}
}

/**
 * 把頁面上的 chunk 重新抓回來，用 new Function 解析（只解析、不執行），
 * 藉此問出「到底是解析失敗還是根本載不到」。
 *
 * 為什麼不能只靠 error 事件：那些 chunk 是釘在 <head> 最前面的 async script，
 * 而這段腳本最早只能插到 <body> 開頭（Next 不讓人排到它們前面），所以「誰先跑」
 * 是條件競爭 —— 實測 chunk 從快取回來時會贏，錯誤事件就漏接了。這支反過來事後
 * 重現一次，拿到的訊息穩定得多，還能決定要對使用者說「手機太舊」還是「網路不通」。
 */
function probe(done){
  var urls=[],tags=D.getElementsByTagName("script"),i,s;
  for(i=0;i<tags.length&&urls.length<4;i++){
    s=tags[i].src||"";
    if(s.indexOf("/_next/")>=0){urls.push(s)}
  }
  var left=urls.length;
  if(!left){done();return}
  var finished=0;
  function fin(){if(!finished){finished=1;done()}}
  var timer=setTimeout(fin,${PROBE_TIMEOUT_MS});
  function step(){if(--left<=0){clearTimeout(timer);fin()}}
  for(i=0;i<urls.length;i++){
    (function(url){
      var x=new XMLHttpRequest();
      x.onreadystatechange=function(){
        if(x.readyState!==4){return}
        if(x.status>=200&&x.status<300){
          try{
            new Function(x.responseText);
          }catch(e){
            // CSP 擋掉 eval 會丟 EvalError，那不是瀏覽器解析不了 —— 只認 SyntaxError
            if(e&&e.name==="SyntaxError"){kind="syntax";note("parse: "+(e.message||e),url)}
          }
        }else{
          if(!kind){kind="network"}
          note("fetch: HTTP "+x.status,url);
        }
        step();
      };
      try{x.open("GET",url,true);x.send()}catch(e){step()}
    })(urls[i]);
  }
}

function report(reason){
  if(!API){return}
  try{
    var tok=null,store=null,uid=null;
    try{tok=localStorage.getItem("member_jwt");store=localStorage.getItem("member_store_id");uid=localStorage.getItem("line_user_id")}catch(e){}
    var x=new XMLHttpRequest();
    x.open("POST",API+"/functions/v1/liff-api",true);
    x.setRequestHeader("Content-Type","application/json");
    if(tok){x.setRequestHeader("Authorization","Bearer "+tok)}
    x.send(JSON.stringify({
      action:"log_client_error",level:"error",source:"boot_no_hydration",
      message:"HTML 骨架載入後 JS 沒有接手（"+reason+(kind?"/"+kind:"")+"）",
      detail:{reason:reason,kind:kind||"unknown",waited_ms:(+new Date())-t0,errors:errs},
      store_code:store,line_user_id:uid,
      page_url:String(location.href).slice(0,500),
      user_agent:navigator.userAgent,
      env:{in_line:/ Line\\//i.test(navigator.userAgent),boot_guard:true,
           screen:((screen&&screen.width)||0)+"x"+((screen&&screen.height)||0)}
    }));
  }catch(e){}
}

function paint(reason){
  // 知道是解析失敗就直說「手機太舊」；知道是抓不到檔案就講網路。分不出來才兩個都提 ——
  // 講得越準，店家越不用陪客人猜（「重開機」「換 wifi」對舊手機一點用都沒有）。
  var why=kind==="syntax"
    ? "這支手機的系統版本太舊，新版網頁沒辦法在上面執行。"
    : kind==="network"
      ? "網路不穩或連線被擋住，網頁的程式檔沒有下載完整。"
      : "網路不穩，或這支手機的系統版本太舊，網頁程式沒辦法在上面執行。";
  var how=kind==="syntax"
    ? "請把手機系統更新到最新版；沒辦法更新的話，改用其他手機或電腦開啟。"
    : "先按下面重新整理試一次；還是一樣的話，請把這一頁截圖給小編。";
  try{
    var box=D.createElement("div");
    box.id="boot-guard";
    box.setAttribute("style","position:fixed;top:0;left:0;right:0;bottom:0;z-index:2147483647;overflow:auto;-webkit-overflow-scrolling:touch;background:#f6f3f4;color:#1c1c1e;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'PingFang TC','Helvetica Neue',sans-serif;font-size:16px;line-height:1.7");
    box.innerHTML='<div style="max-width:340px;margin:14vh auto 0;text-align:center">'
      +'<div style="font-size:42px">\\u26A0\\uFE0F</div>'
      +'<div style="font-size:20px;font-weight:600;margin:14px 0 10px">頁面載入失敗</div>'
      +'<div style="color:rgba(60,60,67,0.6);font-size:15px">'+why+'</div>'
      +'<div style="color:rgba(60,60,67,0.6);font-size:15px;margin-top:10px">已自動回報給店家。'+how+'</div>'
      +'<button id="boot-guard-retry" type="button" style="margin-top:22px;width:100%;padding:14px;border:0;border-radius:14px;background:#c44464;color:#fff;font-size:16px;font-weight:600">重新整理</button>'
      +'<button id="boot-guard-close" type="button" style="margin-top:12px;width:100%;padding:10px;border:0;background:none;color:rgba(60,60,67,0.6);font-size:14px">仍要繼續瀏覽</button>'
      +'<div style="margin-top:20px;font-size:11px;color:rgba(60,60,67,0.32);word-break:break-all">'+reason+(kind?" / "+kind:"")+' \\u00B7 '+String(navigator.userAgent).slice(0,160)+'</div>'
      +'</div>';
    D.body.appendChild(box);
    var btn=D.getElementById("boot-guard-retry");
    if(btn){btn.onclick=function(){location.reload()}}
    // 誤判的逃生口：頁面只是慢（不是壞）時，這片蓋滿全螢幕的東西會把一個其實
    // 正常的 app 擋在後面。寧可留一條路讓使用者自己關掉，也不要把人鎖在外面。
    var cls=D.getElementById("boot-guard-close");
    if(cls){cls.onclick=function(){if(box.parentNode){box.parentNode.removeChild(box)}}}
  }catch(e){}
}

function giveUp(reason){
  if(shown){return}
  shown=1;
  // 先問清楚是哪一種故障，再畫面 + 回報 —— 兩邊的用字都靠 probe 的結果決定
  probe(function(){paint(reason);report(reason)});
}

W.addEventListener("error",function(ev){
  var tgt=ev&&ev.target;
  // 解析錯誤：事件掛在 window 上，帶得到 message / filename
  if(ev&&ev.message){
    note(ev.message,ev.filename);
    if(String(ev.filename||"").indexOf("/_next/")>=0){fatalAt=fatalAt||+new Date()}
    return;
  }
  // 載入失敗：事件掛在 <script> 元素上（要用捕獲階段才收得到），沒有 message
  if(tgt&&tgt.tagName==="SCRIPT"){
    var src=tgt.src||"";
    note("script load failed",src);
    if(String(src).indexOf("/_next/")>=0){fatalAt=fatalAt||+new Date()}
  }
},true);

W.addEventListener("load",function(){loadedAt=+new Date()});

var iv=setInterval(function(){
  if(W[FLAG]){clearInterval(iv);return}
  var now=+new Date();
  if(fatalAt&&now-fatalAt>${FATAL_GRACE_MS}){clearInterval(iv);giveUp("script_error");return}
  if(loadedAt&&now-loadedAt>${SETTLE_AFTER_LOAD_MS}){clearInterval(iv);giveUp("no_hydration");return}
  if(now-t0>${GIVE_UP_MS}){clearInterval(iv);giveUp("timeout")}
},500);
})();`;
}
