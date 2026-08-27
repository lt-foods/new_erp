"use client";

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { getSupabase } from "@/lib/supabase";
import { translateRpcError } from "@/lib/rpcError";
import { useRole, canSeeBranch } from "@/lib/role";

// 現貨直配：把店內現貨直接配給客人，不需要先開團。
// 配單＝待取 —— 當下不扣庫存、不收款，客人到店取貨時才寫 sale 並結案
// （與到店取貨同一套帳，不會重複扣）。見 20260816000010 migration。
//
// 可配量上限是 **free_with_pool**（在庫 − 待客取 − 等貨 − 在途池子），
// 也就是「自由量 ＋ 已到貨的【內部】店現貨池」：
//   - 別的客人正在等的貨（待客取 / 等貨中）不能從這裡賣掉。
//   - 已到貨的池子（RR- / OV- / AB- 容器單）**可以**：送出時 RPC 會在同一個
//     交易裡把池子扣掉（20260824060000），池子帳跟著動，不會有兩份承諾。
//     ⛔ 不要把上限改回 free —— 線上四間店有 800+ 件貨卡在池子裡配不出去，
//     店員只看到「可配 0」＋「請先新增庫存」，補了帳也還是 0（回報原話：
//     「調整庫存完不能把庫存再轉出去」）。
//   - 還在路上的池子量（在途 RR-）維持保留，那批貨還沒到店。

type MemberHit = {
  id: number;
  member_no: string;
  name: string;
  phone: string | null;
  home_store_name: string | null;
  no_new_order: boolean;
};

type Availability = {
  on_hand: number;
  promised: number;
  waiting: number;
  pool: number;            // 內部現貨池總量（含在途）
  pool_arrived: number;    // 其中已到店的部分 —— 這些配得掉
  free: number;            // 純自由量（沒有任何單掛著）
  free_with_pool: number;  // 可配上限＝自由量 ＋ 已到貨池子
  // 零售價優先（20260827020000 起；之前是分店價優先）。賣給終端客人收零售價。
  suggest_price: number;
  retail_price: number | null;  // 沒設價 = null（跟 0 元區分開）
  branch_price: number | null;
};

const num = (v: unknown) => (v == null ? 0 : Number(v));
const numOrNull = (v: unknown) => (v == null ? null : Number(v));

