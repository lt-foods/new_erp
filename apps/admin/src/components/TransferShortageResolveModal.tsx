"use client";

// 店家少收的貨 — 總倉「回覆店家」視窗
//
// ⭐ 這個視窗在回答的問題是:**總倉要怎麼回覆這家店**(老闆 2026-08-21 定稿),
//   不是「總倉內部怎麼處理這批貨」。所以只有兩個答案:同意退回要不要補貨。
// 顯示:
//   - 這一筆的派出 / 實收 / 少收
//   - 兩顆處理鈕 + 一行「第三個答案還沒做」的說明 + 備註
//
// ⭐⭐⭐ 這支檔案的第一鐵則:畫面上每一句「系統會怎樣」的話,都要能指出出處。
//   2026-08-21 上一版在紅框裡寫了一句沒查證的推論(「古華那筆沒有任何人能再派它」),
//   Codex 審的是「程式對不對」,抓不到「畫面上寫的話是不是真的」⇒ 整輪審過了還是錯的。
//   ⛔ 查不到出處的話寧可少講一句。⛔ 不要寫「永遠」「沒有任何人」這種絕對句。
//   (那句話錯在只查了派貨工作台的路 1。路 2 補貨申請的可配量直接讀總倉真實庫存
//    stock_balances.on_hand —— v_picking_demand_no_po 最新版
//    20260612000040_approve_restock_via_picking_workstation.sql:73-78 的 hq_supply CTE
//    ⇒ 貨記回總倉之後,開一張補貨申請就派得出去。古華等兩個月的真因是沒人知道要開申請。)
//
// ⭐⭐ 2026-08-21 複審抓到的病(留著當通則,原始情境已隨「客人在等」那一塊移除):
//   「畫面上先寫一句只在某些情況成立的話,再靠另一個查詢/另一個框去更正它」。
//   ⇒ 修法統一成一條:**先把預設文案改成「不管情況怎樣都成立」**,
//     額外的查詢只拿來「多講一句」,不拿來救錯字。
//     這樣「還在查」「查失敗」「使用者搶先按送出」三種情況自然都不會出事。
//   ⛔ 以後要在畫面加任何一句「系統會怎樣」,先問自己:
//     「這句話在什麼情況下會不成立?」答得出來就不要那樣寫。
//   ⭐ 另一條同樣重要:**同一句斷言可以有好幾個成因,修掉被指出來的那個不等於那句話變真了。**
//     要修一句畫面斷言時,先把「這句話會變假的所有路徑」列完(資料來源的條件、
//     limit、前端過濾、狀態值域全部算),再一次修完。
//   ⛔ 特別檢查所有「綠色的 / 肯定的 / 叫人放心」的文字,它們才是會害人按下不可逆鈕的那些。
//
// ⛔⛔ 2026-08-21 老闆裁示:**這個視窗不查、也不顯示「有沒有客人在等」。**
//   老闆原話:「總倉不在乎有沒有客人在等,因為沒有貨或廠商給不了總倉,總倉也沒辦法啊。」
//   ⇒ 原本那一整塊(customer_orders / customer_order_items 查詢、
//     「查到 N 張客人訂單」「目前沒有客人在等這一項」「一次只查前 50 張」等文字、
//     AFFECTED_CAP / NOT_WAITING_ORDER_STATUSES / PICKED_UP_ITEM_STATUSES 常數、
//     以及四審 P1「要不要扣掉已退回總倉的量」那整段討論)**全部刪除**,不留死碼。
//   ⛔ 不要再加回來。這兩顆按鈕要不要按,跟客人在不在等無關 —— 總倉沒貨就是沒貨。
//
// ⚠️ 兩顆都是單行道(按下去回不來):
//   異常清單的 transfer_short 分支要求 ti.shortage_resolution IS NULL
//   (或 replenish 且還沒補到)才會列出來
//   (v_hq_exceptions 最新版 20260811020010_hq_exceptions_drop_customer_shortage.sql:141-161),
//   而 rpc_resolve_transfer_item_shortage 對所有 resolution 一律寫入 shortage_resolution
//   (最新版 20260811020000_transfer_shortage_redispatch.sql:262-270,沒有任何例外)
//   ⇒ 按完這一筆就從清單消失,之後不能再改選別的。
//   ⛔ 也因此不可以做批次 / 全選 / 一鍵處理(2026-08-21 老闆裁示)。
//
// ⚠️⚠️ 為什麼警語要做成擋眼的色底、不是灰色小字
//   2026-08-21 正式庫唯讀實測(hq_to_store、已收貨、實收<派出、已處理過的分組):
//     restock_hq  85 筆 / 230 件   accept 31 筆 / 89 件   redispatch 23 筆 / 155 件
//   ⇒ 「不補貨」被按的次數是「補貨」的 3.7 倍(85:23)—— 兩顆的後果差很多,值得擋眼。
//   ⛔ 不要為了版面清爽把它改回小灰字。
//   (數字是當時快照、會過期;⛔ 刻意不放進畫面文案,免得變成一句過期的謊)
//
// ⚠️ 畫面上只留兩顆,但 DB 的允許值仍是六種
//   (20260811020000:66-69 的 CHECK 與 :112 的 IF,兩份清單都含
//    replenish/cancel_orders/vendor_claim/**accept**)。
//   歷史資料還會有那四種值(2026-08-21 老闆親跑正式庫:已按過 accept 的有 31 筆 / 89 件)——
//   本檔只負責「新的選擇」,不負責顯示舊值;
//   舊值的顯示字串是 DB view 自己組的(20260811020010:118「· 已標補出貨,尚未補到」),
//   前端沒有任何 resolution → 文字的對照表 ⇒ 移除選項不會讓舊資料顯示成 undefined。
//   ⛔ 只動畫面,零 RPC 變更、零 migration。
//   📌 那 31 筆要不要把貨沖回總倉＝**另一個案子**(老闆已裁示要做),不在本檔。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";

