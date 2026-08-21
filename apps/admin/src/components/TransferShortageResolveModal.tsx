"use client";

// 店家少收的貨 — 總倉處理視窗
// 顯示:
//   - 這一筆的派出 / 實收 / 少收
//   - 這家店這個品項還有沒有客人在等(一句話講完,明細在下面)
//   - 三顆處理鈕 + 備註
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
// ⭐⭐ 2026-08-21 複審再抓到三顆 P0,三顆都是同一個病:
//   「畫面上先寫一句只在某些情況成立的話,再靠另一個查詢/另一個框去更正它」。
//   ① 兩顆的說明寫死「記回總倉庫存」,但 SQL 是 rpc_inbound 到 v_transfer.source_location
//      (20260811020000:152-160 / :188-206)—— 店對店的單是回原本那家店,不是總倉。
//      而且更正用的黃框只在查完才出現、送出鈕在查完前就能按 ⇒ 有一段時間畫面在說謊。
//   ② 客人訂單查詢有 .limit(50),畫面卻把 affected.length 當精確總數講。
//   ③ 「有一部分拿不到」講得比上一個分支(有「可能」)還篤定,而且沒扣既有庫存。
//   ⇒ 修法統一成一條:**先把預設文案改成「不管情況怎樣都成立」**,
//     額外的查詢只拿來「多講一句」,不拿來救錯字。
//     這樣「還在查」「查失敗」「使用者搶先按送出」三種情況自然都不會出事。
//   ⛔ 以後要在畫面加任何一句「系統會怎樣」,先問自己:
//     「這句話在什麼情況下會不成立?」答得出來就不要那樣寫。
//
// ⭐⭐⭐ 2026-08-21 三審又抓到兩顆,兩顆都在**同一句綠字**「✅ 目前沒有客人在等這一項」上。
//   這句是全畫面最危險的一句 —— 它會讓人放心去按「不補」/「不接受退回」,
//   而那兩顆按下去不可逆、這一筆直接從清單消失、事後查不出漏了哪一單。
//   ① (三審 P0,Codex 抓到) 抓滿 CAP 時第 CAP+1 張以後沒查,手上剛好被前端那一刀砍成 0,
//      畫面照樣講「沒有客人在等」⇒ 已拆成兩格,truncated 的 0 改講「不能確定」。
//   ② (施工時自查抓到,Codex 與 CEO 都沒列) 訂單狀態用**白名單**列舉「還在等」的狀態,
//      漏掉了 partially_completed ⇒ 客人領走同一張單的別樣東西、正在等這一樣,
//      畫面卻說「沒有客人在等」。已改成排除終態的黑名單(見 NOT_WAITING_ORDER_STATUSES)。
//   ⇒ 學到的:**同一句斷言可以有好幾個成因,修掉被指出來的那個不等於那句話變真了。**
//     要修一句畫面斷言時,先把「這句話會變假的所有路徑」列完(資料來源的條件、
//     limit、前端過濾、狀態值域全部算),再一次修完。
//   ⛔ 特別檢查所有「綠色的 / 肯定的 / 叫人放心」的文字,它們才是會害人按下不可逆鈕的那些。
//
// ⚠️ 三顆都是單行道(按下去回不來):
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
//   ⇒ 「不補」被按的次數是「補一批」的 3.7 倍(85:23),而還有客人在等時正解是「補一批」。
//   ⛔ 不要為了版面清爽把它改回小灰字。
//   (數字是當時快照、會過期;⛔ 刻意不放進畫面文案,免得變成一句過期的謊)
//
// ⚠️ 畫面上只留三顆,但 DB 的允許值仍是六種
//   (20260811020000:69 的 CHECK 含 replenish/cancel_orders/vendor_claim)。
//   歷史資料還會有那三種值 —— 本檔只負責「新的選擇」,不負責顯示舊值;
//   舊值的顯示字串是 DB view 自己組的(20260811020010:118「· 已標補出貨,尚未補到」),
//   前端沒有任何 resolution → 文字的對照表 ⇒ 移除選項不會讓舊資料顯示成 undefined。
//   ⛔ 只動畫面,零 RPC 變更、零 migration。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import SpinButton from "@/components/SpinButton";
import { Modal } from "@/components/Modal";
import {
  ORDER_STATUS_LABEL,
  ORDER_STATUSES,
  isTerminalStatus,
  type OrderStatus,
} from "@/lib/orderStatus";

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
  dest_store_id?: number | null;
  dest_store_name: string;
};

// 畫面上只給這三顆。老闆的模型:總倉只有兩個決定 —— 貨要不要退回總倉、店家的帳要不要扣。
//   退 + 扣 → redispatch(補一批) / restock_hq(不補)
//   不退 + 扣 → accept
//   不退 + 不扣(把貨算回給店家)→ 系統目前做不到,要另開案 ⇒ 畫面上不放。
type Resolution = "redispatch" | "restock_hq" | "accept";

