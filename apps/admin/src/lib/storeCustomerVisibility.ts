// 門市「客人看得到」（stores.is_visible_to_customers，20260902020000）在門市管理頁的兩條規則 ——
// 純函式，畫面與檢查程式共用**同一份**：
//   一、表單改「類型」的那一下，「客人看得到」勾選框要變成什麼（visibilityAfterKindChange）
//   二、列表「客人看得到」那一欄是哪一種狀態，含「批發但客人還看得到」的醒目標示（customerVisibilityStatus）
//   畫面：app/(protected)/stores/page.tsx
//   檢查程式：scripts/check-store-customer-visibility.mjs（直接載入這支來考，不抄複本）
//
// 這個欄位只管一件事：客人端 liff-api 的 listStores（會員頁「選擇取貨門市」的選單）
//   只列 is_active = true 而且 is_visible_to_customers = true 的店
//   （supabase/functions/liff-api/index.ts:253-254）。整個 repo 只有那裡讀這個欄位。
//
// ⛔ 只放純函式：不 import supabase、不碰 React、不讀網路；也不要用 enum / namespace ——
//   檢查程式是用 Node 直接載入這支 .ts（只把型別去掉），用了就載不進去。

// ============================================================
// 一、表單改「類型」時，「客人看得到」勾選框要變成什麼
// ============================================================
//
//   改成「批發」       → 取消勾選，並出現一行說明（要給客人看請自己勾回來）
//   改回「包子媽分店」 → 回到「打開表單時」的值。⛔ 不可以一律勾回去：
//                        本來就藏著的店（例：9/02 起用 SQL 對客人藏起來的店）類型切過去再切回來，
//                        就會被不小心公開給客人。
//
// 只在類型「被改的那一下」呼叫。打開表單時不呼叫 —— 打開時照資料庫的值帶（新增門市預設勾選）；
// 使用者之後自己勾／取消勾，也不經過這支。

export type KindChangeResult = {
  /** 改完類型之後勾選框的值（存檔時原樣送給 rpc_upsert_store 的 p_is_visible_to_customers） */
  isVisibleToCustomers: boolean;
  /** 要不要出現「已自動取消勾選」那一行說明：改成批發才出現，改回包子媽分店就收起來 */
  showWholesaleNote: boolean;
};

/**
 * @param nextKind       類型改成什麼（stores.store_kind：'branch' 包子媽分店／'wholesale' 批發）
 * @param openedVisible  打開表單那一刻「客人看得到」的值（新增門市＝true）
 */
export function visibilityAfterKindChange(nextKind: string, openedVisible: boolean): KindChangeResult {
  if (nextKind === "wholesale") return { isVisibleToCustomers: false, showWholesaleNote: true };
  return { isVisibleToCustomers: openedVisible, showWholesaleNote: false };
}

// ============================================================
// 二、列表「客人看得到」那一欄
// ============================================================
//
//   hidden            藏起來：is_visible_to_customers = false
//   inactive          勾著「看得到」，但門市停用 → 選單本來就不會列出
//   wholesale_visible ⚠ 批發，而且客人的選單會列出來 → 老闆要去一家一家取消勾選
//   visible           看得到
//
// ⭐ 判準照抄 listStores 的兩個條件（is_active、is_visible_to_customers），不多也不少：
//   停用的店客人本來就選不到，標成「要處理」只會讓老闆白忙；
//   也不看 deleted_at —— listStores 沒看它（刪除時 rpc_delete_store 會一併停用，
//   20260713000000_rpc_delete_store_allow_active.sql:82-83），這裡多看一個條件，
//   萬一有「已刪除卻還啟用」的資料，畫面就會說客人看不到、客人其實看得到。

export type CustomerVisibilityStatus = "visible" | "hidden" | "inactive" | "wholesale_visible";

export type CustomerVisibilityStore = {
  is_visible_to_customers: boolean;
  is_active: boolean;
  /** 'branch' 包子媽分店／'wholesale' 批發（stores.store_kind，20260922000000） */
  store_kind: string | null;
};

export function customerVisibilityStatus(s: CustomerVisibilityStore): CustomerVisibilityStatus {
  if (s.is_visible_to_customers === false) return "hidden";
  if (!s.is_active) return "inactive";
  return s.store_kind === "wholesale" ? "wholesale_visible" : "visible";
}
