"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";
import { StoreLineOaField } from "@/components/StoreLineOaField";
import { isAdmin, useRole } from "@/lib/role";

const PAGE_SIZE = 20;

type PaymentMethod = "cash" | "credit_card" | "transfer" | "line_pay" | "wallet";
const PAYMENT_LABELS: Record<PaymentMethod, string> = {
  cash: "現金",
  credit_card: "信用卡",
  transfer: "轉帳",
  line_pay: "LINE Pay",
  wallet: "儲值金",
};
const PAYMENT_OPTIONS: PaymentMethod[] = ["cash", "credit_card", "transfer", "line_pay", "wallet"];

type Store = {
  id: number;
  code: string;
  name: string;
  location_id: number | null;
  pickup_window_days: number;
  allowed_payment_methods: PaymentMethod[];
  is_active: boolean;
  notes: string | null;
  line_oa_basic_id: string | null;
  line_liff_id: string | null;
  address: string | null;
  latitude: number | null;
  longitude: number | null;
  updated_at: string;
  deleted_at: string | null;
};

type Location = { id: number; code: string; name: string };

type StoreFormValues = Omit<Store, "id" | "updated_at" | "deleted_at"> & { id: number | null };

const EMPTY: Omit<Store, "id" | "updated_at" | "deleted_at"> = {
  code: "",
  name: "",
  location_id: null,
  pickup_window_days: 5,
  allowed_payment_methods: ["cash"],
  is_active: true,
  notes: null,
  line_oa_basic_id: null,
  line_liff_id: null,
  address: null,
  latitude: null,
  longitude: null,
};

type ActiveFilter = "active" | "all" | "deleted";
type LeleFilter = "all" | "lele_only" | "exclude_lele";