export type ShortageContext = {
  transfer_item_id: number;
  transfer_id: number;
  transfer_no: string;
  sku_id: number;
  sku_code: string | null;
  sku_label: string;
  qty_shipped: number;
  qty_received: number;
  shortage_qty: number;
  dest_location: number;
  // ⚠️ 本檔已經不用 dest_store_id(它原本只餵「客人在等」那支查詢,已刪)。
  //   **刻意留著這個欄位**:唯一的呼叫點 ExceptionsContent.tsx:171 仍然在傳它,
  //   而 ExceptionsContent.tsx 不在本 PR 的施工範圍內 —— 拿掉欄位會讓那個物件字面
  //   踩到 TypeScript 的多餘屬性檢查、直接編不過。要清就跟那支檔一起清。
  dest_store_id?: number | null;
  dest_store_name: string;
};

// 畫面上只給這兩顆。⭐ 老闆 2026-08-21 定稿:**這個視窗＝總倉回覆店家的話**,
//   不是「總倉內部怎麼處理這批貨」。老闆原話:
//   「這區塊是在處理店家的異常,是要回覆店家的話。接受退貨、不接受退貨而已,
//     接受退貨就是不跟店家收錢,不接受退貨就是要跟店家收錢,然後接受退貨要不要補貨這樣而已。」
//   ⇒ 同意退回-補貨   → redispatch
//     同意退回-不補貨 → restock_hq
//     不同意退貨(＝要跟店家收錢)→ 系統今天做不到 ⇒ ⛔ 不做按鈕,只在下面寫一行說明。
//
// ⛔⛔ 舊的第三顆 accept(原「不接受退回」「公司吃掉這筆損失」)**已整顆移除**,連同它的
//   「原因必填」一起。老闆 2026-08-21 原話:
//   「庫存怎麼可以平白消失,起碼要數量退回庫存,然後再處理這貨品是遺失還是毀損」
//   ⇒「貨不回帳上」這種選項不該存在。⛔ 不要因為 DB 還收 accept 就把它加回畫面。
//   ⛔ 遺失/毀損/向進貨商求償＝貨回到帳上之後總倉自己另一道手續,**不在這個視窗提**。
//   ⛔ 視窗內不准再出現「不接受退回」「當作沒了」「公司吃」「認賠」這些字。
type Resolution = "redispatch" | "restock_hq";

