"use client";

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { cleanRichTextCampaignText } from "@/lib/text";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";

export type StorageType = "room_temp" | "refrigerated" | "frozen" | "meal_train" | null;

export type SelectedProduct = {
  id: number;
  name: string;
  storage_type: StorageType;
};

// 取貨天數 by 溫層（收單時間 + N 天 = 取貨截止）
const PICKUP_DAYS_BY_STORAGE: Record<string, number> = {
  frozen: 14,
  refrigerated: 14,
  room_temp: 30,
  meal_train: 7,
};
const DEFAULT_PICKUP_DAYS = 21;

function pickupDaysForStorageTypes(types: (StorageType | null)[]): number {
  const all = types.filter(Boolean) as string[];
  if (all.includes("frozen") || all.includes("refrigerated")) {
    return Math.min(...all.map((t) => PICKUP_DAYS_BY_STORAGE[t] ?? DEFAULT_PICKUP_DAYS));
  }
  if (all.length === 0) return DEFAULT_PICKUP_DAYS;
  return Math.max(...all.map((t) => PICKUP_DAYS_BY_STORAGE[t] ?? DEFAULT_PICKUP_DAYS));
}

function toDatetimeLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function dateInputValue(d: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function storeEndAtFromCustomerEndAt(customerEndAt: string): string {
  if (!customerEndAt) return "";
  const d = new Date(customerEndAt);
  if (Number.isNaN(d.getTime())) return "";
  d.setDate(d.getDate() + 1);
  d.setHours(23, 59, 0, 0);
  return toDatetimeLocal(d.toISOString());
}

function pickupDeadlineFromEndAt(endAt: string, pickupDays: number): string {
  const d = new Date(endAt);
  if (Number.isNaN(d.getTime())) return "";
  d.setDate(d.getDate() + pickupDays);
  return dateInputValue(d);
}

export function CreateCampaignModal({
  products,
  onClose,
  onCreated,
}: {
  products: SelectedProduct[];
  onClose: () => void;
  onCreated: (campaignId: number) => void;
}) {
  const today = new Date();
  const defaultCustomerEndAt = new Date(today);
  defaultCustomerEndAt.setDate(today.getDate() + 3);
  defaultCustomerEndAt.setHours(23, 59, 0, 0);
  const defaultCustomerEndAtValue = toDatetimeLocal(defaultCustomerEndAt.toISOString());
  const defaultEndAtValue = storeEndAtFromCustomerEndAt(defaultCustomerEndAtValue);
  const defaultStartAtValue = toDatetimeLocal(today.toISOString());

  const storageTypes = products.map((p) => p.storage_type);
  const pickupDays = pickupDaysForStorageTypes(storageTypes);

  const defaultName = products.length <= 3
    ? products.map((p) => p.name).join(" / ")
    : `${products[0].name} 等 ${products.length} 項商品`;

  const [name, setName] = useState(defaultName);
  const [startAt, setStartAt] = useState(defaultStartAtValue);
  const [customerEndAt, setCustomerEndAt] = useState(defaultCustomerEndAtValue);
  const [endAt, setEndAt] = useState(defaultEndAtValue);
  const [endAtTouched, setEndAtTouched] = useState(false);
  const [pickupDeadline, setPickupDeadline] = useState(() => pickupDeadlineFromEndAt(defaultEndAtValue, pickupDays));
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [campaignNo, setCampaignNo] = useState<string>("（產生中…）");
  // 文案：預設帶入「商品文案」(products.description)，可編輯
  const [description, setDescription] = useState("");

  // fetch preview campaign_no
  useEffect(() => {
    getSupabase().rpc("rpc_next_campaign_no").then(({ data }) => {
      if (data) setCampaignNo(data as string);
    });
  }, []);

  // 預設帶入商品文案（1 campaign : 1 product，取第一個商品的 description）
  useEffect(() => {
    const pid = products[0]?.id;
    if (!pid) return;
    let alive = true;
    getSupabase()
      .from("products")
      .select("description")
      .eq("id", pid)
      .maybeSingle()
      .then(({ data }) => {
        if (alive && data?.description) setDescription(cleanRichTextCampaignText(data.description as string));
      });
    return () => { alive = false; };
  }, [products]);

  // 客人收單改了且店家收單還沒被手動改過，就自動帶隔天 23:59。
  function handleCustomerEndAtChange(val: string) {
    setCustomerEndAt(val);
    if (endAtTouched) return;
    const nextEndAt = storeEndAtFromCustomerEndAt(val);
    setEndAt(nextEndAt);
    if (nextEndAt) setPickupDeadline(pickupDeadlineFromEndAt(nextEndAt, pickupDays));
  }

  // auto-update pickup_deadline when store end_at changes
  function handleEndAtChange(val: string) {
    setEndAtTouched(true);
    setEndAt(val);
    if (!val) return;
    const nextPickupDeadline = pickupDeadlineFromEndAt(val, pickupDays);
    if (nextPickupDeadline) setPickupDeadline(nextPickupDeadline);
  }

  async function handleSave() {
    if (!name.trim()) { setError("請輸入團名稱"); return; }
    if (!startAt) { setError("請設定開團時間"); return; }
    if (!customerEndAt) { setError("請設定客人收單時間"); return; }
    if (!endAt) { setError("請設定店家收單時間"); return; }
    const startTime = new Date(startAt).getTime();
    const customerEndTime = new Date(customerEndAt).getTime();
    const endTime = new Date(endAt).getTime();
    if ([startTime, customerEndTime, endTime].some(Number.isNaN)) {
      setError("請確認開團與收單時間");
      return;
    }
    if (startTime >= customerEndTime) {
      setError("開團時間必須早於客人收單時間");
      return;
    }
    if (endTime < customerEndTime) {
      setError("店家收單不能早於客人收單");
      return;
    }
    setSaving(true); setError(null);
    try {
      // 1 campaign : 1 product invariant — UI 端已限制 products.length=1
      if (products.length !== 1) {
        throw new Error("一個開團只能對應一個商品");
      }
      const { data, error: err } = await getSupabase().rpc("rpc_create_campaign_from_product", {
        p_name: name.trim(),
        p_end_at: new Date(endAt).toISOString(),
        p_pickup_deadline: pickupDeadline || null,
        p_product_id: products[0].id,
        p_description: description.trim(),
        p_customer_end_at: new Date(customerEndAt).toISOString(),
        p_start_at: new Date(startAt).toISOString(),
        p_auto_open: true,
      });
      if (err) throw err;
      onCreated(Number(data));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSaving(false);
    }
  }

  const inputCls = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <div className="space-y-4">
      <div className="rounded-md border border-blue-100 bg-blue-50 px-3 py-2 text-xs text-blue-800 dark:border-blue-900 dark:bg-blue-950 dark:text-blue-200">
        已選 {products.length} 項商品 · {products.map((p) => p.name).join("、")}
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">團號</span>
          <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-sm text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 select-all">
            {campaignNo}
          </div>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">開團時間 <span className="text-red-500">*</span></span>
          <input
            type="datetime-local"
            value={startAt}
            max={customerEndAt || undefined}
            onChange={(e) => setStartAt(e.target.value)}
            className={inputCls}
          />
          <span className="text-xs text-zinc-400">未來時間會先建成草稿、不會提前出現在商城，時間到自動開團</span>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">客人收單 <span className="text-red-500">*</span></span>
          <input
            type="datetime-local"
            value={customerEndAt}
            onChange={(e) => handleCustomerEndAtChange(e.target.value)}
            className={inputCls}
          />
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">店家收單 <span className="text-red-500">*</span></span>
          <input
            type="datetime-local"
            value={endAt}
            min={customerEndAt || undefined}
            onChange={(e) => handleEndAtChange(e.target.value)}
            className={inputCls}
          />
          <span className="text-xs text-zinc-400">預設為客人收單隔天 23:59，可手動改</span>
        </label>

        <label className="flex flex-col gap-1 text-sm sm:col-span-2">
          <span className="text-zinc-600 dark:text-zinc-400">團名稱 <span className="text-red-500">*</span></span>
          <input value={name} onChange={(e) => setName(e.target.value)} className={inputCls} />
        </label>

        <label className="flex flex-col gap-1 text-sm sm:col-span-2">
          <span className="text-zinc-600 dark:text-zinc-400">
            文案
            <span className="ml-1 text-xs text-zinc-400">（會顯示在會員 App，預設帶入商品文案，可修改）</span>
          </span>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={4}
            placeholder="輸入要顯示給顧客看的開團文案…"
            className={`${inputCls} resize-y whitespace-pre-wrap`}
          />
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-600 dark:text-zinc-400">
            取貨截止日
            <span className="ml-1 text-xs text-zinc-400">（依溫層自動計算，可調整）</span>
          </span>
          <DatePicker
            value={pickupDeadline}
            onChange={setPickupDeadline}
            className={inputCls}
          />
        </label>

        <div className="flex flex-col gap-1 text-sm">
          <span className="text-zinc-500">溫層 → 取貨天數</span>
          <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-500 dark:border-zinc-700 dark:bg-zinc-900">
            {products.map((p) => (
              <div key={p.id}>{p.name}：{p.storage_type ?? "未設定"} (+{PICKUP_DAYS_BY_STORAGE[p.storage_type ?? ""] ?? DEFAULT_PICKUP_DAYS}天)</div>
            ))}
          </div>
        </div>
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      <div className="flex items-center gap-3">
        <SpinButton
          type="button"
          onClick={handleSave}
          disabled={saving}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          {saving ? "建立中…" : "建立開團"}
        </SpinButton>
        <SpinButton
          type="button"
          onClick={onClose}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
      </div>
    </div>
  );
}