export default function StoresPage() {
  const [rows, setRows] = useState<Store[] | null>(null);
  const [locations, setLocations] = useState<Location[]>([]);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [activeFilter, setActiveFilter] = useState<ActiveFilter>("active");
  const [leleFilter, setLeleFilter] = useState<LeleFilter>("all");
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState<Store | null>(null);
  const [creating, setCreating] = useState(false);
  const [merging, setMerging] = useState<Store | null>(null);
  const role = useRole();
  const [page, setPage] = useState(1);

  useEffect(() => {
    // 草稿與已套用的搜尋字串不同時，代表 debounce 後會觸發一次新查詢 → 開轉圈圈
    setSearching((prev) => (queryDraft !== query ? true : prev));
    const t = setTimeout(() => setQuery(queryDraft), 250);
    return () => clearTimeout(t);
  }, [queryDraft, query]);

  useEffect(() => { setPage(1); }, [query, activeFilter, leleFilter]);

  // 載入 locations (供下拉)
  useEffect(() => {
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("locations")
        .select("id, code, name")
        .eq("type", "store")
        .eq("is_active", true)
        .order("name");
      if (err) setError(err.message);
      else setLocations((data ?? []) as Location[]);
    })();
  }, []);

  async function reload() {
    let q = getSupabase()
      .from("stores")
      .select("id, code, name, location_id, pickup_window_days, allowed_payment_methods, is_active, notes, line_oa_basic_id, line_liff_id, address, latitude, longitude, updated_at, deleted_at")
      .order("updated_at", { ascending: false })
      .limit(500);
    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`code.ilike.%${safe}%,name.ilike.%${safe}%`);
    }
    if (activeFilter === "active") q = q.eq("is_active", true).is("deleted_at", null);
    else if (activeFilter === "all") q = q.is("deleted_at", null);
    else if (activeFilter === "deleted") q = q.not("deleted_at", "is", null);
    if (leleFilter === "lele_only") q = q.like("code", "LELE-%");
    else if (leleFilter === "exclude_lele") q = q.not("code", "like", "LELE-%");
    try {
      const { data, error: err } = await q;
      if (err) { setError(err.message); return; }
      setError(null);
      setRows((data ?? []) as Store[]);
    } finally {
      setSearching(false);
    }
  }
  useEffect(() => { reload(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [query, activeFilter, leleFilter]);

  const totalPages = Math.max(1, Math.ceil((rows?.length ?? 0) / PAGE_SIZE));
  const paginated = useMemo(
    () => (rows ?? []).slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [rows, page],
  );

  async function handleDelete(r: Store) {
    const ok = window.confirm(
      `確定刪除門市「${r.name}」(${r.code})？\n\n` +
      `刪除會同時停用該門市、並從預設列表消失（可在「僅已刪除」找到並還原）。\n` +
      `若有進行中訂單或補貨申請，後端會拒絕。`,
    );
    if (!ok) return;
    try {
      const { error: err } = await getSupabase().rpc("rpc_delete_store", { p_id: r.id });
      if (err) throw err;
      setError(null);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  async function handleRestore(r: Store) {
    if (!window.confirm(`還原門市「${r.name}」(${r.code})？\n還原後仍為停用狀態、需手動啟用。`)) return;
    try {
      const { error: err } = await getSupabase()
        .from("stores")
        .update({ deleted_at: null })
        .eq("id", r.id);
      if (err) throw err;
      setError(null);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  async function save(v: StoreFormValues, geoDirty: boolean) {
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_upsert_store", {
        p_id: v.id ?? null,
        p_code: v.code.trim(),
        p_name: v.name.trim(),
        p_location_id: v.location_id,
        p_pickup_window_days: v.pickup_window_days,
        p_allowed_payment_methods: v.allowed_payment_methods,
        p_is_active: v.is_active,
        p_notes: v.notes,
        p_line_oa_basic_id: v.line_oa_basic_id,
      });
      if (err) throw err;
      // 地址／座標走另一支 RPC（rpc_upsert_store 的參數個數改過一次就撞過
      // overload，見 20260809000000 的說明）。只有真的動到才呼叫 —— 它限
      // owner/admin，沒改卻照打會讓其他角色連「改備註」都被擋。
      const savedId = v.id ?? (typeof data === "number" ? data : null);
      if (geoDirty && savedId != null) {
        const { error: geoErr } = await getSupabase().rpc("rpc_set_store_geo", {
          p_store_id: savedId,
          p_address: v.address,
          p_latitude: v.latitude,
          p_longitude: v.longitude,
        });
        if (geoErr) throw geoErr;
      }
      setEditing(null);
      setCreating(false);
      setError(null);
      await reload();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setError(/duplicate key|unique/.test(msg) ? `代碼 ${v.code} 已存在` : msg);
    }
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">門市</h1>
          <p className="text-sm text-zinc-500">共 {rows?.length ?? 0} 筆</p>
        </div>
        {!creating && !editing && (
          <SpinButton
            onClick={() => setCreating(true)}
            className="rounded-md bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            新增門市
          </SpinButton>
        )}
      </header>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {creating && (
        <StoreForm
          initial={{ ...EMPTY, id: null }}
          title="新增"
          locations={locations}
          onCancel={() => setCreating(false)}
          onSave={(v, geoDirty) => save({ ...v, id: null }, geoDirty)}
        />
      )}

      <div className="grid gap-3 sm:grid-cols-3">
        <div className="relative">
          <input
            type="search"
            value={queryDraft}
            onChange={(e) => setQueryDraft(e.target.value)}
            placeholder="搜尋 代碼 / 名稱"
            className={`${inputCls} w-full pr-8`}
          />
          <SearchSpinner active={searching} />
        </div>
        <select
          value={activeFilter}
          onChange={(e) => setActiveFilter(e.target.value as ActiveFilter)}
          className={inputCls}
        >
          <option value="active">僅啟用中</option>
          <option value="all">全部（含停用）</option>
          <option value="deleted">僅已刪除</option>
        </select>
        <select
          value={leleFilter}
          onChange={(e) => setLeleFilter(e.target.value as LeleFilter)}
          className={inputCls}
        >
          <option value="all">全部來源</option>
          <option value="lele_only">僅樂樂自動建</option>
          <option value="exclude_lele">排除樂樂自動建</option>
        </select>
      </div>

      <Table>
        <THead>
          <Th>代碼</Th>
          <Th>名稱</Th>
          <Th>LINE@</Th>
          <Th>對應 location</Th>
          <Th align="right">取貨窗 (天)</Th>
          <Th>付款方式</Th>
          <Th>狀態</Th>
          <Th>更新</Th>
          <Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={9} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={9}>沒有符合條件的門市</EmptyRow>
          ) : (
            paginated.map((r) =>
              editing?.id === r.id ? (
                <tr key={r.id}>
                  <td colSpan={9} className="p-0">
                    <StoreForm
                      initial={{ ...r, id: r.id }}
                      title="編輯"
                      locations={locations}
                      onCancel={() => setEditing(null)}
                      onSave={(v, geoDirty) => save({ ...v, id: r.id }, geoDirty)}
                    />
                  </td>
                </tr>
              ) : (
                <Tr key={r.id}>
                  <Td className="font-mono text-xs">
                    <div className="flex items-center gap-1.5">
                      <span>{r.code}</span>
                      {r.code.startsWith("LELE-") && (
                        <span
                          title="樂樂 CSV 匯入時自動建立"
                          className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-normal text-amber-700 dark:bg-amber-950 dark:text-amber-300"
                        >
                          樂樂
                        </span>
                      )}
                    </div>
                  </Td>
                  <Td>
                    <div className="flex items-center gap-1.5">
                      <span>{r.name}</span>
                      {/* 沒座標 = 不會出現在首頁「門市熱賣地圖」上，列表要一眼看得出來 */}
                      {r.latitude == null || r.longitude == null ? (
                        <span
                          title="尚未設定經緯度，不會出現在首頁熱賣地圖上"
                          className="rounded bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400"
                        >
                          無座標
                        </span>
                      ) : null}
                    </div>
                  </Td>
                  {/* 會員端現貨專區的「LINE 詢問」要靠這個值才能直接開對話；
                      沒設的店會退成「複製訊息」，所以列表要一眼看得出哪幾間還沒填。 */}
                  <Td className="whitespace-nowrap font-mono text-xs">
                    {r.line_oa_basic_id ? (
                      r.line_oa_basic_id
                    ) : (
                      <span className="rounded bg-zinc-100 px-1.5 py-0.5 font-sans text-[11px] text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
                        未設定
                      </span>
                    )}
                  </Td>
                  <Td className="text-xs text-zinc-500">
                    {r.location_id
                      ? locations.find((l) => l.id === r.location_id)?.name ?? `#${r.location_id}`
                      : "—"}
                  </Td>
                  <Td align="right" className="font-mono text-xs">{r.pickup_window_days}</Td>
                  <Td className="text-xs">
                    {(r.allowed_payment_methods ?? []).length
                      ? r.allowed_payment_methods.map((m) => PAYMENT_LABELS[m] ?? m).join("、")
                      : "—"}
                  </Td>
                  <Td>
                    {r.deleted_at ? (
                      <span className="inline-block rounded bg-red-100 px-2 py-0.5 text-xs text-red-800 dark:bg-red-950 dark:text-red-300">
                        已刪除
                      </span>
                    ) : (
                      <span
                        className={`inline-block rounded px-2 py-0.5 text-xs ${
                          r.is_active
                            ? "bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300"
                            : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
                        }`}
                      >
                        {r.is_active ? "啟用" : "停用"}
                      </span>
                    )}
                  </Td>
                  <Td className="whitespace-nowrap text-xs text-zinc-500">
                    {new Date(r.updated_at).toLocaleString("zh-TW", { dateStyle: "short", timeStyle: "short" })}
                  </Td>
                  <Td>
                    <div className="flex items-center gap-3">
                      {!r.deleted_at && (
                        <SpinButton
                          onClick={() => setEditing(r)}
                          className="text-xs text-blue-600 hover:underline dark:text-blue-400"
                        >
                          編輯
                        </SpinButton>
                      )}
                      {/* 兩店合併：rpc_merge_stores 本體限 owner/admin，按鈕同步只給管理員層級 */}
                      {!r.deleted_at && isAdmin(role) && (
                        <SpinButton
                          onClick={() => setMerging(r)}
                          className="text-xs text-purple-600 hover:underline dark:text-purple-400"
                        >
                          合併
                        </SpinButton>
                      )}
                      {!r.deleted_at && (
                        <SpinButton
                          onClick={() => handleDelete(r)}
                          className="text-xs text-red-600 hover:underline dark:text-red-400"
                        >
                          刪除
                        </SpinButton>
                      )}
                      {r.deleted_at && (
                        <SpinButton
                          onClick={() => handleRestore(r)}
                          className="text-xs text-amber-600 hover:underline dark:text-amber-400"
                        >
                          還原
                        </SpinButton>
                      )}
                    </div>
                  </Td>
                </Tr>
              ),
            )
          )}
        </TBody>
      </Table>

      {merging && (
        <MergeStoreDialog
          source={merging}
          onClose={() => setMerging(null)}
          onDone={async () => {
            setMerging(null);
            await reload();
          }}
        />
      )}

      {(rows?.length ?? 0) > PAGE_SIZE && (
        <div className="flex flex-wrap items-center justify-end gap-2 text-sm">
          <span className="text-xs text-zinc-500">
            共 {rows?.length ?? 0} 筆 · 顯示 {(page - 1) * PAGE_SIZE + 1} - {Math.min(page * PAGE_SIZE, rows?.length ?? 0)}
          </span>
          <PagerBtn onClick={() => setPage(1)} disabled={page === 1}>« 第一頁</PagerBtn>
          <PagerBtn onClick={() => setPage((p) => Math.max(1, p - 1))} disabled={page === 1}>‹ 上頁</PagerBtn>
          <span className="text-xs text-zinc-500">{page} / {totalPages}</span>
          <PagerBtn onClick={() => setPage((p) => Math.min(totalPages, p + 1))} disabled={page === totalPages}>下頁 ›</PagerBtn>
          <PagerBtn onClick={() => setPage(totalPages)} disabled={page === totalPages}>最末頁 »</PagerBtn>
        </div>
      )}
    </div>
  );
}

