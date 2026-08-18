"use client";

import { useEffect, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { DatePicker } from "@/components/DatePicker";
import SpinButton from "@/components/SpinButton";
import SearchSpinner from "@/components/SearchSpinner";
import { translateRpcError } from "@/lib/rpcError";

// 客人看的店面網址（與 campaigns/quick-control、FbPublishModal 同一個寫法）
const MEMBER_APP_URL = (process.env.NEXT_PUBLIC_MEMBER_APP_URL ?? "https://new-erp-admin.vercel.app").replace(/\/$/, "");

// 漂漂館品牌以 code 反查 id（⛔ 不寫死任何 brand id / tenant id）
// 建立於 supabase/migrations/20260818000100_brand_piaopiao_seed.sql
const PIAOPIAO_BRAND_CODE = "PIAOPIAO";

type Candidate = {
  id: number;
  product_name_hint: string | null;
  raw_text: string;
  source_user_id: string | null;
  source_user_name: string | null;
  source_channel: string | null;
  system_status: string;
  owner_action: string;
  scheduled_open_at: string | null;
  scheduled_sort_order: number | null;
  created_at: string;
  adopted_supplier_name: string | null;
  adopted_cost: number | null;
  adopted_sale_price: number | null;
  // v_community_product_candidates 補的欄位（來源 → 品牌，NULL = 尚未對應 = 找貨群）
  source_brand_id: number | null;
  source_brand_code: string | null;
  source_brand_name: string | null;
  // 該候選的商品是否已經有團（非 cancelled）。降級讀本表時一律填 false。
  has_campaign: boolean;
};

// 本表就有的欄位（view 掛掉時的降級查詢用）
const CANDIDATE_COLS =
  "id, product_name_hint, raw_text, source_user_id, source_user_name, source_channel, system_status, owner_action, scheduled_open_at, scheduled_sort_order, created_at, adopted_supplier_name, adopted_cost, adopted_sale_price";
// view 才有的額外欄位
const CANDIDATE_COLS_VIEW =
  `${CANDIDATE_COLS}, source_brand_id, source_brand_code, source_brand_name, has_campaign`;

// 候選池來源清單（rpc_community_channel_summary）
type ChannelRow = {
  source_channel: string;
  candidate_count: number;
  brand_id: number | null;
  brand_code: string | null;
  brand_name: string | null;
};

// 一鍵開團的逐筆結果（成功要留連結、失敗要留原因）
type OpenResult = {
  candidateId: number;
  name: string;
  url?: string;
  campaignNo?: string;
  error?: string;
};

type Tab = "pending" | "collected" | "scheduled" | "ignored" | "adopted" | "all";

// 來源維度：與上面的「狀態」分頁正交（漂漂館的候選同樣會有未處理／已排程）
type SourceFilter = "all" | "unassigned" | "piaopiao";

const TABS: { key: Tab; label: string }[] = [
  { key: "pending", label: "未處理" },
  { key: "collected", label: "已收藏" },
  { key: "scheduled", label: "已排程" },
  { key: "ignored", label: "已忽略" },
  { key: "adopted", label: "已採用" },
  { key: "all", label: "全部" },
];

const SOURCE_FILTERS: { key: SourceFilter; label: string }[] = [
  { key: "all", label: "全部來源" },
  { key: "unassigned", label: "找貨群" },
  { key: "piaopiao", label: "漂漂館" },
];

const ACTION_LABEL: Record<string, string> = {
  none: "未處理",
  collected: "已收藏",
  scheduled: "已排程",
  adopted: "已採用",
  ignored: "已忽略",
};

const ACTION_COLOR: Record<string, string> = {
  none: "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400",
  collected: "bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300",
  scheduled: "bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300",
  adopted: "bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300",
  ignored: "bg-zinc-200 text-zinc-500 dark:bg-zinc-700 dark:text-zinc-400",
};

export default function CommunityCandidatesPage() {
  const [rows, setRows] = useState<Candidate[] | null>(null);
  const [queryDraft, setQueryDraft] = useState("");
  const [query, setQuery] = useState("");
  const [searching, setSearching] = useState(false);
  const [tab, setTab] = useState<Tab>("pending");
  const [error, setError] = useState<string | null>(null);
  const [scheduling, setScheduling] = useState<number | null>(null);
  const [scheduleDate, setScheduleDate] = useState("");
  const [busy, setBusy] = useState(false);
  const [editingInfo, setEditingInfo] = useState<number | null>(null);
  const [adoptSupplier, setAdoptSupplier] = useState("");
  const [adoptCost, setAdoptCost] = useState("");
  const [adoptSalePrice, setAdoptSalePrice] = useState("");
  const [highlightId, setHighlightId] = useState<number | null>(null);
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [bulkDate, setBulkDate] = useState("");

  // ── 來源維度（與狀態分頁正交）────────────────────────────────────────────
  const [sourceFilter, setSourceFilter] = useState<SourceFilter>("all");
  const [piaopiaoBrandId, setPiaopiaoBrandId] = useState<number | null>(null);
  const [channels, setChannels] = useState<ChannelRow[] | null>(null);
  const [showChannels, setShowChannels] = useState(false);
  // true ＝ 讀不到 v_community_product_candidates（DB 更新還沒套）→ 全頁降級成改動前的樣子
  const [viewMissing, setViewMissing] = useState(false);

  // ── 一鍵建商品＋開團 ─────────────────────────────────────────────────────
  const [openPanel, setOpenPanel] = useState(false);
  const [openEndAt, setOpenEndAt] = useState("");            // ⛔ 刻意留空：不自己編預設收單時間
  const [openPickupDeadline, setOpenPickupDeadline] = useState(""); // ⛔ 同上
  const [openProgress, setOpenProgress] = useState<string | null>(null);
  // ⚠️ 結果清單「不放在」rows 裡，也不在 reload / 換分頁時清掉 —— 老闆還沒把連結複製走
  const [openResults, setOpenResults] = useState<OpenResult[] | null>(null);

  const highlightRowRef = useRef<HTMLElement | null>(null);

  // ⚠️ 兩顆批次鈕的可選條件「分開判斷」，不可以共用一個 isSelectable：
  //   「批次排日期」只負責建商品 → 已排程的沒有意義，維持排除。
  //   「建商品＋開團」→ 老闆很可能先按了「批次排日期」把商品建起來（候選變成
  //     scheduled），之後才決定要開團。共用同一個條件的話那些候選在這一頁
  //     永遠選不到、也看不出為什麼，只能繞去商品編輯頁手動開團 ——
  //     而那條舊路徑沒有本 PR 新加的「售價 > 0」守衛，等於繞過安全網。
  //   所以這裡只排除「已經有團的」。
  const canSchedule = (r: Candidate) => r.owner_action !== "scheduled";
  // viewMissing（DB 還沒套 migration）時一律不可開團 —— 讓降級後的行為與改動前完全一致
  const canOpen = (r: Candidate) => !viewMissing && !r.has_campaign;
  const isSelectable = (r: Candidate) => canSchedule(r) || canOpen(r);

  const selectHint = (r: Candidate) => {
    if (canSchedule(r) && canOpen(r)) return "選取";
    if (canOpen(r)) return "已排程，仍可補開團";
    if (canSchedule(r)) return "選取（已開過團，不能再開）";
    return "已排程且已開團";
  };

  // 還沒被歸類的來源數（＝老闆的待辦：新群第一次進來、或機器人這次帶的是 groupId）
  const unmappedChannels = (channels ?? []).filter((c) => c.brand_id === null).length;

  const toggleOne = (id: number) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const clearSelected = () => setSelected(new Set());

  useEffect(() => {
    const id = Number(new URLSearchParams(window.location.search).get("highlight"));
    if (Number.isFinite(id) && id > 0) {
      setHighlightId(id);
      setTab("all");
    }
  }, []);

  useEffect(() => {
    // 打字內容與已送出的 query 不同 → 有一筆 reload 待觸發，轉圈圈到 reload 結束才停
    if (queryDraft !== query) setSearching(true);
    const t = setTimeout(() => setQuery(queryDraft), 300);
    return () => clearTimeout(t);
  }, [queryDraft, query]);

  useEffect(() => {
    if (highlightId && highlightRowRef.current) {
      highlightRowRef.current.scrollIntoView({ behavior: "smooth", block: "center" });
    }
  }, [highlightId, rows]);

  // 漂漂館品牌 id（以 code 反查，⛔ 不寫死 id）
  const loadPiaopiaoBrand = async () => {
    const { data } = await getSupabase()
      .from("brands")
      .select("id")
      .eq("code", PIAOPIAO_BRAND_CODE)
      .maybeSingle();
    setPiaopiaoBrandId(data ? Number((data as { id: number }).id) : null);
  };

  // 來源清單（哪些 source_channel 進來過、各自對到哪個品牌）
  const loadChannels = async () => {
    const { data, error: err } = await getSupabase().rpc("rpc_community_channel_summary");
    if (!err) setChannels((data as ChannelRow[]) ?? []);
  };

  useEffect(() => {
    // setState 放在 async callback 裡而不是 effect 本體（react-hooks/set-state-in-effect），
    // 順便用 alive 旗標避免元件卸載後才回來的 setState。
    let alive = true;
    (async () => {
      if (!alive) return;
      await loadPiaopiaoBrand();
      if (!alive) return;
      await loadChannels();
    })();
    return () => { alive = false; };
  }, []);

  // 依 tab / 搜尋字串組查詢；useView=false 時退回本表、不帶來源欄位也不做來源篩選
  const buildCandidateQuery = (useView: boolean) => {
    let q = getSupabase()
      .from(useView ? "v_community_product_candidates" : "community_product_candidates")
      .select(useView ? CANDIDATE_COLS_VIEW : CANDIDATE_COLS)
      .order("created_at", { ascending: false })
      .limit(200);

    if (tab === "pending") q = q.eq("owner_action", "none");
    else if (tab === "collected") q = q.eq("owner_action", "collected");
    else if (tab === "scheduled") q = q.eq("owner_action", "scheduled");
    else if (tab === "ignored") q = q.eq("owner_action", "ignored");
    else if (tab === "adopted") q = q.eq("owner_action", "adopted");

    // 來源維度：與上面的狀態分頁互不影響（本表沒有這些欄位，降級時整段跳過）
    if (useView && sourceFilter === "unassigned") {
      // 尚未對應到任何品牌 —— 包含既有 source_channel 為 NULL 的舊資料
      q = q.is("source_brand_id", null);
    } else if (useView && sourceFilter === "piaopiao" && piaopiaoBrandId !== null) {
      q = q.eq("source_brand_id", piaopiaoBrandId);
    }

    if (query.trim()) {
      const safe = query.replace(/[%,()]/g, " ").trim();
      q = q.or(`product_name_hint.ilike.%${safe}%,raw_text.ilike.%${safe}%`);
    }
    return q;
  };

  const reload = async () => {
    try {
      // 「漂漂館」篩選需要品牌 id，沒有就明講（⛔ 不要靜默退回全部讓老闆以為沒資料）
      if (!viewMissing && sourceFilter === "piaopiao" && piaopiaoBrandId === null) {
        setRows([]);
        setError("找不到「漂漂館」品牌，資料庫更新可能還沒套用（20260818000100）");
        return;
      }

      // ⚠️⚠️ 降級：DB 更新還沒套（或 view 讀不到）時，⛔ 不可以整頁掛掉。
      //   既有 6 個分頁與 2495 筆舊資料要照常顯示，只有「來源分線 / 一鍵開團」停用。
      //   判定法刻意不去猜 PostgREST 的錯誤碼：view 讀失敗就改讀本表，
      //   本表讀得到 → 確定是 view 的問題 → 降級；本表也讀不到 → 回報真正的錯誤。
      if (!viewMissing) {
        const { data, error: err } = await buildCandidateQuery(true);
        if (!err) {
          setError(null);
          setRows((data as unknown as Candidate[]) ?? []);
          return;
        }
      }

      const { data: baseData, error: baseErr } = await buildCandidateQuery(false);
      if (baseErr) {
        setError(baseErr.message);
        return;
      }
      if (!viewMissing) setViewMissing(true);
      setError(null);
      // 本表沒有 view 的欄位 → 補成「未對應品牌 / 未開團」，語意等同改動前
      setRows(
        ((baseData as unknown as Candidate[]) ?? []).map((r) => ({
          ...r,
          source_brand_id: null,
          source_brand_code: null,
          source_brand_name: null,
          has_campaign: false,
        }))
      );
    } finally {
      setSearching(false);
    }
  };

  useEffect(() => {
    reload();
    clearSelected();
    // ⛔ 這裡刻意不動 openResults：換分頁不可以把還沒複製走的連結清掉
  }, [query, tab, sourceFilter, piaopiaoBrandId]);

  const patch = async (id: number, updates: Record<string, unknown>) => {
    setBusy(true);
    try {
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({ ...updates, updated_at: new Date().toISOString() })
        .eq("id", id);
      if (err) throw err;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleCollect = (id: number) =>
    patch(id, { owner_action: "collected", scheduled_open_at: null, scheduled_sort_order: null });
  const handleIgnore = (id: number) =>
    patch(id, { owner_action: "ignored", scheduled_open_at: null, scheduled_sort_order: null });
  const handleRestore = (id: number) =>
    patch(id, { owner_action: "none", scheduled_open_at: null, scheduled_sort_order: null });

  const nextSortOrderForDay = async (date: string): Promise<number> => {
    const { data, error: err } = await getSupabase()
      .from("community_product_candidates")
      .select("scheduled_sort_order")
      .eq("scheduled_open_at", date)
      .not("scheduled_sort_order", "is", null)
      .order("scheduled_sort_order", { ascending: false })
      .limit(1);
    if (err) throw err;
    const max = (data?.[0]?.scheduled_sort_order as number | null) ?? 0;
    return max + 1;
  };

  // ⚠️ 只有真的要標品牌時才帶 p_brand_id。
  //   DB 更新還沒套時線上仍是 3 參數版的 rpc_schedule_candidate，多傳一個參數
  //   PostgREST 會直接說找不到函式 —— 那會把「批次排日期」這顆既有按鈕一起弄壞。
  const scheduleArgs = (id: number, dateStr: string, productName: string, brandId: number | null) => {
    const args: Record<string, unknown> = {
      p_candidate_id: id,
      p_scheduled_date: dateStr,
      p_product_name: productName,
    };
    if (brandId !== null && brandId !== undefined) args.p_brand_id = brandId;
    return args;
  };

  const deriveProductName = (row: Candidate): string => {
    const hint = (row.product_name_hint ?? "").trim();
    if (hint) return hint.slice(0, 60);
    const raw = (row.raw_text ?? "").trim().replace(/\s+/g, " ");
    if (raw) return raw.slice(0, 30);
    return `候選 #${row.id}`;
  };

  const scheduleAt = async (id: number, dateStr: string) => {
    const row = rows?.find((r) => r.id === id);
    if (!row) {
      setError("找不到該候選資料，請重新整理後再試");
      return;
    }
    const productName = deriveProductName(row);

    setBusy(true);
    try {
      const sb = getSupabase();
      // 呼叫 rpc_schedule_candidate：建 draft product + sku + 標 candidate scheduled
      // （不再自動建開團；開團改由商品編輯頁「建立新開團」按鈕觸發）
      // 來源已對應到品牌就一起標上（沒對應＝不帶參數＝與改動前行為相同）
      const { error: rpcErr } = await sb.rpc(
        "rpc_schedule_candidate",
        scheduleArgs(id, dateStr, productName, row.source_brand_id)
      );
      if (rpcErr) throw rpcErr;

      // RPC 不負責 scheduled_sort_order（行事曆排序遺留欄位），補一下
      const nextOrder = await nextSortOrderForDay(dateStr);
      await sb
        .from("community_product_candidates")
        .update({ scheduled_sort_order: nextOrder })
        .eq("id", id);

      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleSchedule = async (id: number) => {
    if (!scheduleDate) return;
    await scheduleAt(id, scheduleDate);
    setScheduling(null);
    setScheduleDate("");
  };

  const formatLocalDate = (d: Date): string => {
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const day = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${day}`;
  };

  const localDateStr = (daysFromNow: number): string => {
    const d = new Date();
    d.setDate(d.getDate() + daysFromNow);
    return formatLocalDate(d);
  };

  const nextWeekMonday = (): string => {
    const d = new Date();
    const day = d.getDay();
    const daysUntil = day === 0 ? 1 : 8 - day;
    d.setDate(d.getDate() + daysUntil);
    return formatLocalDate(d);
  };

  const handleQuickSchedule = async (id: number, dateStr: string) => {
    await scheduleAt(id, dateStr);
    setScheduling(null);
    setScheduleDate("");
  };

  const handleBulkSchedule = async (dateStr: string) => {
    if (!dateStr || selected.size === 0) return;
    const ids = [...selected].filter((id) => {
      const r = rows?.find((x) => x.id === id);
      return r && canSchedule(r);
    });
    const skipped = selected.size - ids.length;
    if (ids.length === 0) {
      setError("選取的候選都已經排程過了，這顆鈕沒有可做的事（要開團請按「建商品 ＋ 開團」）");
      return;
    }
    setBusy(true);
    setError(skipped > 0 ? `已排程的 ${skipped} 筆會略過，只處理其餘 ${ids.length} 筆` : null);
    try {
      const sb = getSupabase();
      // 順序執行：每一筆建 product/sku 再補 sort_order，避免 sort 撞號（不建開團）
      for (const id of ids) {
        const row = rows?.find((r) => r.id === id);
        if (!row) continue;
        const productName = deriveProductName(row);
        const { error: rpcErr } = await sb.rpc(
          "rpc_schedule_candidate",
          scheduleArgs(id, dateStr, productName, row.source_brand_id)
        );
        if (rpcErr) throw rpcErr;
        const nextOrder = await nextSortOrderForDay(dateStr);
        await sb
          .from("community_product_candidates")
          .update({ scheduled_sort_order: nextOrder })
          .eq("id", id);
      }
      clearSelected();
      setBulkDate("");
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  // ── 來源歸屬：把某個 source_channel 指到某個品牌（brandId 傳 null ＝ 取消）──
  const setChannelBrand = async (channel: string, brandId: number | null) => {
    setBusy(true);
    try {
      const { error: err } = await getSupabase().rpc("rpc_set_community_channel_brand", {
        p_source_channel: channel,
        p_brand_id: brandId,
      });
      if (err) throw err;
      setError(null);
      await loadChannels();
      await reload();
    } catch (e) {
      setError(translateRpcError(e));
    } finally {
      setBusy(false);
    }
  };

  // ── 一鍵：建商品 ＋ 開團 ＋ 拿連結 ───────────────────────────────────────
  // 每一筆各自是一個 RPC ＝ 一個交易：失敗的整筆回滾、成功的照樣留著連結。
  const handleBulkOpenCampaign = async () => {
    if (busy || selected.size === 0) return;
    // 降級模式下 rpc_open_campaign_from_candidate 根本不存在，不要送出去換一個看不懂的錯
    if (viewMissing) {
      setError("「一鍵建商品＋開團」尚未啟用（資料庫更新還沒套用）");
      return;
    }

    // ⛔ 收單時間／取貨截止日一律由老闆指定，這裡不編任何預設值
    if (!openEndAt) { setError("請先指定收單時間"); return; }
    const endDate = new Date(openEndAt);
    if (Number.isNaN(endDate.getTime())) { setError("收單時間格式不正確"); return; }
    if (endDate.getTime() <= Date.now()) { setError("收單時間必須晚於現在"); return; }
    if (!openPickupDeadline) { setError("請先指定取貨截止日"); return; }
    if (openPickupDeadline < formatLocalDate(endDate)) { setError("取貨截止日不可早於收單日"); return; }

    // ⚠️ 這裡用 canOpen 不是 canSchedule：「已排程但還沒開團」的候選要能補開團
    const ids = [...selected].filter((id) => {
      const r = rows?.find((x) => x.id === id);
      return r && canOpen(r);
    });
    const skipped = selected.size - ids.length;
    if (ids.length === 0) {
      setError("選取的候選都已經開過團了，不會重複開");
      return;
    }

    setBusy(true);
    setError(skipped > 0 ? `已開過團的 ${skipped} 筆會略過，只處理其餘 ${ids.length} 筆` : null);
    setOpenResults(null);

    // 團是「現在」就開（RPC 內 status='open'、start_at=NOW()），
    // 所以候選的「預計開團日」記今天才不會跟事實對不起來。
    const scheduledDate = formatLocalDate(new Date());
    const results: OpenResult[] = [];

    try {
      const sb = getSupabase();
      for (let i = 0; i < ids.length; i++) {
        const id = ids[i];
        const row = rows?.find((r) => r.id === id);
        if (!row) continue;
        const name = deriveProductName(row);
        setOpenProgress(`處理中 ${i + 1} / ${ids.length}：${name}`);
        try {
          const { data, error: rpcErr } = await sb.rpc("rpc_open_campaign_from_candidate", {
            p_candidate_id: id,
            p_scheduled_date: scheduledDate,
            p_product_name: name,
            p_end_at: endDate.toISOString(),
            p_pickup_deadline: openPickupDeadline,
          });
          if (rpcErr) throw rpcErr;
          const out = (data ?? {}) as { campaign_id?: number; campaign_no?: string };
          if (!out.campaign_id) throw new Error("開團沒有回傳團號，請重新整理確認");
          results.push({
            candidateId: id,
            name,
            campaignNo: out.campaign_no,
            url: `${MEMBER_APP_URL}/shop/c/${out.campaign_id}`,
          });
          // 行事曆排序欄位（與既有批次排程同一個作法）。純呈現用，失敗不影響已拿到的連結。
          try {
            const nextOrder = await nextSortOrderForDay(scheduledDate);
            await sb
              .from("community_product_candidates")
              .update({ scheduled_sort_order: nextOrder })
              .eq("id", id);
          } catch { /* 排序失敗不擋，團已經建好了 */ }
        } catch (e) {
          // ⛔ 不 throw：一筆失敗不可以讓後面的都不跑、也不可以讓前面的連結消失
          results.push({ candidateId: id, name, error: translateRpcError(e) });
        }
        // ⛔ 迴圈中刻意不 reload（計畫 §B-4 第 3 點）
      }

      // ⚠️ 先把結果放進 state，再做任何可能失敗的收尾（reload 失敗也不可以吃掉連結）
      setOpenResults(results);
      const failed = results.filter((r) => r.error).length;
      if (failed > 0) {
        setError(`共 ${results.length} 筆：成功 ${results.length - failed} 筆、失敗 ${failed} 筆（失敗原因見下方清單，成功的連結照樣可以複製）`);
      }
      clearSelected();
      setOpenPanel(false);
      try {
        await reload(); // 全部跑完才 reload 這一次
      } catch {
        /* 清單刷新失敗不影響上面已經產生的連結，老闆可自行按「重新整理」 */
      }
    } finally {
      setBusy(false);
      setOpenProgress(null);
    }
  };

  const copyAllLinks = async () => {
    const text = (openResults ?? [])
      .filter((r) => r.url)
      .map((r) => `${r.name}\n${r.url}`)
      .join("\n\n");
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      setError(null);
      setOpenProgress("已複製全部連結");
      setTimeout(() => setOpenProgress(null), 2000);
    } catch {
      setError("瀏覽器不允許自動複製，請手動長按選取下面的網址");
    }
  };

  const extractPrice = (text: string): string => {
    const patterns = [
      /\$(\d+(?:\.\d+)?)/,
      /(\d+(?:\.\d+)?)元/,
      /售價\s*(\d+(?:\.\d+)?)/,
      /特價\s*(\d+(?:\.\d+)?)/,
      /一組\s*(\d+(?:\.\d+)?)/,
    ];
    for (const p of patterns) {
      const m = text.match(p);
      if (m) return m[1];
    }
    return "";
  };

  const handleFillSubmit = async (id: number) => {
    setBusy(true);
    try {
      const costVal = adoptCost.trim() ? Number(adoptCost) : null;
      if (costVal !== null && (isNaN(costVal) || costVal < 0)) {
        setError("成本不可為負數");
        return;
      }
      const salePriceVal = adoptSalePrice.trim() ? Number(adoptSalePrice) : null;
      if (salePriceVal !== null && (isNaN(salePriceVal) || salePriceVal < 0)) {
        setError("售價不可為負數");
        return;
      }
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({
          adopted_supplier_name: adoptSupplier.trim() || null,
          adopted_cost: costVal,
          adopted_sale_price: salePriceVal,
          updated_at: new Date().toISOString(),
        })
        .eq("id", id);
      if (err) throw err;
      setEditingInfo(null);
      setAdoptSupplier("");
      setAdoptCost("");
      setAdoptSalePrice("");
      setError(null);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const handleAdopt = async (id: number) => {
    setBusy(true);
    try {
      const { data: { user } } = await getSupabase().auth.getUser();
      if (!user) {
        setError("無法取得登入資訊，請重新整理後再試");
        return;
      }
      const now = new Date().toISOString();
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({
          owner_action: "adopted",
          adopted_at: now,
          adopted_by: user.id,
          updated_at: now,
        })
        .eq("id", id);
      if (err) throw err;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const fmt = (s: string) =>
    new Date(s).toLocaleString("zh-TW", {
      month: "numeric",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });

  // 來源歸到哪一邊。⚠️ 只在「有來源」時顯示：
  //   群名一旦改掉，那個群新進來的候選會變成未分類 → 這裡當場從粉紅變灰，
  //   老闆在清單上就看得到，不用等到「漂漂館分頁怎麼少了幾筆」才發現。
  function renderSourceBucket(r: Candidate) {
    if (!r.source_channel) return null;
    return r.source_brand_id === null ? (
      <span className="mt-0.5 inline-flex rounded-full bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
        找貨群
      </span>
    ) : (
      <span className="mt-0.5 inline-flex rounded-full bg-pink-100 px-1.5 py-0.5 text-[10px] font-medium text-pink-700 dark:bg-pink-900/30 dark:text-pink-300">
        {r.source_brand_name}
      </span>
    );
  }

  function renderActions(r: Candidate) {
    if (editingInfo === r.id) {
      return (
        <div className="flex flex-col gap-2">
          <input
            autoFocus
            placeholder="廠商（選填）"
            value={adoptSupplier}
            onChange={(e) => setAdoptSupplier(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <input
            type="number"
            min={0}
            step="1"
            placeholder="成本（選填）"
            value={adoptCost}
            onChange={(e) => setAdoptCost(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <input
            type="number"
            min={0}
            step="1"
            placeholder="售價（選填）"
            value={adoptSalePrice}
            onChange={(e) => setAdoptSalePrice(e.target.value)}
            className="rounded border border-zinc-300 px-2 py-1 text-xs focus:outline-none dark:border-zinc-700 dark:bg-zinc-900"
          />
          <div className="flex gap-1">
            <SpinButton
              onClick={() => handleFillSubmit(r.id)}
              disabled={busy}
              className="rounded bg-blue-600 px-2 py-0.5 text-xs text-white hover:bg-blue-700 disabled:opacity-50"
            >
              {busy ? "儲存中…" : "儲存"}
            </SpinButton>
            <SpinButton
              onClick={() => { setEditingInfo(null); setAdoptSupplier(""); setAdoptCost(""); setAdoptSalePrice(""); }}
              disabled={busy}
              className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
            >
              取消
            </SpinButton>
          </div>
        </div>
      );
    }
    if (scheduling === r.id) {
      return (
        <div className="flex flex-col gap-1.5">
          <div className="flex flex-wrap gap-1">
            {[
              { label: "明天", date: localDateStr(1) },
              { label: "後天", date: localDateStr(2) },
              { label: "下週一", date: nextWeekMonday() },
            ].map(({ label, date }) => (
              <SpinButton
                key={label}
                onClick={() => handleQuickSchedule(r.id, date)}
                disabled={busy}
                className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
              >
                {label}
              </SpinButton>
            ))}
          </div>
          <div className="flex flex-wrap items-center gap-1">
            <DatePicker
              value={scheduleDate}
              onChange={setScheduleDate}
              className="rounded border border-zinc-300 bg-white px-1.5 py-0.5 text-xs dark:border-zinc-700 dark:bg-zinc-900"
            />
            <SpinButton
              onClick={() => handleSchedule(r.id)}
              disabled={!scheduleDate || busy}
              className="rounded bg-amber-500 px-2 py-0.5 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
            >
              確定
            </SpinButton>
            <SpinButton
              onClick={() => {
                setScheduling(null);
                setScheduleDate("");
              }}
              disabled={busy}
              className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
            >
              取消
            </SpinButton>
          </div>
        </div>
      );
    }
    return (
      <div className="flex flex-wrap items-center gap-1">
        <SpinButton
          onClick={() => {
            setEditingInfo(r.id);
            setAdoptSupplier(r.adopted_supplier_name ?? "");
            setAdoptCost(r.adopted_cost !== null ? String(r.adopted_cost) : "");
            setAdoptSalePrice(r.adopted_sale_price !== null ? String(r.adopted_sale_price) : extractPrice(r.raw_text));
            setScheduling(null);
          }}
          disabled={busy}
          className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-400 disabled:opacity-50"
        >
          {r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null ? "修改資料" : "補資料"}
        </SpinButton>
        {r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => {
              const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
              if (!complete && !window.confirm("廠商、成本、售價尚未完整，確定要採用嗎？")) return;
              handleAdopt(r.id);
            }}
            disabled={busy}
            className="rounded border border-green-400 px-2 py-0.5 text-xs text-green-700 hover:bg-green-50 dark:border-green-700 dark:text-green-400 dark:hover:bg-green-950/30 disabled:opacity-50"
          >
            採用
          </SpinButton>
        )}
        {r.owner_action !== "collected" && r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => handleCollect(r.id)}
            disabled={busy}
            className="rounded border border-blue-300 px-2 py-0.5 text-xs text-blue-600 hover:bg-blue-50 dark:border-blue-800 dark:text-blue-400 disabled:opacity-50"
          >
            收藏
          </SpinButton>
        )}
        {r.owner_action !== "scheduled" && (
          <SpinButton
            onClick={() => {
              setScheduling(r.id);
              setScheduleDate("");
            }}
            disabled={busy}
            className="rounded border border-amber-300 px-2 py-0.5 text-xs text-amber-600 hover:bg-amber-50 dark:border-amber-800 dark:text-amber-400 disabled:opacity-50"
          >
            排日期
          </SpinButton>
        )}
        {r.owner_action !== "ignored" && r.owner_action !== "adopted" && (
          <SpinButton
            onClick={() => handleIgnore(r.id)}
            disabled={busy}
            className="rounded border border-zinc-300 px-2 py-0.5 text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 disabled:opacity-50"
          >
            忽略
          </SpinButton>
        )}
        {(r.owner_action === "collected" ||
          r.owner_action === "scheduled" ||
          r.owner_action === "ignored") && (
          <SpinButton
            onClick={() => handleRestore(r.id)}
            disabled={busy}
            className="rounded border border-zinc-200 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-50 dark:border-zinc-800 disabled:opacity-50"
          >
            還原
          </SpinButton>
        )}
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">選品候選池</h1>
          <p className="mt-0.5 text-sm text-zinc-500">LINE #選品 進來的商品候選</p>
        </div>
        <SpinButton
          onClick={() => reload()}
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          重新整理
        </SpinButton>
      </header>

      {/* Tabs */}
      <div className="flex gap-0 border-b border-zinc-200 dark:border-zinc-800">
        {TABS.map(({ key, label }) => (
          <SpinButton
            key={key}
            onClick={() => setTab(key)}
            className={
              tab === key
                ? "border-b-2 border-zinc-900 px-4 py-2 text-sm font-medium text-zinc-900 dark:border-zinc-100 dark:text-zinc-100"
                : "px-4 py-2 text-sm text-zinc-500 hover:text-zinc-700 dark:hover:text-zinc-300"
            }
          >
            {label}
          </SpinButton>
        ))}
      </div>

      {/* DB 更新還沒套用時的降級提示：頁面其餘部分（6 個分頁、既有資料、批次排日期）照常運作 */}
      {viewMissing && (
        <div className="rounded-md border border-amber-300 bg-amber-50 p-2.5 text-sm text-amber-800 dark:border-amber-700 dark:bg-amber-950/40 dark:text-amber-200">
          「漂漂館分線」與「一鍵建商品＋開團」尚未啟用（資料庫更新還沒套用）。
          <span className="text-amber-700 dark:text-amber-300">
            　候選池的其他功能一切正常，可以照常使用。
          </span>
        </div>
      )}

      {/* 來源切換（與上面的狀態分頁正交：漂漂館的候選一樣會有未處理／已排程） */}
      {!viewMissing && (
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs text-zinc-500 dark:text-zinc-400">來源</span>
        {SOURCE_FILTERS.map(({ key, label }) => (
          <SpinButton
            key={key}
            onClick={() => setSourceFilter(key)}
            className={
              sourceFilter === key
                ? "min-h-[36px] rounded-full bg-zinc-900 px-3 text-sm font-medium text-white dark:bg-zinc-100 dark:text-zinc-900"
                : "min-h-[36px] rounded-full border border-zinc-300 px-3 text-sm text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
            }
          >
            {label}
          </SpinButton>
        ))}
        <SpinButton
          onClick={() => setShowChannels((v) => !v)}
          className="ml-auto min-h-[36px] rounded-md border border-zinc-300 px-3 text-sm text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          {showChannels ? "收起來源設定" : "來源設定"}
          {unmappedChannels > 0 && (
            <span className="ml-1.5 inline-flex rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/40 dark:text-amber-300">
              {unmappedChannels} 個未分類
            </span>
          )}
        </SpinButton>
      </div>
      )}

      {/* 來源設定：哪個 LINE 來源算漂漂館
          ⚠️ Bot 拿不到群名時會改帶 groupId（而且有 10 分鐘負快取），
             所以同一個群可能以兩個不同字串出現 —— 兩個都設一次就會歸到同一邊。 */}
      {!viewMissing && showChannels && (
        <div className="rounded-md border border-zinc-200 p-3 text-sm dark:border-zinc-800">
          <p className="mb-2 text-xs text-zinc-500 dark:text-zinc-400">
            候選是從哪個 LINE 來源進來的。把屬於漂漂館的來源標起來，上面的「漂漂館」才篩得到、
            一鍵開團也才會自動標品牌。
            <br />
            ⚠️ 機器人抓不到群組名稱時會改用群組 ID（C 開頭那串）記錄，同一個群可能出現兩個名字，
            <strong>兩個都要標</strong>。沒標的一律算「找貨群」，不會被誤標成漂漂館。
          </p>
          {channels === null ? (
            <div className="text-xs text-zinc-400">載入中…</div>
          ) : channels.length === 0 ? (
            <div className="text-xs text-zinc-400">
              目前沒有任何帶來源的候選（既有資料的來源欄都是空的，全部算找貨群）。
            </div>
          ) : (
            <div className="space-y-1.5">
              {channels.map((c) => (
                <div
                  key={c.source_channel}
                  className="flex flex-wrap items-center gap-2 rounded border border-zinc-100 px-2 py-1.5 dark:border-zinc-800"
                >
                  <span className="break-all font-mono text-xs">{c.source_channel}</span>
                  <span className="text-xs text-zinc-400">{c.candidate_count} 筆</span>
                  {c.brand_id === null ? (
                    <span className="inline-flex rounded-full bg-zinc-100 px-1.5 py-0.5 text-[10px] text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
                      找貨群（未分類）
                    </span>
                  ) : (
                    <span className="inline-flex rounded-full bg-pink-100 px-1.5 py-0.5 text-[10px] font-medium text-pink-700 dark:bg-pink-900/30 dark:text-pink-300">
                      {c.brand_name}
                    </span>
                  )}
                  <div className="ml-auto flex gap-1">
                    {piaopiaoBrandId !== null && c.brand_id !== piaopiaoBrandId && (
                      <SpinButton
                        onClick={() => setChannelBrand(c.source_channel, piaopiaoBrandId)}
                        disabled={busy}
                        className="min-h-[36px] rounded border border-pink-300 px-2.5 text-xs text-pink-700 hover:bg-pink-50 disabled:opacity-50 dark:border-pink-800 dark:text-pink-300 dark:hover:bg-pink-950/30"
                      >
                        標成漂漂館
                      </SpinButton>
                    )}
                    {c.brand_id !== null && (
                      <SpinButton
                        onClick={() => setChannelBrand(c.source_channel, null)}
                        disabled={busy}
                        className="min-h-[36px] rounded border border-zinc-300 px-2.5 text-xs text-zinc-500 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700"
                      >
                        取消
                      </SpinButton>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
          {piaopiaoBrandId === null && (
            <p className="mt-2 text-xs text-red-600 dark:text-red-400">
              找不到「漂漂館」品牌 —— 資料庫 migration（20260818000100）可能還沒套用。
            </p>
          )}
        </div>
      )}

      {/* Search */}
      <div className="flex gap-2">
        <div className="relative flex-1">
          <input
            className="w-full rounded-md border border-zinc-300 px-3 py-1.5 pr-8 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100"
            placeholder="搜尋商品名稱或文案…"
            value={queryDraft}
            onChange={(e) => setQueryDraft(e.target.value)}
          />
          <SearchSpinner active={searching} />
        </div>
        {queryDraft && (
          <SpinButton
            onClick={() => setQueryDraft("")}
            className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
          >
            清除
          </SpinButton>
        )}
      </div>

      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {/* 批次排日期工具列 */}
      {selected.size > 0 && (
        <div className="sticky top-0 z-10 flex flex-wrap items-center gap-2 rounded-md border border-amber-300 bg-amber-50 p-2.5 text-sm dark:border-amber-700 dark:bg-amber-950/40">
          <span className="font-medium text-amber-800 dark:text-amber-200">
            已選 {selected.size} 筆
          </span>
          <div className="flex flex-wrap items-center gap-1">
            {[
              { label: "明天", date: localDateStr(1) },
              { label: "後天", date: localDateStr(2) },
              { label: "下週一", date: nextWeekMonday() },
            ].map(({ label, date }) => (
              <SpinButton
                key={label}
                onClick={() => handleBulkSchedule(date)}
                disabled={busy}
                className="rounded bg-amber-500 px-2.5 py-1 text-xs text-white hover:bg-amber-600 disabled:opacity-50"
              >
                {label}
              </SpinButton>
            ))}
          </div>
          <DatePicker
            value={bulkDate}
            onChange={setBulkDate}
            className="rounded border border-zinc-300 bg-white px-2 py-1 text-xs dark:border-zinc-700 dark:bg-zinc-900"
          />
          <SpinButton
            onClick={() => handleBulkSchedule(bulkDate)}
            disabled={!bulkDate || busy}
            className="rounded bg-amber-600 px-3 py-1 text-xs font-semibold text-white hover:bg-amber-700 disabled:opacity-50"
          >
            {busy ? "排程中…" : "📅 批次排日期"}
          </SpinButton>
          {/* DB 更新沒套時整顆藏起來：留著會讓老闆按了得到「都已經開過團了」這種誤導訊息 */}
          {!viewMissing && (
            <SpinButton
              onClick={() => setOpenPanel((v) => !v)}
              disabled={busy}
              className="min-h-[44px] rounded-md bg-pink-600 px-3 text-xs font-semibold text-white hover:bg-pink-700 disabled:opacity-50"
            >
              🚀 建商品 ＋ 開團
            </SpinButton>
          )}
          <SpinButton
            onClick={clearSelected}
            disabled={busy}
            className="ml-auto rounded border border-zinc-300 px-2.5 py-1 text-xs text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800 disabled:opacity-50"
          >
            清除選取
          </SpinButton>

          {/* 一鍵開團：收單時間／取貨截止日都要老闆自己填，⛔ 不給預設值 */}
          {openPanel && (
            <div className="w-full rounded-md border border-pink-300 bg-white p-3 dark:border-pink-800 dark:bg-zinc-900">
              <p className="mb-2 text-xs text-zinc-600 dark:text-zinc-300">
                會對已選的 {selected.size} 筆各自做：建商品＋規格＋售價 → 啟用 → 開團 → 產生客人連結。
                <br />
                來源已標成漂漂館的，商品品牌會自動標上；其餘不標。
                <span className="ml-1 text-zinc-400">（候選的「預計開團日」會記成今天，因為團現在就開）</span>
              </p>
              <div className="flex flex-wrap items-end gap-3">
                <label className="flex flex-col gap-1 text-xs">
                  <span className="text-zinc-600 dark:text-zinc-400">
                    收單時間 <span className="text-red-500">*</span>
                  </span>
                  <input
                    type="datetime-local"
                    value={openEndAt}
                    onChange={(e) => setOpenEndAt(e.target.value)}
                    className="min-h-[44px] rounded-md border border-zinc-300 bg-white px-2 text-base dark:border-zinc-700 dark:bg-zinc-900"
                  />
                </label>
                <label className="flex flex-col gap-1 text-xs">
                  <span className="text-zinc-600 dark:text-zinc-400">
                    取貨截止日 <span className="text-red-500">*</span>
                  </span>
                  <DatePicker
                    value={openPickupDeadline}
                    onChange={setOpenPickupDeadline}
                    className="min-h-[44px] rounded-md border border-zinc-300 bg-white px-2 text-base dark:border-zinc-700 dark:bg-zinc-900"
                  />
                </label>
                <SpinButton
                  onClick={handleBulkOpenCampaign}
                  disabled={busy || !openEndAt || !openPickupDeadline}
                  className="min-h-[44px] rounded-md bg-pink-600 px-4 text-sm font-semibold text-white hover:bg-pink-700 disabled:opacity-40"
                >
                  {busy ? "開團中…" : `確定開團（${selected.size} 筆）`}
                </SpinButton>
                <SpinButton
                  onClick={() => setOpenPanel(false)}
                  disabled={busy}
                  className="min-h-[44px] rounded-md border border-zinc-300 px-3 text-sm text-zinc-600 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:text-zinc-300"
                >
                  取消
                </SpinButton>
              </div>
              {(!openEndAt || !openPickupDeadline) && (
                <p className="mt-2 text-xs text-amber-700 dark:text-amber-400">
                  收單時間與取貨截止日都填好才能開團（系統不會替你猜）。
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {/* 進度 */}
      {openProgress && (
        <div className="rounded-md bg-zinc-100 p-2 text-sm text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
          {openProgress}
        </div>
      )}

      {/* 開團結果：⛔ 這一區不會因為 reload / 換分頁被清掉，要老闆自己按「關閉」 */}
      {openResults && openResults.length > 0 && (
        <div className="rounded-md border border-pink-300 bg-pink-50/60 p-3 dark:border-pink-800 dark:bg-pink-950/20">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <span className="text-sm font-semibold text-pink-900 dark:text-pink-200">
              開團結果：成功 {openResults.filter((r) => r.url).length} 筆
              {openResults.some((r) => r.error) && `、失敗 ${openResults.filter((r) => r.error).length} 筆`}
            </span>
            <SpinButton
              onClick={copyAllLinks}
              disabled={!openResults.some((r) => r.url)}
              className="min-h-[36px] rounded-md bg-pink-600 px-3 text-xs font-semibold text-white hover:bg-pink-700 disabled:opacity-40"
            >
              複製全部連結
            </SpinButton>
            <SpinButton
              onClick={() => setOpenResults(null)}
              className="ml-auto min-h-[36px] rounded-md border border-zinc-300 px-3 text-xs text-zinc-600 hover:bg-white dark:border-zinc-700 dark:text-zinc-300"
            >
              關閉
            </SpinButton>
          </div>
          <ul className="space-y-1.5">
            {openResults.map((r) => (
              <li key={r.candidateId} className="rounded border border-zinc-200 bg-white p-2 text-xs dark:border-zinc-800 dark:bg-zinc-900">
                <div className="font-medium">
                  {r.error ? "❌ " : "✅ "}
                  {r.name}
                  {r.campaignNo && <span className="ml-1.5 text-zinc-400">{r.campaignNo}</span>}
                </div>
                {r.url && (
                  <a
                    href={r.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="mt-0.5 block break-all text-blue-600 underline dark:text-blue-400"
                  >
                    {r.url}
                  </a>
                )}
                {r.error && <div className="mt-0.5 text-red-600 dark:text-red-400">{r.error}</div>}
              </li>
            ))}
          </ul>
        </div>
      )}

      {rows === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : rows.length === 0 ? (
        <div className="rounded-lg border border-zinc-200 p-8 text-center text-sm text-zinc-400 dark:border-zinc-800">
          沒有符合的資料
        </div>
      ) : (
        <>
        <div className="hidden overflow-x-auto rounded-lg border border-zinc-200 md:block dark:border-zinc-800">
          <table className="w-full text-sm">
            <thead className="bg-zinc-50 text-xs text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
              <tr>
                <th className="w-8 px-2 py-2 text-left">
                  {(() => {
                    const selectables = (rows ?? []).filter(isSelectable);
                    const allSelected = selectables.length > 0 && selectables.every((r) => selected.has(r.id));
                    return (
                      <input
                        type="checkbox"
                        checked={allSelected}
                        disabled={selectables.length === 0}
                        onChange={(e) => {
                          if (e.target.checked) {
                            setSelected(new Set(selectables.map((r) => r.id)));
                          } else {
                            clearSelected();
                          }
                        }}
                        title="全選可排程的候選"
                        className="h-4 w-4 cursor-pointer"
                      />
                    );
                  })()}
                </th>
                <th className="px-3 py-2 text-left font-medium">時間</th>
                <th className="px-3 py-2 text-left font-medium">商品名稱</th>
                <th className="px-3 py-2 text-left font-medium">文案</th>
                <th className="px-3 py-2 text-left font-medium">來源</th>
                <th className="px-3 py-2 text-left font-medium">狀態</th>
                <th className="px-3 py-2 text-left font-medium">排程日</th>
                <th className="px-3 py-2 text-left font-medium">動作</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-zinc-100 dark:divide-zinc-800">
              {rows.map((r) => (
                <tr
                  key={r.id}
                  ref={(el) => {
                    if (r.id === highlightId) highlightRowRef.current = el;
                  }}
                  className={`hover:bg-zinc-50 dark:hover:bg-zinc-900/50 ${
                    r.id === highlightId
                      ? "bg-amber-50 ring-2 ring-amber-300 dark:bg-amber-950/30 dark:ring-amber-700"
                      : ""
                  }`}
                >
                  <td className="px-2 py-3">
                    <input
                      type="checkbox"
                      checked={selected.has(r.id)}
                      disabled={!isSelectable(r)}
                      onChange={() => toggleOne(r.id)}
                      className="h-4 w-4 cursor-pointer disabled:cursor-not-allowed disabled:opacity-30"
                      title={selectHint(r)}
                    />
                  </td>
                  <td className="whitespace-nowrap px-3 py-3 text-zinc-500">{fmt(r.created_at)}</td>
                  <td className="px-3 py-3 font-medium">
                    {r.product_name_hint ?? "—"}
                    {(() => {
                      const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
                      const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
                      if (complete) return <span className="ml-1.5 inline-flex rounded-full bg-teal-100 px-1.5 py-0.5 text-[10px] font-medium text-teal-700 dark:bg-teal-900/30 dark:text-teal-300">已補資料</span>;
                      if (any) return <span className="ml-1.5 inline-flex rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">資料未完整</span>;
                      return null;
                    })()}
                  </td>
                  <td className="max-w-xs px-3 py-3 text-zinc-600 dark:text-zinc-300">
                    <span title={r.raw_text}>
                      {r.raw_text.slice(0, 80)}
                      {r.raw_text.length > 80 ? "…" : ""}
                    </span>
                    {(r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null) && (
                      <div className="mt-1 space-y-0.5 text-xs text-zinc-500 dark:text-zinc-400">
                        {r.adopted_supplier_name && <div>廠商：{r.adopted_supplier_name}</div>}
                        {r.adopted_cost !== null && <div>成本：{r.adopted_cost}</div>}
                        {r.adopted_sale_price !== null && <div>售價：{r.adopted_sale_price}</div>}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-3 text-zinc-500">
                    {r.source_user_name ?? r.source_user_id ?? "—"}
                    {r.source_channel && (
                      <div className="text-xs text-zinc-400">{r.source_channel}</div>
                    )}
                    <div>{renderSourceBucket(r)}</div>
                  </td>
                  <td className="px-3 py-3">
                    <span
                      className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                    >
                      {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                    </span>
                  </td>
                  <td className="whitespace-nowrap px-3 py-3 text-zinc-500">
                    {r.scheduled_open_at ?? "—"}
                  </td>
                  <td className="px-3 py-3">{renderActions(r)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Mobile card list */}
        <div className="space-y-2 md:hidden">
          {rows.map((r) => {
            const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
            const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
            return (
              <div
                key={r.id}
                ref={(el) => {
                  if (r.id === highlightId) highlightRowRef.current = el;
                }}
                className={`rounded-lg border p-3 transition ${
                  r.id === highlightId
                    ? "border-amber-300 bg-white ring-2 ring-amber-300 dark:border-amber-700 dark:bg-zinc-900 dark:ring-amber-700"
                    : selected.has(r.id)
                    ? "border-amber-400 bg-amber-50/60 ring-1 ring-amber-300 dark:border-amber-700 dark:bg-amber-950/20 dark:ring-amber-800"
                    : "border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900"
                }`}
              >
                <div className="flex items-center justify-between gap-2">
                  {isSelectable(r) ? (
                    <label className="-m-1.5 flex min-w-0 flex-1 cursor-pointer items-center gap-2 rounded-md p-1.5 active:bg-amber-50 dark:active:bg-amber-950/30">
                      <input
                        type="checkbox"
                        checked={selected.has(r.id)}
                        onChange={() => toggleOne(r.id)}
                        className="h-5 w-5 shrink-0 cursor-pointer accent-amber-600"
                      />
                      <span className="shrink-0 text-xs font-medium text-zinc-500 dark:text-zinc-400">
                        {selected.has(r.id) ? "已選取" : "選取"}
                      </span>
                      <span
                        className={`inline-flex shrink-0 rounded-full px-2 py-0.5 text-[10px] font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                      >
                        {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                      </span>
                    </label>
                  ) : (
                    <span
                      className={`inline-flex rounded-full px-2 py-0.5 text-[10px] font-medium ${ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none}`}
                      title={selectHint(r)}
                    >
                      {ACTION_LABEL[r.owner_action] ?? r.owner_action}
                    </span>
                  )}
                  <span className="shrink-0 text-[11px] text-zinc-400">{fmt(r.created_at)}</span>
                </div>

                <div className="mt-2 flex items-baseline gap-1.5">
                  <span className="text-sm font-medium leading-snug">
                    {r.product_name_hint ?? "—"}
                  </span>
                  {complete && (
                    <span className="inline-flex shrink-0 rounded-full bg-teal-100 px-1.5 py-0.5 text-[10px] font-medium text-teal-700 dark:bg-teal-900/30 dark:text-teal-300">
                      已補資料
                    </span>
                  )}
                  {any && !complete && (
                    <span className="inline-flex shrink-0 rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                      資料未完整
                    </span>
                  )}
                </div>

                <p className="mt-1 whitespace-pre-line text-xs text-zinc-600 dark:text-zinc-300">
                  {r.raw_text.slice(0, 140)}
                  {r.raw_text.length > 140 ? "…" : ""}
                </p>

                {any && (
                  <div className="mt-1.5 space-y-0.5 text-[11px] text-zinc-500 dark:text-zinc-400">
                    {r.adopted_supplier_name && <div>廠商：{r.adopted_supplier_name}</div>}
                    {r.adopted_cost !== null && <div>成本：{r.adopted_cost}</div>}
                    {r.adopted_sale_price !== null && <div>售價：{r.adopted_sale_price}</div>}
                  </div>
                )}

                <div className="mt-2 flex flex-wrap gap-x-3 gap-y-0.5 text-[11px] text-zinc-500">
                  <span>來源：{r.source_user_name ?? r.source_user_id ?? "—"}</span>
                  {r.source_channel && <span className="text-zinc-400">{r.source_channel}</span>}
                  {renderSourceBucket(r)}
                  {r.scheduled_open_at && <span>排程日：{r.scheduled_open_at}</span>}
                </div>

                <div className="mt-2 border-t border-zinc-100 pt-2 dark:border-zinc-800">
                  {renderActions(r)}
                </div>
              </div>
            );
          })}
        </div>
        </>
      )}

      <div className="text-xs text-zinc-400">共 {rows?.length ?? 0} 筆（最多 200）</div>
    </div>
  );
}