const RESOLUTION_OPTIONS: Array<{
  value: Resolution;
  icon: string;
  title: string;
  desc: string;
  // 按下去會發生什麼「回不去」的事。一律顯示(不是選中才出現)—— 要在按之前就看到才有用。
  warn: string;
  // ⛔ 只剩 caution / info 兩種。原本還有 danger,那是舊 accept 專用的紅底,
  //   accept 移除後一起拿掉,不留沒有人用的樣式(2026-08-21)。
  warnTone: "caution" | "info";
}> = [
  {
    value: "redispatch",
    icon: "🔁",
    // ⛔ 標題是老闆 2026-08-21 逐字定的字樣(對店家講的話),不要改寫、不要加系統講法。
    title: "同意退回-補貨",
    desc:
      "少收的數量以原出庫成本記回「原本送貨出去的那一邊」，並自動開一張撿貨單給該店 —— " +
      "撿貨單會出現在收件匣的「📋 撿貨單」，樓下撿完再送一次。",
    warnTone: "info",
    // 出處:記回原出貨端 20260811020000:188-206
    //      (rpc_inbound 的 p_location_id => v_transfer.source_location,不是寫死總倉);
    //      自動開 draft 撿貨單 20260811020000:222-245;
    //      draft 在收件匣撿貨單匣算待處理 hq/inbox/page.tsx 的 classifyPicking。
    // ⛔ 刻意不寫「客人訂單會自動推進」:那要再走 rpc_mark_orders_shipping_for_wave
    //    (20260614000050 最新版)且要 campaign 對得上,本檔沒有實測過 ⇒ 不寫進畫面。
    warn: "要再送一批給這家店 → 選這顆。按完這一筆會從清單消失，但貨已經記回去、撿貨單也開好了。",
  },
  {
    value: "restock_hq",
    icon: "🏭",
    // ⛔ 同上,老闆逐字定的字樣。
    title: "同意退回-不補貨",
    desc: "少收的數量以原出庫成本記回「原本送貨出去的那一邊」，不會自動再送給店家。",
    warnTone: "caution",
    // 出處:記回原出貨端 20260811020000:140-163
    //      (同樣是 p_location_id => v_transfer.source_location;
    //       ⚠️ restock_hq 這一支「沒有」總倉守衛 —— redispatch 有 :172-177 擋非總倉,
    //       restock_hq 沒有 ⇒ 店對店的單按這顆,貨是回到原本那家店,不是總倉)。
    // ⛔ 這裡刻意不寫「開補貨申請就派得出去」:那條路的可配量 hq_supply 讀的是
    //    「總倉的」stock_balances.on_hand(v_picking_demand_no_po 最新版
    //    20260612000040:60-78)⇒ 只有貨真的回到總倉才成立。
    //    它被移到下面 srcIsHq === true 才顯示的那一塊。
    warn:
      "按下去回不來，這一筆會從清單消失，而且系統不會自動再送貨給這家店 —— " +
      "之後要補給這家店，得另外開單。",
  },
];

// warn 方塊的色底 —— 刻意用「擋眼」的實心底色,不是灰色小字(理由見檔頭的實測數字)
const WARN_TONE_CLASS: Record<"caution" | "info", string> = {
  caution:
    "border-amber-300 bg-amber-100 text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200",
  info: "border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-800 dark:bg-blue-950/60 dark:text-blue-200",
};