function PagerBtn({
  onClick,
  disabled,
  children,
}: {
  onClick: () => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <SpinButton
      onClick={onClick}
      disabled={disabled}
      className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
    >
      {children}
    </SpinButton>
  );
}

function StoreForm({
  initial,
  title,
  locations,
  onSave,
  onCancel,
}: {
  initial: StoreFormValues;
  title: string;
  locations: Location[];
  onSave: (v: StoreFormValues, geoDirty: boolean) => void;
  onCancel: () => void;
}) {
  const [v, setV] = useState<StoreFormValues>(initial);
  function up<K extends keyof typeof v>(k: K, val: typeof v[K]) {
    setV({ ...v, [k]: val });
  }
  // 經緯度用字串暫存：綁 number 的話打「25.」會被 Number() 吃掉小數點，
  // 使用者永遠打不完一個座標
  const [latStr, setLatStr] = useState(initial.latitude == null ? "" : String(initial.latitude));
  const [lngStr, setLngStr] = useState(initial.longitude == null ? "" : String(initial.longitude));
  const lat = parseCoord(latStr);
  const lng = parseCoord(lngStr);
  const geoError =
    (latStr.trim() !== "" && lat === null) || (lngStr.trim() !== "" && lng === null)
      ? "經緯度只能是數字"
      : (lat === null) !== (lng === null)
        ? "經度與緯度要一起填或一起留空"
        : null;
  const geoDirty =
    (v.address ?? null) !== (initial.address ?? null) ||
    lat !== (initial.latitude == null ? null : Number(initial.latitude)) ||
    lng !== (initial.longitude == null ? null : Number(initial.longitude));
  function togglePayment(m: PaymentMethod) {
    const cur = new Set(v.allowed_payment_methods ?? []);
    if (cur.has(m)) cur.delete(m);
    else cur.add(m);
    up("allowed_payment_methods", Array.from(cur) as PaymentMethod[]);
  }

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (geoError) return;
        onSave({ ...v, latitude: lat, longitude: lng }, geoDirty);
      }}
      className="space-y-3 border-l-4 border-blue-400 bg-blue-50/40 p-4 dark:bg-blue-950/20"
    >
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold">{title}</h3>
        {v.code.startsWith("LELE-") && (
          <span className="rounded bg-amber-100 px-2 py-0.5 text-[10px] text-amber-700 dark:bg-amber-950 dark:text-amber-300">
            樂樂自動建立
          </span>
        )}
      </div>
      <div className="grid gap-3 sm:grid-cols-4">
        <F label="代碼 *">
          <input
            value={v.code}
            onChange={(e) => up("code", e.target.value)}
            required
            className={inputCls}
          />
        </F>
        <F label="名稱 *">
          <input
            value={v.name}
            onChange={(e) => up("name", e.target.value)}
            required
            className={inputCls}
          />
        </F>
        <F label="對應 location (倉別)">
          <select
            value={v.location_id ?? ""}
            onChange={(e) => up("location_id", e.target.value ? Number(e.target.value) : null)}
            className={inputCls}
          >
            <option value="">— 未設定 —</option>
            {locations.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name} ({l.code})
              </option>
            ))}
          </select>
        </F>
        <F label="取貨窗 (天)">
          <input
            type="number"
            min={1}
            value={v.pickup_window_days}
            onChange={(e) => up("pickup_window_days", Math.max(1, Number(e.target.value) || 1))}
            className={inputCls}
          />
        </F>

        <F label="付款方式" className="sm:col-span-3">
          <div className="flex flex-wrap gap-3 pt-1.5">
            {PAYMENT_OPTIONS.map((m) => (
              <label key={m} className="flex items-center gap-1.5 text-sm">
                <input
                  type="checkbox"
                  checked={(v.allowed_payment_methods ?? []).includes(m)}
                  onChange={() => togglePayment(m)}
                />
                <span>{PAYMENT_LABELS[m]}</span>
              </label>
            ))}
          </div>
        </F>
        <F label="啟用">
          <label className="flex items-center gap-2 pt-1.5 text-sm">
            <input
              type="checkbox"
              checked={v.is_active}
              onChange={(e) => up("is_active", e.target.checked)}
            />
            <span>{v.is_active ? "啟用中" : "停用"}</span>
          </label>
        </F>

        <F label="LINE@ ID" className="sm:col-span-2">
          <input
            value={v.line_oa_basic_id ?? ""}
            onChange={(e) => up("line_oa_basic_id", e.target.value || null)}
            placeholder="@example（留空 = 用租戶預設）"
            className={inputCls}
          />
          <span className="text-[11px] text-zinc-500">
            會員 App 現貨專區「LINE 詢問」會把訊息帶到這個官方帳號
          </span>
        </F>

        <StoreLineOaField storeId={v.id} storeCode={v.code} />

        {/* 地址 / 座標：首頁「門市熱賣地圖」靠這兩個數字定位；沒填的店不會出現在圖上。
            座標可在 Google 地圖上對門市按右鍵，第一行就是「緯度, 經度」，直接貼上。 */}
        <F label="地址" className="sm:col-span-2">
          <input
            value={v.address ?? ""}
            onChange={(e) => up("address", e.target.value || null)}
            placeholder="例：新北市中和區中山路二段 100 號"
            className={inputCls}
          />
        </F>
        <F label="緯度 / 經度（首頁地圖用）" className="sm:col-span-2">
          <div className="flex items-center gap-2">
            <input
              value={latStr}
              onChange={(e) => setLatStr(e.target.value)}
              onPaste={(e) => {
                // Google 地圖右鍵複製的是「25.0330, 121.5654」，整串貼進緯度欄時
                // 順手拆成兩格，不要逼使用者手動剪一半
                const pair = e.clipboardData.getData("text").match(
                  /^\s*(-?\d+(?:\.\d+)?)\s*[,，]\s*(-?\d+(?:\.\d+)?)\s*$/,
                );
                if (!pair) return;
                e.preventDefault();
                setLatStr(pair[1]);
                setLngStr(pair[2]);
              }}
              inputMode="decimal"
              placeholder="25.033"
              className={`${inputCls} w-full`}
            />
            <span className="text-zinc-400">,</span>
            <input
              value={lngStr}
              onChange={(e) => setLngStr(e.target.value)}
              inputMode="decimal"
              placeholder="121.5654"
              className={`${inputCls} w-full`}
            />
          </div>
          <span className={`text-[11px] ${geoError ? "text-red-600 dark:text-red-400" : "text-zinc-500"}`}>
            {geoError ??
              "Google 地圖對門市按右鍵，第一行「25.0330, 121.5654」整串貼到左欄會自動拆開；留空 = 不出現在首頁地圖"}
          </span>
        </F>

        <F label="備註" className="sm:col-span-4">
          <textarea
            value={v.notes ?? ""}
            onChange={(e) => up("notes", e.target.value || null)}
            className={`${inputCls} min-h-16`}
          />
        </F>
      </div>
      <div className="flex items-center gap-2">
        <SpinButton
          type="submit"
          className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm text-white transition-colors hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          儲存
        </SpinButton>
        <SpinButton
          type="button"
          onClick={onCancel}
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm transition-colors hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
        >
          取消
        </SpinButton>
      </div>
    </form>
  );
}