export function SpotSaleModal({
  storeId,
  storeName,
  skuId,
  skuCode,
  skuLabel,
  onClose,
  onSaved,
}: {
  storeId: number;
  storeName: string;
  skuId: number;
  skuCode: string | null;
  skuLabel: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  // 分店價只給 canSeeBranch 的角色看（跟商品編輯頁同一套收斂）
  const role = useRole();
  const showBranchPrice = canSeeBranch(role);
  const [avail, setAvail] = useState<Availability | null>(null);
  const [term, setTerm] = useState("");
  const [hits, setHits] = useState<MemberHit[]>([]);
  const [searching, setSearching] = useState(false);
  const [member, setMember] = useState<MemberHit | null>(null);
  const [qty, setQty] = useState(1);
  const [price, setPrice] = useState<number | "">("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  // 自由量拆解 + 建議售價（伺服端開單時會再驗一次，這裡只是預檢）
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: e } = await getSupabase().rpc("rpc_get_spot_availability", {
        p_store_id: storeId,
        p_sku_id: skuId,
      });
      if (cancelled) return;
      if (e) {
        setError(translateRpcError(e));
        return;
      }
      const a = (data ?? {}) as Record<string, unknown>;
      const parsed: Availability = {
        on_hand: num(a.on_hand),
        promised: num(a.promised),
        waiting: num(a.waiting),
        pool: num(a.pool),
        pool_arrived: num(a.pool_arrived),
        free: num(a.free),
        free_with_pool: num(a.free_with_pool),
        suggest_price: num(a.suggest_price),
        retail_price: numOrNull(a.retail_price),
        branch_price: numOrNull(a.branch_price),
      };
      setAvail(parsed);
      setQty((q) => Math.max(1, Math.min(q, parsed.free_with_pool)));
      // 建議售價為 0（沒設過價）時留空，逼店員自己填 —— 0 元會在取貨時被擋
      setPrice(parsed.suggest_price > 0 ? parsed.suggest_price : "");
    })();
    return () => {
      cancelled = true;
    };
  }, [storeId, skuId]);

  // 會員搜尋，debounce 250ms。
  // 不在 effect 裡同步 setHits([]) 清單 —— 那會觸發 cascading render
  // （react-hooks/set-state-in-effect）。改成渲染時用 showHits 判斷要不要畫，
  // 舊結果留在 state 裡不礙事。
  useEffect(() => {
    const q = term.trim();
    if (!q || member) return;
    let cancelled = false;
    const t = setTimeout(async () => {
      // setSearching 放進 timeout 裡（不是 effect body）：同步 setState 會被
      // react-hooks/set-state-in-effect 擋。順帶讓「搜尋中…」等 debounce 過了
      // 才出現，打字途中不會每個字都閃一下。
      setSearching(true);
      const { data } = await getSupabase().rpc("rpc_search_members", { p_term: q, p_limit: 8 });
      if (!cancelled) {
        setHits((data as MemberHit[]) ?? []);
        setSearching(false);
      }
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(t);
    };
  }, [term, member]);

  // 有輸入且還沒選人時才畫下拉（取代在 effect 裡清 hits）
  const showHits = term.trim().length > 0 && !member;
  const free = avail?.free ?? 0;
  const cap = avail?.free_with_pool ?? 0; // 可配上限（含已到貨池子）
  // 這次配單會從池子扣掉幾件（超出純自由量的部分）
  const fromPool = Math.max(0, Math.min(qty, cap) - free);
  const priceNum = typeof price === "number" ? price : 0;
  const amount = qty * priceNum;
  const canSubmit = !busy && !!member && qty > 0 && qty <= cap && priceNum > 0;

  async function save() {
    if (!canSubmit || !member) return;
    if (
      !confirm(
        `把「${skuLabel}」×${qty}（$${priceNum}/件）配給 ${member.name}？\n\n` +
          `訂單為「待取」，客人到店取貨時才扣庫存、收款 $${amount}。\n` +
          (fromPool > 0
            ? `其中 ${fromPool} 件來自【內部】${storeName}現貨池，送出後會自動從池子扣掉。\n`
            : "") +
          `配錯可在訂單頁取消品項。`,
      )
    )
      return;
    setBusy(true);
    setError(null);
    try {
      const sb = getSupabase();
      const { data: sess } = await sb.auth.getSession();
      const operator = sess.session?.user?.id;
      if (!operator) throw new Error("尚未登入");
      const { data: res, error: e } = await sb.rpc("rpc_create_spot_sale", {
        p_store_id: storeId,
        p_sku_id: skuId,
        p_qty: qty,
        p_unit_price: priceNum,
        p_member_id: member.id,
        p_operator: operator,
        p_nickname: null,
        p_reason: reason.trim() || null,
        // 已到貨的【內部】店現貨池也算可配量，超出自由量的部分由 RPC 同步扣池子
        // （20260824060000）。不帶這個旗標＝退回舊行為，池子的貨一件都配不出去。
        p_use_pool: true,
      });
      if (e) throw new Error(translateRpcError(e));
      // 20260816000060 起一次配單一張單（不再併進既有單），所以不用再分兩種訊息
      const r = (res ?? {}) as { order_no?: string; amount?: number; from_pool?: number };
      const usedPool = num(r.from_pool);
      alert(
        `✅ 已配給 ${member.name}：${skuLabel} ×${qty}（$${num(r.amount) || amount}）\n\n` +
          `訂單 ${r.order_no ?? ""} · 狀態：待取。\n` +
          (usedPool > 0 ? `已從【內部】${storeName}現貨池扣掉 ${usedPool} 件。\n` : "") +
          `客人到店後在「取貨」頁完成交貨（每次配貨各一張單，可分別取貨）。`,
      );
      onSaved();
      onClose();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Modal open onClose={onClose} title="🤝 配給客人（現貨直配）" maxWidth="max-w-lg">
      <div className="space-y-3 text-sm">
        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-3 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        {/* 商品（唯讀）＋自由量拆解 */}
        <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900/60">
          <div className="font-medium text-zinc-900 dark:text-zinc-100">{skuLabel}</div>
          <div className="mt-0.5 text-xs text-zinc-500">
            {skuCode && <span className="mr-1.5 font-mono">{skuCode}</span>}· {storeName} ·{" "}
            {avail === null ? (
              "載入可配量…"
            ) : (
              <>
                可配{" "}
                <b className={cap > 0 ? "text-emerald-700 dark:text-emerald-400" : "text-rose-600 dark:text-rose-400"}>
                  {cap}
                </b>{" "}
                件
                {cap > free && (
                  <span className="ml-1 text-zinc-400">
                    （自由量 {free} ＋ 內部現貨池 {cap - free}）
                  </span>
                )}
              </>
            )}
          </div>
          {avail && (
            <div className="mt-1 text-[11px] text-zinc-400">
              在庫 {avail.on_hand} − 待客取 {avail.promised} − 等貨中 {avail.waiting} − 內部單{" "}
              {avail.pool}
              {avail.pool > avail.pool_arrived && (
                <span>（其中在途 {avail.pool - avail.pool_arrived} 件不可配）</span>
              )}
            </div>
          )}
          {/* 零售/分店價並列：預填的是零售價，店員要看得出另一個是多少 */}
          {avail && (avail.retail_price != null || avail.branch_price != null) && (
            <div className="mt-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px]">
              {avail.retail_price != null && (
                <span className="rounded bg-emerald-100 px-1.5 py-0.5 font-bold text-emerald-800 dark:bg-emerald-950 dark:text-emerald-300">
                  零售 ${avail.retail_price}
                </span>
              )}
              {showBranchPrice && avail.branch_price != null && (
                <span className="rounded bg-amber-100 px-1.5 py-0.5 font-bold text-amber-800 dark:bg-amber-950 dark:text-amber-300">
                  分店 ${avail.branch_price}
                </span>
              )}
            </div>
          )}
          {/* 會動到池子時一定要講：店家看的可轉出量會跟著少，不講就是憑空消失 */}
          {avail && fromPool > 0 && (
            <div className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-400">
              其中 <b>{fromPool}</b> 件掛在【內部】{storeName}現貨池，送出後會自動從池子扣掉
              （池子會留一列刪除線紀錄）。
            </div>
          )}
          {avail && cap <= 0 && (
            <div className="mt-1.5 text-[11px] text-amber-700 dark:text-amber-400">
              {avail.promised + avail.waiting + avail.pool > avail.on_hand ? (
                <>
                  帳上已超額 {avail.promised + avail.waiting + avail.pool - avail.on_hand} 件
                  （承諾多於在庫）：要用「＋ 新增庫存」補的話得補超過這個數才會有可配量，
                  數量對不上請改走「庫存盤點」重盤一次。
                </>
              ) : (
                <>
                  這批貨都被別的客人佔著（待客取 / 等貨中）。架上實際有更多貨 →
                  先用「＋ 新增庫存」把現貨入帳。
                </>
              )}
            </div>
          )}
        </div>

        {/* 客人 */}
        <div>
          <span className="mb-1 block text-xs text-zinc-500">客人</span>
          {member ? (
            <div className="flex items-center gap-2 rounded-md border border-violet-300 bg-violet-50 px-3 py-2 dark:border-violet-800 dark:bg-violet-950/40">
              <span className="min-w-0 flex-1">
                <span className="font-medium">{member.name}</span>
                <span className="ml-1.5 text-xs text-zinc-500">
                  {member.member_no}
                  {member.phone ? ` · ${member.phone}` : ""}
                  {member.home_store_name ? ` · ${member.home_store_name}` : ""}
                </span>
              </span>
              <SpinButton
                onClick={() => {
                  setMember(null);
                  setTerm("");
                }}
                className="shrink-0 text-xs text-zinc-500 underline"
              >
                換人
              </SpinButton>
            </div>
          ) : (
            <>
              <input
                value={term}
                onChange={(e) => setTerm(e.target.value)}
                placeholder="🔍 搜尋 姓名 / 電話 / 會員編號…"
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
              />
              {showHits && (hits.length > 0 || searching) && (
                <div className="mt-1 max-h-56 overflow-y-auto rounded-md border border-zinc-200 dark:border-zinc-700">
                  {searching && hits.length === 0 && (
                    <div className="px-3 py-2 text-xs text-zinc-500">搜尋中…</div>
                  )}
                  {hits.map((m) => (
                    <SpinButton
                      key={m.id}
                      onClick={() => setMember(m)}
                      disabled={m.no_new_order}
                      title={m.no_new_order ? "此會員已被標記為不可新增訂單" : undefined}
                      className="block w-full border-b border-zinc-100 px-3 py-2 text-left last:border-b-0 hover:bg-zinc-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-zinc-800 dark:hover:bg-zinc-800"
                    >
                      <span className="font-medium">{m.name}</span>
                      <span className="ml-1.5 text-xs text-zinc-500">
                        {m.member_no}
                        {m.phone ? ` · ${m.phone}` : ""}
                        {m.home_store_name ? ` · ${m.home_store_name}` : ""}
                      </span>
                      {m.no_new_order && (
                        <span className="ml-1.5 text-[10px] text-rose-600">（停用）</span>
                      )}
                    </SpinButton>
                  ))}
                </div>
              )}
            </>
          )}
        </div>

        {/* 數量 + 單價 */}
        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">數量</span>
            <input
              type="number"
              min={1}
              max={cap || 1}
              value={qty}
              onChange={(e) => {
                const v = Math.floor(Number(e.target.value));
                setQty(Number.isFinite(v) ? Math.max(0, Math.min(v, cap)) : 0);
              }}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
            />
            <span className="mt-1 block text-[11px] text-zinc-400">
              上限 {cap}
              {cap > free ? `（自由量 ${free} ＋ 池子 ${cap - free}）` : "（自由量）"}
            </span>
          </label>
          <label className="block">
            <span className="mb-1 block text-xs text-zinc-500">單價</span>
            <input
              type="number"
              min={1}
              value={price}
              onChange={(e) => {
                const v = Number(e.target.value);
                setPrice(e.target.value === "" ? "" : Number.isFinite(v) ? Math.max(0, v) : 0);
              }}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-right tabular-nums dark:border-zinc-700 dark:bg-zinc-800"
            />
            <span className="mt-1 block text-[11px] text-zinc-400">
              {priceNum <= 0
                ? "必填，不可為 0"
                : avail?.retail_price != null
                  ? "預填零售價，可改"
                  : "未設零售價，預填分店價，可改"}
            </span>
          </label>
        </div>

        <label className="block">
          <span className="mb-1 block text-xs text-zinc-500">備註（選填）</span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="例：客人臨櫃指定"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 dark:border-zinc-700 dark:bg-zinc-800"
          />
        </label>

        <div className="rounded-md border border-violet-200 bg-violet-50 px-3 py-2 text-xs text-violet-800 dark:border-violet-900 dark:bg-violet-950/40 dark:text-violet-300">
          送出＝把貨配到客人名下（<b>待取</b>）。現在不扣庫存、不收款；
          客人取貨時才扣庫存、收款（取貨頁）。
        </div>

        <div className="flex items-center justify-end gap-2 pt-1">
          <SpinButton
            onClick={onClose}
            className="rounded-md border border-zinc-300 px-4 py-2 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={save}
            disabled={!canSubmit}
            className="rounded-md bg-violet-600 px-5 py-2 font-semibold text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:bg-zinc-300 dark:disabled:bg-zinc-700"
          >
            {busy
              ? "處理中…"
              : member
                ? `配給${member.name}${qty > 0 && priceNum > 0 ? `（${qty} 件 · $${amount}）` : ""}`
                : "請先選客人"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

export default SpotSaleModal;