export function TransferShortageResolveModal({
  ctx,
  onClose,
  onSubmitted,
}: {
  ctx: ShortageContext;
  onClose: () => void;
  onSubmitted: () => void;
}) {
  const [resolution, setResolution] = useState<Resolution | null>(null);
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 這張單的出貨端是不是總倉。null = 還在查 / 查不到 → 這一塊什麼都不顯示。
  // ⭐ 兩顆按鈕的文案本身已經不管出貨端是誰都成立,所以 null 不會造成任何錯誤斷言;
  //    查到 true / false 只是「多講一句」讓人更好判斷,不是在更正上面的字。
  const [srcIsHq, setSrcIsHq] = useState<boolean | null>(null);

  // 出貨端是不是總倉 —— 純粹為了「多講一句」而查(不是拿來更正上面的文案):
  //   ① 兩顆的「記回原本送貨出去的那一邊」實際是 rpc_inbound 到 transfers.source_location
  //      (20260811020000:152-160 / :188-206)。查到是總倉就直接把話講明,使用者不用自己推。
  //   ② 「再補一批」對非總倉出貨的單會被 RPC 直接擋下
  //      (20260811020000:172-177 RAISE「出貨端不是總倉，無法自動重派」)⇒ 值得先講。
  // ⛔⛔ 查不到一律維持 null(什麼都不顯示),絕對不可以讓「查不到」掉進 false 那一邊 ——
  //   false 會渲染出「這張單不是總倉派出去的」這句**斷言**,而我們其實只是沒讀到資料。
  //   (2026-08-21 自審抓到:原本寫 `(l?.type ?? "") === "central_warehouse"`,
  //    locations 那一列讀不到(查無此列 / 被 RLS 擋)時 l 是 null → 算出 false,
  //    於是「我沒查到」被畫成「我確定不是」—— 正是本檔頭第一鐵則禁止的那件事。)
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const sb = getSupabase();
        const { data: t, error: e1 } = await sb
          .from("transfers")
          .select("source_location")
          .eq("id", ctx.transfer_id)
          .maybeSingle();
        if (e1) throw new Error(e1.message);
        const locId = (t as { source_location: number | null } | null)?.source_location;
        if (locId == null) return;
        const { data: l, error: e2 } = await sb
          .from("locations")
          .select("type")
          .eq("id", locId)
          .maybeSingle();
        if (e2) throw new Error(e2.message);
        if (cancelled) return;
        const srcType = (l as { type: string | null } | null)?.type;
        // 沒讀到那一列 / type 是空的 → 維持 null,不要掉進 false(理由見上面的註解)
        if (srcType == null) return;
        setSrcIsHq(srcType === "central_warehouse");
      } catch (e) {
        if (!cancelled) console.warn("查出貨端失敗:", e);
      }
    })();
    return () => { cancelled = true; };
  }, [ctx.transfer_id]);

  // ⛔ 這裡原本有「原因必填」(reasonRequired / reasonMissing),那是舊 accept 專用的 ——
  //   accept 移除後整段一起刪乾淨,不留死碼(2026-08-21 老闆定稿)。
  //   現在兩顆都是「同意退回」,備註一律選填。

  async function submit() {
    if (!resolution) {
      setError("請選擇怎麼處理");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { error: e } = await sb.rpc("rpc_resolve_transfer_item_shortage", {
        p_transfer_item_id: ctx.transfer_item_id,
        p_resolution: resolution,
        p_notes: notes || null,
        p_operator: operator,
      });
      if (e) throw new Error(translateRpcError(e));
      onSubmitted();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal open onClose={onClose} title="處理店家少收的貨" maxWidth="max-w-3xl">
      {/* 這一筆的數字 */}
      <div className="rounded-md border border-rose-200 bg-rose-50 p-3 dark:border-rose-900 dark:bg-rose-950/40">
        <div className="flex flex-wrap items-baseline gap-2">
          <span className="font-mono text-sm">{ctx.transfer_no}</span>
          <span className="text-xs text-zinc-500">→ {ctx.dest_store_name}</span>
        </div>
        <div className="mt-1 text-sm">
          <span className="font-mono text-[11px] text-zinc-500">{ctx.sku_code}</span>
          <span className="ml-1 font-medium">{ctx.sku_label}</span>
        </div>
        <div className="mt-2 grid grid-cols-3 gap-2 text-xs">
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">派出</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_shipped}</div>
          </div>
          <div className="rounded border border-zinc-200 bg-white p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <div className="text-zinc-500">店家實收</div>
            <div className="font-mono text-base font-semibold">{ctx.qty_received}</div>
          </div>
          <div className="rounded border border-rose-300 bg-rose-100 p-2 dark:border-rose-700 dark:bg-rose-900/40">
            <div className="text-rose-700 dark:text-rose-300">少收</div>
            <div className="font-mono text-base font-bold text-rose-700 dark:text-rose-300">{ctx.shortage_qty}</div>
          </div>
        </div>
      </div>

      {/* 兩顆處理鈕 —— 這是「回覆店家」的兩個答案 */}
      <div className="mt-4 space-y-2">
        <div className="text-xs font-semibold text-zinc-700 dark:text-zinc-300">要怎麼回覆店家？ *</div>

        <div className="rounded border-2 border-rose-400 bg-rose-100 p-2 text-[11px] leading-relaxed text-rose-900 dark:border-rose-600 dark:bg-rose-950 dark:text-rose-200">
          <div className="font-bold">⚠️ 兩顆都是按下去就回不來，先想清楚再按</div>
          <div className="mt-0.5">
            按完之後這一筆就會從「異常」清單消失，<span className="font-bold">不能再改選別的</span>。
          </div>
        </div>

        {/* 這張單是誰派出去的 —— 只在「查到答案」時才多講一句。
            ⭐ 上面兩顆的文案本身已經不管出貨端是誰都成立(不再寫死「總倉」),
            所以這一塊純粹是「多給資訊」,不是拿來補救錯字 ⇒
            還在查 / 查不到而什麼都沒顯示時,畫面上也不會有任何一句是錯的,
            使用者搶在查完之前按下送出也不會被騙。
            (2026-08-21 上一版的做法相反:預設文案寫死「總倉」,靠這一塊去更正,
             於是查詢還沒回來的那幾百毫秒裡畫面就在說謊 ⇒ 被複審判 P0。) */}
        {srcIsHq === true && (
          <div className="rounded border border-zinc-300 bg-zinc-50 p-2 text-[11px] leading-relaxed text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
            這張單是<span className="font-bold">總倉</span>派出去的 →
            上面說的「原本送貨出去的那一邊」就是總倉。
            貨記回總倉之後就算進總倉的可配量 —— 要再補給這家店，請該店開一張補貨申請，
            總倉核准後就能直接派，不用再進一次貨（要是這批貨先被別的單配走了，就得等下一批）。
          </div>
        )}
        {/* 出處:可配量 hq_supply 直接讀總倉 stock_balances.on_hand
            (v_picking_demand_no_po 最新版 20260612000040:60-78),不需要採購單、不需要進貨單。
            ⚠️ 最後那個括號不是廢話:hq_supply 讀的是「當下的」on_hand,回總倉的貨並沒有被
            這家店保留住,別的需求先配走就沒了 ⇒ 不加這句就會變成一句「一定派得到」的保證。 */}

        {/* ⛔ 這裡刻意不寫「退回原本那家店」,而是沿用上面兩顆的同一個講法。
            locations.type 現在的 CHECK 只有 'central_warehouse' / 'store' 兩種
            (20260805000010_rpc_upsert_store_auto_location.sql:13 的原話),
            所以今天「不是總倉 ⇒ 就是店」剛好成立 —— 但那是靠一條「現在只有兩種值」的
            schema 假設撐著的,以後多一種 type 這句話就變假。
            用「原本送貨出去的那一邊」不依賴任何假設,而且跟兩顆按鈕的用字一致。 */}
        {srcIsHq === false && (
          <div className="rounded border-2 border-amber-400 bg-amber-100 p-2 text-[11px] leading-relaxed text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-200">
            <span className="font-bold">這張單不是總倉派出去的。</span>
            貨會退回<span className="font-bold">原本送貨出去的那一邊</span>（不是總倉），
            而且「<span className="font-bold">同意退回-補貨</span>」按下去會被系統擋掉 —— 只有總倉派出去的單能自動補。
          </div>
        )}
        {/* 出處:redispatch 對非總倉出貨會 RAISE(20260811020000:172-177);
            restock_hq 沒有這道守衛,照樣把貨記回 v_transfer.source_location(:152-160)。 */}

        {RESOLUTION_OPTIONS.map((opt) => {
          const active = resolution === opt.value;
          return (
            <label
              key={opt.value}
              className={`flex cursor-pointer items-start gap-3 rounded-md border p-3 transition ${
                active
                  ? "border-blue-400 bg-blue-50 dark:border-blue-700 dark:bg-blue-950/30"
                  : "border-zinc-200 bg-white hover:bg-zinc-50 dark:border-zinc-800 dark:bg-zinc-900 dark:hover:bg-zinc-950"
              }`}
            >
              <input
                type="radio"
                name="resolution"
                value={opt.value}
                checked={active}
                onChange={() => setResolution(opt.value)}
                className="mt-1"
              />
              <div className="flex-1">
                <div className="flex items-baseline gap-2">
                  <span className="text-base">{opt.icon}</span>
                  <span className="font-medium">{opt.title}</span>
                </div>
                <div className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">{opt.desc}</div>
                {/* 「按下去會發生什麼回不去的事」一律顯示,不只在選中時才出現 ——
                    要在按之前就看到才有用。⛔ 不可以改回無底色的小灰字:2026-08-21 實測
                    「不補」被誤按的次數是「補一批」的 3.7 倍(理由見檔頭)。 */}
                <div
                  className={`mt-1.5 rounded border px-2 py-1.5 text-[11px] leading-relaxed ${
                    WARN_TONE_CLASS[opt.warnTone]
                  }`}
                >
                  {opt.warn}
                </div>
              </div>
            </label>
          );
        })}

        {/* 第三個答案「不同意退貨」(＝要跟店家收錢)還沒做 —— ⛔ 刻意做成「說明文字」不是按鈕。
            老闆 2026-08-21 逐字定的話,原因是總倉真的按不出這個結果。
            ⭐ 括號那句是這裡唯一一句「系統會怎樣」的話,出處:
              月結明細與金額都是按 ti.qty_received 算的
              (rpc_generate_hq_to_store_settlement 最新版
               20260807000000_settlement_taipei_month_boundary.sql:103-115 金額、:276-297 明細,
               兩處都帶 AND ti.qty_received > 0),
              而 rpc_resolve_transfer_item_shortage 只寫 shortage_* 欄位、
              **不會動到 qty_received**(20260811020000:262-270 的 UPDATE 欄位清單)
              ⇒ 上面兩顆按完,少收的那幾件都不會進月結單。
            ⛔ 這句只描述月結是怎麼算出來的,不寫「一定不會被收錢」——
              月結另有人工調整那條路(20260801000000_settlement_manual_adjustment),不歸這個視窗管。
            ⛔⛔ 這一段查到最新版用的是標準查法(帶 public. 選擇性前綴),
              rpc_generate_hq_to_store_settlement 共 8 版,20260807000000 是最後一支。 */}
        <div className="rounded border border-zinc-300 bg-zinc-50 p-2 text-[11px] leading-relaxed text-zinc-700 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
          🚧 要跟店家收錢（不同意退貨）的功能還在施工，這種先不要按、這筆會留在清單。
          <div className="mt-0.5 opacity-80">
            （月結是按店家<span className="font-bold">實際收到</span>的數量算錢，
            所以上面兩顆按完，少收的這幾件都不會算進店家的月結單。）
          </div>
        </div>
      </div>

      {/* 備註 —— 兩顆都是選填(舊的「不接受的原因（必填）」隨 accept 一起移除) */}
      <label className="mt-4 block text-xs">
        <span className="block font-semibold text-zinc-700 dark:text-zinc-300">備註（選填）</span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder="例如：已通知司機張先生補送 / 物流單號 XXX-XX / 顧客同意延期至下批貨"
          rows={2}
          className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1 text-sm dark:border-zinc-700 dark:bg-zinc-800"
        />
      </label>

      {error && (
        <div className="mt-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="mt-4 flex justify-end gap-2">
        <SpinButton
          onClick={onClose}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
        <SpinButton
          onClick={submit}
          disabled={!resolution || submitting}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
        >
          {submitting ? "處理中…" : "✓ 送出"}
        </SpinButton>
      </div>
    </Modal>
  );
}