const RESOLUTION_OPTIONS: Array<{
  value: Resolution;
  icon: string;
  title: string;
  desc: string;
  // 按下去會發生什麼「回不去」的事。一律顯示(不是選中才出現)—— 要在按之前就看到才有用。
  warn: string;
  warnTone: "danger" | "caution" | "info";
}> = [
  {
    value: "redispatch",
    icon: "🔁",
    title: "接受退回 — 貨退回去，再補一批給店家",
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
    warn: "還有客人在等這批貨 → 選這顆。按完這一筆會從清單消失，但貨已經記回去、撿貨單也開好了。",
  },
  {
    value: "restock_hq",
    icon: "🏭",
    title: "接受退回 — 貨退回去，不補",
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
  {
    value: "accept",
    icon: "✋",
    title: "不接受退回",
    desc: "貨不退回去，店家的帳照扣。",
    warnTone: "danger",
    // 出處:accept 在 RPC 裡沒有任何分支,只會走到最後那段 UPDATE
    //      (20260811020000:112-270,只有 restock_hq / redispatch 有 rpc_inbound);
    //      函式 COMMENT 原話「其餘 resolution 僅打標記」(20260811020000:281)。
    warn:
      "⚠️ 系統目前還不會把貨算回給店家，這筆損失公司會吃掉。請在下面寫清楚不接受的原因（會留在紀錄上）。",
  },
];

// warn 方塊的色底 —— 刻意用「擋眼」的實心底色,不是灰色小字(理由見檔頭的實測數字)
const WARN_TONE_CLASS: Record<"danger" | "caution" | "info", string> = {
  danger:
    "border-rose-400 bg-rose-100 font-semibold text-rose-900 dark:border-rose-600 dark:bg-rose-950 dark:text-rose-200",
  caution:
    "border-amber-300 bg-amber-100 text-amber-900 dark:border-amber-700 dark:bg-amber-950 dark:text-amber-200",
  info: "border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-800 dark:bg-blue-950/60 dark:text-blue-200",
};

type AffectedOrder = {
  id: number;
  order_no: string;
  member_id: number | null;
  pending_qty: number;
  status: string;
};

// 客人訂單一次最多抓幾張。
// ⚠️ 這個上限一定會反映到畫面文字上:抓滿了就代表「還有沒抓到的」,
//    那時候畫面不能把 affected.length 當精確總數(2026-08-21 複審 P0:
//    舊版有 .limit(50) 卻寫成「還有 50 張」)。
// 實作上刻意多抓 1 張(limit = CAP + 1):
//   拿回 CAP+1 張 ⇒ 確定超過 CAP ⇒ 畫面多一行「後面還有沒查到的」;
//   拿回 ≤ CAP 張 ⇒ 就是全部,那一行不出現。
// ⚠️⚠️ 2026-08-21 四審更正:這裡原本寫「文案改『至少 N 張』」—— 現在**不是**這樣了。
//   四審 P1 發現另一個反方向的誤差(已退回總倉的沒扣掉 ⇒ 可能更少),
//   兩個誤差一夾,「至少」會變成假話 ⇒ 畫面已改成「查到 N 張 + 兩行誤差說明」。
//   詳細推導見 render 紅字那一段的註解。⛔ 不要照這裡的舊說法把「至少」加回去。
// ⛔ 為什麼不用 { count: 'exact', head: true } 另外抓一次精確筆數:
//   ① 那個 count 數的是「SQL 過濾完」的 customer_orders 筆數,但畫面顯示的清單
//      還要再被下面的前端過濾砍一刀(items 是 cancelled/expired 的不算、
//      pending_qty 合計為 0 的不算)⇒ count 會比清單多,兩個數字對不起來,
//      等於把一種假話換成另一種假話。
//   ② 就算把那兩個條件搬到 SQL 去,「合計 N 件」的件數還是加不出來
//      (要嘛再開第三支 aggregate,要嘛還是得把全部列拉回來)⇒ 件數仍會被低估。
//   多抓 1 列的成本 ≈ 0,而且不用多一次 round-trip。
const AFFECTED_CAP = 50;

// 「還有客人在等」的訂單狀態 —— ⭐ 刻意用「排除終態」的黑名單,不是白名單。
//
// 2026-08-21 三審自查抓到:舊版寫死白名單 .in("status", [pending,confirmed,shipping,ready]),
//   漏掉了 partially_completed(部分取貨)。而 partially_completed 的定義,照
//   rpc_record_pickup 最新版(20260815000000_zero_price_order_guard.sql:365-402)是:
//     取貨後數 status IN ('pending','reserved','ready') 的明細還剩幾筆
//     (並且扣掉「量已被未取退貨蓋掉」的 SKU,見 :369-396 那段 LEFT JOIN),
//     剩 0 → 'completed';剩 >0 → 'partially_completed'
//   ⇒ partially_completed 的字面意思就是「這張單還有品項沒取走」
//
// ⚠️⚠️ 2026-08-21 四審更正:上面這個引用原本寫「最新版 = 20260512000008:148-156」,那是錯的。
//   20260512000008 之後還有 **7 支** migration 改過同一支函式:
//     20260614000030 / 20260630000010 / 20260704000000 /
//     20260731000000_return_deduct_payable_and_pickup_guard /
//     20260801000000_full_return_closes_order / 20260813000000 / 20260815000000
//   結論(partially_completed = 還有品項沒取走)剛好沒變,但引用是過期的。
//   ⛔ 抄這種「最新版是 XXX」之前一定要跑一次標準查法,兩個坑都要避開:
//     ① 早期版本沒有 public. 前綴 ⇒ 只 grep "FUNCTION public.<名>" 會漏掉前 5 支,要寫成:
//        git grep -ln -E "FUNCTION (public\.)?rpc_record_pickup" origin/main -- supabase/migrations | sort
//     ② 光排序時間戳分不出誰後跑 —— 本 repo 有 37 組同時間戳的檔
//        (例:20260801000000 有 5 支、20260731000000 有 2 支)⇒ 要逐一開檔看哪支真的動了那支函式。
//   (本檔其餘 4 處「最新版」四審時一併重驗過,都是對的:
//    v_picking_demand_no_po→20260612000040、v_hq_exceptions→20260811020010、
//    rpc_resolve_transfer_item_shortage→20260811020000、rpc_mark_orders_shipping_for_wave→20260614000050、
//    customer_orders_status_check→20260606000021。)
//   ⇒ 漏掉它 = 客人領走了同一張單的別樣東西、正在等這一樣,畫面卻說「沒有客人在等」。
//   團購一張單本來就常訂好幾樣,短收又正好代表有東西沒到 ⇒ 這是最常見的情境,不是邊界。
//
// ⭐ 為什麼是黑名單:這個畫面的錯誤代價**兩邊完全不對稱**。
//     少報(漏一個「還在等」的狀態)→ 畫面說「沒人在等」→ 有人去按不可逆的「不補」⇒ 客人拿不到貨
//     多報(誤收一個終態)          → 畫面說「有人在等」→ 有人去按「補一批」    ⇒ 多送一趟
//   ⇒ 漏的時候必須往「多報」倒。白名單漏了往少報倒,黑名單漏了往多報倒 ⇒ 用黑名單。
//   (⚠️ 這跟 2026-08-19 陸貨管理那次「黑名單改白名單」的裁示方向相反,不是打架 ——
//    判準是同一條「漏的時候往哪邊倒」,只是這個畫面的安全方向剛好在另一邊。)
//
// ⭐ 而且不自己抄一份清單:直接拿 orderStatus.ts 的 ORDER_STATUSES 過 isTerminalStatus 算出來
//   ⇒ 那邊是 single source of truth(它自己的檔頭這樣宣告,且 DB CHECK 最新版
//     20260606000021_customer_orders_status_check_add_partial.sql:11-15 的 9 個值與它逐字相同),
//     以後那邊加狀態,這裡自動跟著對,不會再長出第二份會過期的清單。
//   ⚠️ 萬一 DB 出現一個 ORDER_STATUSES 沒有的新值 → 它不在黑名單裡 → 會被抓回來(多報)⇒ 安全方向。
const NOT_WAITING_ORDER_STATUSES = ORDER_STATUSES.filter(isTerminalStatus);

// 明細層「已經拿走了」的狀態 —— 這些不算在等。
// ⚠️ 只排 picked_up,刻意**不排** partially_picked_up:後者是「只取走一部分」,
//   剩下那部分客人還在等,排掉會變成少報(危險方向)。
//   (而且它目前是 dead value:全 repo 只有 view 在讀它
//    〔如 20260805000160_allocation_candidates_picked_items.sql:73〕,
//    沒有任何 RPC 會寫入它,orderStatus.ts 的 ORDER_ITEM_STATUS_LABEL 也沒收它
//    ⇒ 現在留不留都不影響畫面,但留著才是日後啟用時安全的那一邊。)
// 出處:排除 picked_up 是既有慣例 —— 互助板同形狀查詢
//   inventory/mutual-aid/page.tsx:2010 濾的就是 (cancelled,expired,picked_up)。
const PICKED_UP_ITEM_STATUSES = ["cancelled", "expired", "picked_up"];

// ⚠️⚠️⚠️ 已知限制(2026-08-21 四審 P1,刻意不修,理由在下面):
//   這個查詢**沒有扣掉「已經退回總倉」的量** ⇒ 算出來的張數/件數是**上限**,不是精確值。
//
// 為什麼會這樣(不是漏寫,是 DB 那邊刻意的):
//   rpc_create_order_return 對「部分退貨」**刻意不動品項行狀態**(保持 active),
//   原話見 20260801000000_full_return_closes_order.sql:20-23 與 :283-284 ——
//   因為 v_customer_order_summary / rpc_wallet_pay_order 的退貨扣減(20260731000000)
//   是把退貨量分攤到「非 cancelled/expired」的品項行,
//   **若把行改 cancelled,扣減會歸零、應收會跳回全額**。
//   ⇒ 部分退貨的單:order 仍是 ready/partially_completed、品項行仍是 active
//     ⇒ 本查詢照樣抓得到 ⇒ 算成「還在等」。
//   (全數退貨不受影響:那時 order 會被收尾成 cancelled/completed,:285-330 ⇒ 黑名單擋掉了。)
//
// ⭐ 方向是安全的:這是**多報**,不是少報。
//     多報 → 畫面說「可能有人在等」→ 去按「補一批」⇒ 多送一趟
//     少報 → 畫面說「沒人在等」  → 去按不可逆的「不補」⇒ 客人拿不到貨
//   ⇒ 跟 NOT_WAITING_ORDER_STATUSES 用黑名單是同一條判準「漏的時候往哪邊倒」。
//
// ⛔ 為什麼不真的去扣(甲案):**它失敗的方向是「少報」,而且我這輪驗不了。**
//   要扣就得在前端重寫一份 DB 的規則:transfer_type='return_to_hq'
//   ＋ status IN ('shipped','received') ＋ 用 regex 剖 notes header
//   (`^\[order return([^\]:]*)` 不含「取貨後退回」)＋ 按 SKU 聚合後相減
//   —— 逐字抄自 20260815000000:369-396。這份抄寫有三個問題:
//     ① 抄錯任一個條件就變成**多扣** ⇒ 少報 ⇒ 正是會害客人拿不到貨的那個方向。
//        最容易錯的是那個 regex:「取貨後退回」的退貨**不可以扣**
//        (那些品項行已經是 picked_up、上面那一刀早就排掉了)⇒ 誤扣就是重複扣。
//     ② 沒有可拋棄的測試庫可以驗(沒 docker、沒 psql,唯一連得到的是正式庫,不能拿去試)
//        ⇒ 跟檔尾「甲案為什麼沒做」是同一個困境:用一個驗不了的東西換掉一個已經安全的行為。
//     ③ 那份規則放在 DB,以後 DB 改了(它 3 週內已經改過 2 次:20260731000000→20260801000000)
//        前端這份抄本不會跟著動,而且**它壞掉的時候是無聲的**(數字只會少,畫面看不出來)。
//   ⇒ 換到的好處只是「少送一趟貨」,賠掉的風險是「客人拿不到貨」⇒ 不值得,採乙案。
//   📌 什麼時候值得回頭做甲案:有測試庫能實測、而且改成「由 DB 出一支 view/RPC 回報未取量」
//     (讓規則只有一份、留在 DB)之後 —— 不要在前端養第二份抄本。
//
// ⇒ 乙案的落地方式:**不去算退貨量,改成把畫面的話講到永遠成立**
//   (紅字一律講「可能」+ 明講「沒扣掉退回總倉的」,見 render 那一段)。

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
  const [affected, setAffected] = useState<AffectedOrder[] | null>(null);
  // 查不到(沒有分店 id / 查詢失敗)。⛔ 不可以跟「查到 0 張」混在一起顯示成
  // 「沒有客人在等」—— 那是把「我沒查到」講成「確定沒有」,正是本檔要根絕的那種假話。
  const [affectedFailed, setAffectedFailed] = useState(false);
  // 抓滿 AFFECTED_CAP 了(＝還有沒抓到的)。true 時畫面會多一行「後面還有沒查到的 → 也可能比這多」。
  // (四審前這裡寫「一律加『至少』」,已不成立 —— 理由見 render 紅字那段。)
  const [affectedTruncated, setAffectedTruncated] = useState(false);
  // 這張單的出貨端是不是總倉。null = 還在查 / 查不到 → 這一塊什麼都不顯示。
  // ⭐ 三顆按鈕的文案本身已經不管出貨端是誰都成立,所以 null 不會造成任何錯誤斷言;
  //    查到 true / false 只是「多講一句」讓人更好判斷,不是在更正上面的字。
  const [srcIsHq, setSrcIsHq] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      // 沒有分店 id ＝ 這張單的收貨端不是分店(例如店退回總倉)→ 查不出客人訂單。
      // ⛔ 放在 async 裡而不是 effect body:effect body 同步 setState 會被
      //    react-hooks/set-state-in-effect 擋(原版就在這一行被標紅)。
      if (!ctx.dest_store_id) {
        if (!cancelled) { setAffected([]); setAffectedTruncated(false); setAffectedFailed(true); }
        return;
      }
      try {
        const sb = getSupabase();
        const { data, error: e } = await sb
          .from("customer_orders")
          .select(`id, order_no, status, member_id,
                   items:customer_order_items!inner(qty, status, sku_id)`)
          .eq("pickup_store_id", ctx.dest_store_id)
          // 排除終態,而不是列舉「還在等」的狀態(理由見 NOT_WAITING_ORDER_STATUSES)
          .not("status", "in", `(${NOT_WAITING_ORDER_STATUSES.join(",")})`)
          .eq("items.sku_id", ctx.sku_id)
          .is("transferred_from_order_id", null)
          // 多抓 1 張只為了判斷「有沒有抓滿」(理由見 AFFECTED_CAP 的註解)
          .limit(AFFECTED_CAP + 1);
        if (e) throw new Error(e.message);
        if (cancelled) return;
        const raw = (data ?? []) as Array<{
          id: number;
          order_no: string;
          status: string;
          member_id: number | null;
          items: Array<{ qty: number; status: string; sku_id: number }>;
        }>;
        // 抓回 CAP+1 張 ⇒ 確定還有沒抓到的。第 CAP+1 張只當旗標用,不進清單。
        const truncated = raw.length > AFFECTED_CAP;
        // ⭐⭐ 這一刀「砍完可能變空」,而 truncated 時第 51 張以後根本沒查 ⇒
        //   rows.length === 0 在 truncated 時**不等於**「沒有客人在等」。
        //   render 那邊因此必須把這兩種 0 分開講(見 affected.length === 0 的分支)。
        //   ⛔ 不要以為「SQL 已經濾過了所以這一刀砍不到東西」就把 render 的判斷省掉 ——
        //     那正是三審 P0 的成因。這一刀在什麼情況下會砍到東西,見下面兩行的說明。
        // ⛔ 為什麼不把整刀搬進 SQL(PostgREST 內嵌篩選)一勞永逸:見檔尾「甲案為什麼沒做」。
        const rows = raw.slice(0, AFFECTED_CAP).map((o) => {
          // ⚠️ 這裡的 sku_id 比對跟上面 SQL 的 .eq("items.sku_id") 是**重複**的 ——
          //   重複是刻意的:PostgREST 內嵌篩選在本專案沒有被實測過(既有同形狀查詢
          //   inventory/mutual-aid/page.tsx:2029-2030 前端也照樣再濾一次),
          //   萬一內嵌條件只作用在 items 陣列、沒把整張單濾掉,這一刀是唯一防線。
          //
          // ⚠️⚠️ 2026-08-21 四審更正(P2):這一行原本寫「sku_id 比對**與 status 排除**…是重複的」,
          //   後半是錯的 —— **明細層的 status 排除在 SQL 端根本不存在**,只有這裡有。
          //   三審的存檔訊息與檔尾註解都寫「SQL 端照樣加了條件」,那句話只兌現了一半:
          //     ✅ 真的加了的是**訂單層**:.not("status","in",NOT_WAITING_ORDER_STATUSES)(上面那支查詢)
          //     ❌ 當時講的是**明細層**(items.status)的條件,而它**從來沒加進 SQL**,只在前端這一刀做
          //   ⇒ 所以 PICKED_UP_ITEM_STATUSES 這一刀是明細層的**唯一防線**,不是備援。
          //     ⛔ 不可以因為「SQL 應該已經濾過了」就把它刪掉 —— SQL 沒濾。
          //   (存檔訊息已經推出去、不 rewrite history,所以更正只能寫在這裡。
          //    ⭐ 教訓:回報與存檔訊息裡每一句「我做了 X」都要跟磁碟對得上。
          //    這個案子五輪抓到的病一直是同一個 ——「說的跟做的不一樣」,連存檔訊息也算。)
          const matchingItems = o.items.filter(
            (i) => i.sku_id === ctx.sku_id && !PICKED_UP_ITEM_STATUSES.includes(i.status),
          );
          const pending = matchingItems.reduce((s, i) => s + Number(i.qty), 0);
          return { id: o.id, order_no: o.order_no, member_id: o.member_id, pending_qty: pending, status: o.status };
        // qty 有 DB CHECK 保證恆為正(customer_order_items 建表
        // 20260423120000_stores_order_schema.sql:208「qty NUMERIC(18,3) NOT NULL CHECK (qty > 0)」)
        // ⇒ pending_qty === 0 只可能是 matchingItems 全空,也就是
        //   「這張單的這個品項全被取消/過期/已經領走了」⇒ 這張單確實不在等。
        }).filter((x) => x.pending_qty > 0);
        setAffected(rows);
        setAffectedTruncated(truncated);
        setAffectedFailed(false);
      } catch (e) {
        if (!cancelled) {
          // ⛔ 不要塞進 error 那個紅框:那個框是「送出失敗」用的,會讓人以為按鈕壞了。
          console.warn("查客人訂單失敗:", e);
          setAffected([]);
          setAffectedTruncated(false);
          setAffectedFailed(true);
        }
      }
    })();
    return () => { cancelled = true; };
  }, [ctx.dest_store_id, ctx.sku_id]);

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

  // 「不接受退回」＝公司吃掉這筆損失,一定要留下原因(老闆 2026-08-21 指定必填)
  const reasonRequired = resolution === "accept";
  const reasonMissing = reasonRequired && notes.trim() === "";

  async function submit() {
    if (!resolution) {
      setError("請選擇怎麼處理");
      return;
    }
    if (reasonMissing) {
      setError("選「不接受退回」一定要寫原因。");
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

  const totalAffectedQty = affected?.reduce((s, o) => s + o.pending_qty, 0) ?? 0;

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

      {/* 有沒有客人在等 —— 第一眼就要看懂,這是決定按哪一顆的唯一依據。
          ⛔ 舊版標題寫「📊 該店該品項待處理客戶訂單分析」,老闆看不懂(2026-08-21 退件)。 */}
      <div className="mt-4 rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
        {affected === null ? (
          <div className="p-3 text-xs text-zinc-500">查詢中…</div>
        ) : affectedFailed ? (
          <div className="rounded-md border-l-4 border-amber-400 bg-amber-50 p-3 text-sm text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            ⚠️ 查不到這一項的客人訂單，請自行確認有沒有人在等。
          </div>
        ) : affected.length === 0 && affectedTruncated ? (
          /* ⭐⭐⭐ 三審 P0 就是這一格漏掉了。
             affectedTruncated 代表「抓滿 CAP 了、第 CAP+1 張以後沒查」,
             而手上這 CAP 張又剛好被上面那一刀全砍掉(該品項全取消/過期/已領走)
             ⇒ 手上是 0,但**沒查完的那一段完全未知** ⇒ 絕對不可以講「沒有客人在等」。
             ⛔ 這一格必須跟下面那格的綠字分開:綠字會讓人放心去按「不補」「不接受退回」,
                而那兩顆按下去不可逆、這一筆直接從清單消失、事後查不出漏了哪一單。
             ⭐ 用琥珀色不是綠色 —— 它跟上面「查不到」是同一種話:**我不知道**。 */
          <div className="rounded-md border-l-4 border-amber-400 bg-amber-50 p-3 text-sm font-semibold text-amber-900 dark:bg-amber-950 dark:text-amber-200">
            ⚠️ 不能確定有沒有客人在等，請自行確認
            <div className="mt-0.5 text-[11px] font-normal opacity-80">
              前 {AFFECTED_CAP} 張裡沒有人在等這一項，但這家店這個品項的相關訂單超過 {AFFECTED_CAP} 張，
              第 {AFFECTED_CAP + 1} 張以後這裡沒有查。
            </div>
          </div>
        ) : affected.length === 0 ? (
          /* 走到這裡保證 affectedTruncated === false(上一格已經攔掉 true)
             ⇒ 手上的 0 就是全部的 0 ⇒ 這句綠字才敢講死。
             ⛔ 誰要動上面那一格的條件,先回來確認這句話還成不成立。 */
          <div className="rounded-md border-l-4 border-emerald-400 bg-emerald-50 p-3 text-sm font-semibold text-emerald-900 dark:bg-emerald-950 dark:text-emerald-200">
            ✅ 目前沒有客人在等這一項
            <div className="mt-0.5 text-[11px] font-normal opacity-80">
              （只算這家店、這個品項、還沒取消也還沒領走的訂單）
            </div>
          </div>
        ) : (
          <div>
            {/* ⭐ 這幾行的每個數字都必須「不管什麼情況都成立」。而這個數字有**兩個方向相反**的誤差:
                  ① 抓滿了(affectedTruncated)⇒ 第 CAP+1 張以後沒查 ⇒ 真正在等的可能**更多**
                  ② 已經退回總倉的沒扣掉(理由見 PICKED_UP_ITEM_STATUSES 下面那段「已知限制」)
                     ⇒ 真正在等的可能**更少**
                ⛔⛔ 所以它**既不是上限、也不是下限**,任何「至少 N」「最多 N」都會在某一格變假:
                  「至少 N 張」在 ①+② 同時發生時假掉 —— 手上 50 張裡有 10 張已退回,
                    真正在等的是 40,講「至少 50」就是說謊;
                  「最多 N 張」在 ① 發生時假掉 —— 第 51 張以後可能還有一堆在等。
                  ⇒ 唯一永遠成立的講法:**標題只講「可能」、並講明 N 是「查到的」,
                    再把兩個方向的誤差各自寫成一行小字。**
                  (2026-08-21 四審 P1。三審寫「至少」是只想到 ① 沒想到 ② ——
                   跟那句綠字、跟「實際張數會更多」都是同一個病:把不知道的講成知道。)
                ⭐ 「拿不到」一律留「可能」:這裡只查了「這家店這個品項的待處理客人訂單」,
                  沒有扣掉這家店自己既有的庫存、也沒算其他還沒到的貨
                  ⇒ 少收 N 件不等於真的有 N 件客人拿不到。 */}
            <div className="rounded-md border-l-4 border-rose-500 bg-rose-50 p-3 text-sm font-bold text-rose-900 dark:bg-rose-950 dark:text-rose-200">
              {`🔴 這一項可能還有客人在等 —— 查到 ${affected.length} 張客人訂單（合計 ${totalAffectedQty} 件）`}
              <div className="mt-0.5 space-y-0.5 text-[11px] font-normal opacity-80">
                {/* 比大小的結論一律綁定在「查到的這些訂單」上,不講成全店的實情 ——
                    ① 會讓「全部」以外還有沒查到的,② 會讓查到的其實沒那麼多。 */}
                <div>
                  {totalAffectedQty <= ctx.shortage_qty
                    ? `少收 ${ctx.shortage_qty} 件 ≥ 查到的 ${totalAffectedQty} 件 → 查到的這些訂單可能全部拿不到貨`
                    : `少收 ${ctx.shortage_qty} 件 / 查到 ${totalAffectedQty} 件 → 可能有一部分拿不到`}
                </div>
                {/* ⛔ 下面這兩行是「N 不精確」的唯一告知處,不可以刪 ——
                       刪掉任一行,上面那個 N 就從「可能」變回「確定」,
                       而使用者是拿它去按不可逆的按鈕的。 */}
                <div>⚠️ 已經退回總倉的沒有扣掉 → 實際在等的可能比這少。</div>
                {affectedTruncated && (
                  <div>
                    ⚠️ 一次只查前 {AFFECTED_CAP} 張，第 {AFFECTED_CAP + 1} 張以後沒查 → 也可能比這多。
                  </div>
                )}
              </div>
            </div>
            <ul className="max-h-32 space-y-0.5 overflow-y-auto px-3 py-2 text-xs">
              {affected.slice(0, 10).map((o) => (
                <li key={o.id} className="flex items-baseline gap-2">
                  <span className="font-mono text-zinc-700 dark:text-zinc-300">{o.order_no}</span>
                  <span className="text-zinc-500">會員 #{o.member_id ?? "—"}</span>
                  <span className="text-zinc-500">{o.pending_qty} 件</span>
                  <span className="rounded bg-zinc-100 px-1 py-0.5 text-[9px] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
                    {ORDER_STATUS_LABEL[o.status as OrderStatus] ?? o.status}
                  </span>
                </li>
              ))}
              {affected.length > 10 && (
                <li className="text-[11px] text-zinc-400">
                  … 還有 {affected.length - 10} 張{affectedTruncated ? "以上" : ""}
                </li>
              )}
            </ul>
          </div>
        )}
      </div>

      {/* 三顆處理鈕 */}
      <div className="mt-4 space-y-2">
        <div className="text-xs font-semibold text-zinc-700 dark:text-zinc-300">要怎麼處理？ *</div>

        <div className="rounded border-2 border-rose-400 bg-rose-100 p-2 text-[11px] leading-relaxed text-rose-900 dark:border-rose-600 dark:bg-rose-950 dark:text-rose-200">
          <div className="font-bold">⚠️ 三顆都是按下去就回不來，先想清楚再按</div>
          <div className="mt-0.5">
            按完之後這一筆就會從「異常」清單消失，<span className="font-bold">不能再改選別的</span>。
          </div>
        </div>

        {/* 這張單是誰派出去的 —— 只在「查到答案」時才多講一句。
            ⭐ 上面三顆的文案本身已經不管出貨端是誰都成立(不再寫死「總倉」),
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

        {/* ⛔ 這裡刻意不寫「退回原本那家店」,而是沿用上面三顆的同一個講法。
            locations.type 現在的 CHECK 只有 'central_warehouse' / 'store' 兩種
            (20260805000010_rpc_upsert_store_auto_location.sql:13 的原話),
            所以今天「不是總倉 ⇒ 就是店」剛好成立 —— 但那是靠一條「現在只有兩種值」的
            schema 假設撐著的,以後多一種 type 這句話就變假。
            用「原本送貨出去的那一邊」不依賴任何假設,而且跟三顆按鈕的用字一致。 */}
        {srcIsHq === false && (
          <div className="rounded border-2 border-amber-400 bg-amber-100 p-2 text-[11px] leading-relaxed text-amber-900 dark:border-amber-600 dark:bg-amber-950 dark:text-amber-200">
            <span className="font-bold">這張單不是總倉派出去的。</span>
            貨會退回<span className="font-bold">原本送貨出去的那一邊</span>（不是總倉），
            而且第一顆「再補一批給店家」按下去會被系統擋掉 —— 只有總倉派出去的單能自動補。
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
      </div>

      {/* 備註 —— 選「不接受退回」時必填 */}
      <label className="mt-4 block text-xs">
        <span className="block font-semibold text-zinc-700 dark:text-zinc-300">
          {reasonRequired ? "不接受的原因（必填）*" : "備註（選填）"}
        </span>
        <textarea
          value={notes}
          onChange={(e) => setNotes(e.target.value)}
          placeholder={
            reasonRequired
              ? "例如：店家自己弄丟的 / 已跟店長談過由店家自行吸收 / 送達時清點無誤"
              : "例如：已通知司機張先生補送 / 物流單號 XXX-XX / 顧客同意延期至下批貨"
          }
          rows={2}
          className={`mt-1 w-full rounded-md border bg-white px-2 py-1 text-sm dark:bg-zinc-800 ${
            reasonMissing
              ? "border-rose-400 dark:border-rose-600"
              : "border-zinc-300 dark:border-zinc-700"
          }`}
        />
        {reasonMissing && (
          <span className="mt-1 block text-[11px] font-semibold text-rose-600 dark:text-rose-400">
            這筆損失公司會吃掉，請先寫清楚原因才能送出。
          </span>
        )}
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
          disabled={!resolution || reasonMissing || submitting}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
        >
          {submitting ? "處理中…" : "✓ 送出"}
        </SpinButton>
      </div>
    </Modal>
  );
}

// ============================================================
// 甲案(把前端那一刀搬進 SQL)為什麼沒做 —— 2026-08-21 三審時評估過,結論是「不做」
//
// 甲案長這樣:在查詢裡直接寫 .not("items.status","in","(cancelled,expired,picked_up)"),
// 靠 customer_order_items!inner 把「該品項已全數失效」的整張單濾掉,
// 讓 limit 直接作用在「已經過濾好的訂單」上 ⇒ 前端不用再砍一刀 ⇒
// 「抓滿 + 砍完變空」這一格自然消失。
//
// 兩個前提,一個成立、一個驗不了:
//   ✅ 前提二(合計 > 0 搬得進去嗎):搬得進去。qty 有 CHECK (qty > 0)
//      (20260423120000_stores_order_schema.sql:208)⇒ 只要留下任一筆匹配明細,合計必然為正
//      ⇒ 不需要 SQL 端做 HAVING(PostgREST 本來也做不到 HAVING)。
//   ❌ 前提一(PostgREST 的內嵌篩選在 !inner 下,真的會把整張 top-level 單濾掉嗎):
//      **本輪驗不了。** 本機沒有 docker、沒有 psql(只有 supabase CLI,而它要 docker
//      才起得了本地庫)⇒ 起不了乾淨的 PostgREST 來實測;
//      ⛔ 而唯一連得到的庫是正式庫,不能拿去試。
//      repo 裡雖然有一模一樣的既有寫法(inventory/mutual-aid/page.tsx:2009-2010),
//      但它 :2029-2030 前端又濾了一次一樣的條件 ⇒ 那段程式的正確性不依賴這個前提
//      ⇒ 它證明不了這個前提在本專案成立,只證明「有人這樣寫過」。
//
// ⭐ 決定性的理由不是「驗不了」,是**它失敗的方式是無聲的**:
//   若前提一不成立,那張單照樣被回傳(items 是空陣列)、照樣佔掉 limit 一個名額,
//   前端還是得砍那一刀、還是可能砍成空 ⇒ 洞原封不動,
//   但我會以為修好了、下一輪審查也會以為這條關閉了。
//   ⇒ 「用一個我不能驗證的前提去換掉一道能驗證的防線」= 又一次把「我不知道」畫成「我確定」,
//     正是本檔頭第一鐵則禁止的那件事,只是這次搬到程式碼層。
//
// ⇒ 採乙案:前端那一刀**保留**當防線,並在 render 把「查完的 0」和「沒查完的 0」分成兩句話講。
//   這條路的正確性完全不依賴 PostgREST 的內嵌篩選行為 ⇒ 讀碼就能驗證。
//
// ⚠️⚠️ 2026-08-21 四審更正(P2):這一段原本寫「採乙案:**SQL 端照樣加條件**(讓 limit 盡量
//   花在有效訂單上)」—— 那句話沒有兌現,磁碟上不存在這個條件:
//     ✅ SQL 端有的是**訂單層**狀態條件 .not("status","in",NOT_WAITING_ORDER_STATUSES)
//        —— 那是本輪為了修「漏掉 partially_completed」新加的,跟甲案/乙案無關。
//     ❌ 這一段在講的**明細層** .not("items.status","in",…) **從來沒有加**。
//   ⇒ 實際採的是「明細層完全交給前端那一刀」,不是「兩邊都加」。
//     結果上不影響安全(前端那道防線在,見上面 rows 那一段),但敘述與程式不一致本身
//     就是本檔頭第一鐵則要根絕的病 ⇒ 在這裡改正,不留著騙下一個人。
//
// 📌 什麼情況下值得回頭做甲案:有了可拋棄的測試庫(staging / 本地 docker)、
//   並且實測「內嵌篩選會讓 top-level 單消失」為真之後。
//   ⚠️ 即使那時做了,也**不要**移除 render 那一格 —— limit 還在,
//     「抓滿」這件事本身不會消失,truncated 的文案永遠有存在意義。
// ============================================================