function F({
  label,
  children,
  className = "",
}: {
  label: string;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <label className={`flex flex-col gap-1 text-sm ${className}`}>
      <span className="text-xs text-zinc-500">{label}</span>
      {children}
    </label>
  );
}

// 空字串 → null（＝清除座標）；非數字 → null，並由 geoError 擋下送出
function parseCoord(s: string): number | null {
  const t = s.trim();
  if (t === "") return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";

type MergeTarget = { id: number; code: string; name: string };

// rpc_merge_stores 回傳的 jsonb → 畫面文案
const MERGE_RESULT_LABELS: [string, string][] = [
  ["bindings_moved", "LINE 綁定改掛目標店"],
  ["bindings_deduped", "LINE 綁定去重刪除（兩店都綁過）"],
  ["members_moved", "會員改隸目標店"],
  ["orders_moved", "訂單改掛目標店"],
  ["stock_lines", "庫存移轉 SKU 數"],
  ["stock_qty", "庫存移轉件數"],
];

function MergeStoreDialog({
  source,
  onClose,
  onDone,
}: {
  source: { id: number; code: string; name: string };
  onClose: () => void;
  onDone: () => void | Promise<void>;
}) {
  const [targets, setTargets] = useState<MergeTarget[]>([]);
  const [targetId, setTargetId] = useState<number | "">("");
  const [confirmText, setConfirmText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<Record<string, unknown> | null>(null);

  useEffect(() => {
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("stores")
        .select("id, code, name")
        .eq("is_active", true)
        .is("deleted_at", null)
        .neq("id", source.id)
        .order("name");
      if (err) setError(err.message);
      else setTargets((data ?? []) as MergeTarget[]);
    })();
  }, [source.id]);

  async function run() {
    if (targetId === "") return;
    setBusy(true);
    setError(null);
    try {
      const { data, error: err } = await getSupabase().rpc("rpc_merge_stores", {
        p_source_store_id: source.id,
        p_target_store_id: targetId,
      });
      if (err) throw err;
      setResult((data ?? {}) as Record<string, unknown>);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  const target = targets.find((t) => t.id === targetId);
  const canRun = targetId !== "" && confirmText.trim() === source.code && !busy;
  const pendingAid = Number(result?.aid_listings_open ?? 0);
  const pendingStaff = Number(result?.staff_assignments_pending ?? 0);
  const negLeft = Number(result?.negative_balances_left ?? 0);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-xl dark:bg-zinc-900">
        {result === null ? (
          <>
            <h2 className="text-base font-semibold">
              合併門市：{source.name}（{source.code}）
            </h2>
            <p className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">
              會把 <b>{source.name}</b> 的 LINE 綁定（兩店重複的自動去重）、會員、
              全部訂單改掛到目標店，店倉庫存開正式調撥單（MG-）整批移轉並自動收貨，
              完成後停用來源店。<b>此動作無法自動復原。</b>
            </p>
            <p className="mt-1 text-xs text-zinc-500">
              來源店若還有在途入庫調撥單或進行中補貨申請，後端會拒絕 —— 先收完或取消再合併。
            </p>

            <label className="mt-4 block text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">目標店（承接方，須為啟用中門市）</span>
              <select
                value={targetId}
                onChange={(e) => setTargetId(e.target.value === "" ? "" : Number(e.target.value))}
                className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 text-sm dark:border-zinc-700 dark:bg-zinc-950"
              >
                <option value="">— 選擇目標店 —</option>
                {targets.map((t) => (
                  <option key={t.id} value={t.id}>
                    {t.name}（{t.code}）
                  </option>
                ))}
              </select>
            </label>

            <label className="mt-3 block text-sm">
              <span className="text-zinc-600 dark:text-zinc-400">
                輸入來源店代碼 <b className="font-mono">{source.code}</b> 以確認
              </span>
              <input
                value={confirmText}
                onChange={(e) => setConfirmText(e.target.value)}
                placeholder={source.code}
                className="mt-1 w-full rounded-md border border-zinc-300 bg-white px-2 py-1.5 font-mono text-sm dark:border-zinc-700 dark:bg-zinc-950"
              />
            </label>

            {error && (
              <div className="mt-3 rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
                {error}
              </div>
            )}

            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={onClose}
                disabled={busy}
                className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm dark:border-zinc-700"
              >
                取消
              </button>
              <SpinButton
                onClick={run}
                disabled={!canRun}
                className="rounded-md bg-purple-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-purple-700 disabled:opacity-40"
              >
                {busy ? "合併中…" : `合併到 ${target ? target.name : "…"}`}
              </SpinButton>
            </div>
          </>
        ) : (
          <>
            <h2 className="text-base font-semibold">
              ✅ 合併完成：{String(result.source_store)} → {String(result.target_store)}
            </h2>
            <ul className="mt-3 space-y-1 text-sm">
              {MERGE_RESULT_LABELS.map(([k, label]) => (
                <li key={k} className="flex justify-between gap-4">
                  <span className="text-zinc-600 dark:text-zinc-400">{label}</span>
                  <span className="font-mono">{String(result[k] ?? 0)}</span>
                </li>
              ))}
              {result.stock_transfer_no ? (
                <li className="flex justify-between gap-4">
                  <span className="text-zinc-600 dark:text-zinc-400">庫存調撥單</span>
                  <span className="font-mono text-xs">{String(result.stock_transfer_no)}</span>
                </li>
              ) : null}
            </ul>
            {(pendingAid > 0 || pendingStaff > 0 || negLeft > 0) && (
              <div className="mt-3 rounded-md border border-amber-200 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300">
                需要人工收尾：
                {pendingAid > 0 && <div>・互助板還有 {pendingAid} 則進行中釋出掛在來源店，請手動結掉或改店。</div>}
                {pendingStaff > 0 && <div>・{pendingStaff} 個員工帳號的分店指派（app_metadata.stores）還指著來源店名，請到員工管理更新。</div>}
                {negLeft > 0 && <div>・來源店倉還有 {negLeft} 筆負庫存留在原地，請盤點處理。</div>}
              </div>
            )}
            <div className="mt-4 flex justify-end">
              <SpinButton
                onClick={onDone}
                className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white dark:bg-zinc-50 dark:text-zinc-900"
              >
                完成
              </SpinButton>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
