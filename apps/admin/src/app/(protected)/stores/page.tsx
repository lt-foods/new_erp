"use client";

import { useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { Table, THead, TBody, Tr, Th, Td, EmptyRow, LoadingRow } from "@/components/DataTable";

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
      .select("id, code, name, location_id, pickup_window_days, allowed_payment_methods, is_active, notes, line_oa_basic_id, updated_at, deleted_at")
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

  async function save(v: StoreFormValues) {
    try {
      const { error: err } = await getSupabase().rpc("rpc_upsert_store", {
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
          onSave={(v) => save({ ...v, id: null })}
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
          <Th>對應 location</Th>
          <Th align="right">取貨窗 (天)</Th>
          <Th>付款方式</Th>
          <Th>狀態</Th>
          <Th>更新</Th>
          <Th>{""}</Th>
        </THead>
        <TBody>
          {rows === null ? (
            <LoadingRow colSpan={8} />
          ) : rows.length === 0 ? (
            <EmptyRow colSpan={8}>沒有符合條件的門市</EmptyRow>
          ) : (
            paginated.map((r) =>
              editing?.id === r.id ? (
                <tr key={r.id}>
                  <td colSpan={8} className="p-0">
                    <StoreForm
                      initial={{ ...r, id: r.id }}
                      title="編輯"
                      locations={locations}
                      onCancel={() => setEditing(null)}
                      onSave={(v) => save({ ...v, id: r.id })}
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
                  <Td>{r.name}</Td>
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
  onSave: (v: StoreFormValues) => void;
  onCancel: () => void;
}) {
  const [v, setV] = useState<StoreFormValues>(initial);
  function up<K extends keyof typeof v>(k: K, val: typeof v[K]) {
    setV({ ...v, [k]: val });
  }
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
        onSave(v);
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

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";
