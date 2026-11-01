"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import {
  DndContext,
  pointerWithin,
  rectIntersection,
  closestCorners,
  PointerSensor,
  useSensor,
  useSensors,
  useDroppable,
  type CollisionDetection,
  type DragEndEvent,
  type DragOverEvent,
  type DragStartEvent,
} from "@dnd-kit/core";
import {
  SortableContext,
  useSortable,
  verticalListSortingStrategy,
  arrayMove,
} from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import SpinButton from "@/components/SpinButton";
import { useRole } from "@/lib/role";

type CalendarCandidate = {
  id: number;
  product_name_hint: string | null;
  scheduled_open_at: string | null;
  scheduled_sort_order: number | null;
  owner_action: string;
  created_at: string;
  adopted_supplier_name: string | null;
  adopted_cost: number | null;
  adopted_sale_price: number | null;
  /** manual = 人工排；reco = 從系統預選排入；reco_explore = 系統預選的新嘗試（rpc_calendar_week，20261101000240） */
  source: "manual" | "reco" | "reco_explore";
};

/** 排程卡上的來源標籤：之後要比較「人排的」跟「系統推薦的」哪個賣得好 */
function SourceBadge({ source }: { source: CalendarCandidate["source"] }) {
  if (source === "manual") {
    return <span className="inline-flex rounded px-1.5 py-0.5 text-[10px] bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">人工排</span>;
  }
  return (
    <span className="inline-flex rounded px-1.5 py-0.5 text-[10px] bg-violet-50 text-violet-700 dark:bg-violet-950/40 dark:text-violet-300">
      {source === "reco_explore" ? "系統推薦・新嘗試" : "系統推薦"}
    </span>
  );
}

/** 總部（同候選池 RLS）可以拖拉、排入；店長唯讀 */
const EDIT_ROLES = ["owner", "admin", "hq_manager", "assistant", ""];

/** 推薦系統 ⑥ 系統預選（20261101000170）：只是建議，按「排入」才真的排程 */
type Prediction = { buyers: number; low: number; high: number; confidence: "high" | "mid" | "low"; reasons: string[] };
type Slate = {
  id: number;
  slate_date: string;
  rank: number;
  predicted: number;
  reason: string | null;
  /** exploit = 照預估排；explore = 新嘗試（類別勝率抽樣抽中的，20261101000190） */
  pick_kind: "exploit" | "explore";
  candidate: {
    id: number;
    product_name_hint: string | null;
    raw_text: string | null;
    reco_predictions: Prediction | Prediction[] | null;
  } | null;
};
const slatePrediction = (s: Slate): Prediction | null => {
  const p = s.candidate?.reco_predictions ?? null;
  return Array.isArray(p) ? (p[0] ?? null) : p;
};
const CONF_LABEL: Record<Prediction["confidence"], string> = { high: "信心高", mid: "信心中", low: "信心低" };
const CONF_TAG: Record<Prediction["confidence"], string> = {
  high: "bg-emerald-50 text-emerald-700 dark:bg-emerald-950/40 dark:text-emerald-300",
  mid: "bg-sky-50 text-sky-700 dark:bg-sky-950/40 dark:text-sky-300",
  low: "bg-amber-50 text-amber-700 dark:bg-amber-950/40 dark:text-amber-300",
};

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

const WEEKDAYS = ["日", "一", "二", "三", "四", "五", "六"];

function formatDate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function suggestedTime(idx: number): string {
  const total = 9 * 60 + idx * 30;
  const h = Math.floor(total / 60);
  const m = total % 60;
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export default function CommunityCandidatesCalendarPage() {
  const [rows, setRows] = useState<CalendarCandidate[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [slates, setSlates] = useState<Slate[]>([]);

  const days = useMemo(() => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return Array.from({ length: 7 }, (_, i) => {
      const d = new Date(today);
      d.setDate(d.getDate() + i);
      return d;
    });
  }, []);

  const role = useRole();
  const editable = role !== null && EDIT_ROLES.includes(role);

  const reload = useCallback(async () => {
    if (role === null) return; // 還沒讀到角色，先別決定要不要撈預選
    const startStr = formatDate(days[0]);
    const endStr = formatDate(days[6]);
    // 走 RPC：店長也讀得到（候選池表的 RLS 只開給總部），成本只回給總部
    const { data, error: err } = await getSupabase().rpc("rpc_calendar_week", { p_from: startStr, p_to: endStr });
    if (err) setError(err.message);
    else {
      setError(null);
      setRows((data as CalendarCandidate[]) ?? []);
    }
    if (!EDIT_ROLES.includes(role)) { setSlates([]); return; }
    // 系統預選（讀不到不擋週曆本身）
    const { data: sl } = await getSupabase()
      .from("reco_slates")
      .select(
        "id, slate_date, rank, predicted, reason, pick_kind, candidate:community_product_candidates(id, product_name_hint, raw_text, reco_predictions(buyers, low, high, confidence, reasons))"
      )
      .eq("status", "suggested")
      .gte("slate_date", startStr)
      .lte("slate_date", endStr)
      .order("slate_date", { ascending: true })
      .order("rank", { ascending: true });
    setSlates(((sl as unknown) as Slate[]) ?? []);
  }, [days, role]);

  const slateName = (sl: Slate) => {
    const hint = (sl.candidate?.product_name_hint ?? "").trim();
    if (hint) return hint.slice(0, 60);
    const raw = (sl.candidate?.raw_text ?? "").trim().replace(/\s+/g, " ");
    return raw ? raw.slice(0, 30) : `候選 #${sl.candidate?.id ?? sl.id}`;
  };

  /** 排入：走候選池同一支 rpc_schedule_candidate（建草稿商品），再記成 accepted */
  const acceptSlate = async (sl: Slate) => {
    if (!sl.candidate) return;
    setBusy(true);
    try {
      const sb = getSupabase();
      const { error: rpcErr } = await sb.rpc("rpc_schedule_candidate", {
        p_candidate_id: sl.candidate.id,
        p_scheduled_date: sl.slate_date,
        p_product_name: slateName(sl),
      });
      if (rpcErr) throw rpcErr;
      const order = (localByDate[sl.slate_date]?.length ?? 0) + 1;
      await sb.from("community_product_candidates").update({ scheduled_sort_order: order }).eq("id", sl.candidate.id);
      const { error: decErr } = await sb.rpc("rpc_reco_slate_decide", { p_slate_id: sl.id, p_action: "accepted" });
      if (decErr) console.warn("記錄排入失敗:", decErr.message);
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const skipSlate = async (sl: Slate) => {
    setBusy(true);
    try {
      const { error: decErr } = await getSupabase().rpc("rpc_reco_slate_decide", { p_slate_id: sl.id, p_action: "skipped" });
      if (decErr) throw decErr;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const rebuildSlates = async () => {
    setBusy(true);
    try {
      const { error: rbErr } = await getSupabase().rpc("rpc_reco_rebuild_slates");
      if (rbErr) throw rbErr;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    reload();
  }, [reload]);

  // Local mirror of byDate so drag can produce optimistic updates
  const [localByDate, setLocalByDate] = useState<Record<string, CalendarCandidate[]>>({});

  useEffect(() => {
    const map: Record<string, CalendarCandidate[]> = {};
    for (const d of days) map[formatDate(d)] = [];
    for (const r of rows ?? []) {
      if (r.scheduled_open_at) {
        const key = r.scheduled_open_at.slice(0, 10);
        if (map[key]) map[key].push(r);
      }
    }
    setLocalByDate(map);
  }, [rows, days]);

  const handleRemove = async (r: CalendarCandidate) => {
    const label = r.product_name_hint ?? "（無商品名）";
    if (!window.confirm(`確定把「${label}」移出排程嗎？`)) return;
    setBusy(true);
    try {
      const { error: err } = await getSupabase()
        .from("community_product_candidates")
        .update({
          owner_action: "none",
          scheduled_open_at: null,
          scheduled_sort_order: null,
          updated_at: new Date().toISOString(),
        })
        .eq("id", r.id);
      if (err) throw err;
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  // ============ DnD ============

  const [activeCard, setActiveCard] = useState<CalendarCandidate | null>(null);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 5 } }),
  );

  function findContainer(id: number | string): string | null {
    if (typeof id === "string" && days.some((d) => formatDate(d) === id)) return id;
    const numId = Number(id);
    for (const [day, cards] of Object.entries(localByDate)) {
      if (cards.some((c) => c.id === numId)) return day;
    }
    return null;
  }

  // 自訂 collision detection：優先 pointerWithin（指標真的進入 column 才命中），
  // 沒命中再退回 rectIntersection / closestCorners。這樣空 column 也能被命中。
  const collisionDetection: CollisionDetection = useCallback((args) => {
    const pointerCollisions = pointerWithin(args);
    if (pointerCollisions.length > 0) return pointerCollisions;
    const rectCollisions = rectIntersection(args);
    if (rectCollisions.length > 0) return rectCollisions;
    return closestCorners(args);
  }, []);

  const onDragStart = (e: DragStartEvent) => {
    const id = Number(e.active.id);
    for (const cards of Object.values(localByDate)) {
      const c = cards.find((c) => c.id === id);
      if (c) {
        setActiveCard(c);
        break;
      }
    }
  };

  const onDragOver = (e: DragOverEvent) => {
    const { active, over } = e;
    if (!over) return;
    const activeId = Number(active.id);
    const overContainer = findContainer(over.id as number | string);
    const activeContainer = findContainer(activeId);
    if (!activeContainer || !overContainer) return;
    if (activeContainer === overContainer) return;

    setLocalByDate((prev) => {
      const src = [...(prev[activeContainer] ?? [])];
      const dst = [...(prev[overContainer] ?? [])];
      const idx = src.findIndex((c) => c.id === activeId);
      if (idx < 0) return prev;
      const [card] = src.splice(idx, 1);
      // figure out target index: drop above the over card, or end of list
      const overIdx =
        typeof over.id === "number"
          ? dst.findIndex((c) => c.id === Number(over.id))
          : dst.length;
      dst.splice(overIdx >= 0 ? overIdx : dst.length, 0, card);
      return { ...prev, [activeContainer]: src, [overContainer]: dst };
    });
  };

  const onDragEnd = async (e: DragEndEvent) => {
    const card = activeCard;
    setActiveCard(null);
    const { active, over } = e;
    if (!over || !card) return;
    const activeId = Number(active.id);
    const overContainer = findContainer(over.id as number | string);
    const originalContainer = card.scheduled_open_at?.slice(0, 10) ?? null;
    if (!overContainer) return;

    // Determine current container after onDragOver moves
    const currentContainer = findContainer(activeId);
    if (!currentContainer) return;

    if (currentContainer === originalContainer) {
      // Same-day reorder: arrayMove + persist
      const items = localByDate[currentContainer] ?? [];
      const oldIdx = items.findIndex((c) => c.id === activeId);
      const newIdx =
        typeof over.id === "number"
          ? items.findIndex((c) => c.id === Number(over.id))
          : items.length - 1;
      if (oldIdx < 0 || newIdx < 0 || oldIdx === newIdx) return;
      const newItems = arrayMove(items, oldIdx, newIdx);
      setLocalByDate((p) => ({ ...p, [currentContainer]: newItems }));
      await persistDay(currentContainer, newItems);
      await reload();
    } else {
      // Cross-day move: source already updated in onDragOver
      const srcItems = localByDate[originalContainer ?? ""] ?? [];
      const dstItems = localByDate[currentContainer] ?? [];
      setBusy(true);
      try {
        await persistDay(currentContainer, dstItems);
        if (originalContainer) await persistDay(originalContainer, srcItems);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(false);
      }
      await reload();
    }
  };

  async function persistDay(dayKey: string, items: CalendarCandidate[]) {
    const sb = getSupabase();
    const now = new Date().toISOString();
    const { data: userRes } = await sb.auth.getUser();
    const operator = userRes?.user?.id ?? null;
    for (let i = 0; i < items.length; i++) {
      const order = i + 1;
      const { error: err } = await sb
        .from("community_product_candidates")
        .update({
          scheduled_open_at: dayKey,
          scheduled_sort_order: order,
          updated_at: now,
        })
        .eq("id", items[i].id);
      if (err) throw new Error(err.message);

      // 同步更新對應 campaign（透過 RPC 繞過 RLS — admin 客戶端 JWT role claim 可能為 null）
      if (operator) {
        const { error: rpcErr } = await sb.rpc("rpc_reorder_candidate_campaign", {
          p_candidate_id: items[i].id,
          p_day_key: dayKey,
          p_order: order,
          p_operator: operator,
        });
        if (rpcErr) console.warn("campaign reorder failed:", rpcErr.message);
      }
    }
  }

  const todayStr = formatDate(days[0]);

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <h1 className="text-xl font-semibold">選品週曆</h1>
          <p className="mt-0.5 text-sm text-zinc-500">
            {editable
              ? "未來 7 天 · 拖拉卡片排序或換日 · 虛線卡是系統預選（每天 8 個依預估買家、2 個「新嘗試」；同款還沒結束的不推），按「排入」才會排程"
              : "未來 7 天總部排定要開的團（唯讀）"}
          </p>
        </div>
        {editable && (
        <div className="flex shrink-0 gap-2">
        <SpinButton
          onClick={rebuildSlates}
          disabled={busy}
          className="rounded-md border border-violet-300 px-3 py-1.5 text-sm text-violet-700 hover:bg-violet-50 disabled:opacity-50 dark:border-violet-800 dark:text-violet-300 dark:hover:bg-violet-950/30"
        >
          重新產生預選
        </SpinButton>
        <Link
          href="/community-candidates"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          候選池
        </Link>
        </div>
        )}
      </header>

      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {rows === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : !editable ? (
        <div className="flex gap-2 overflow-x-auto pb-2 lg:grid lg:grid-cols-7 lg:overflow-x-visible lg:pb-0">
          {days.map((d) => {
            const key = formatDate(d);
            const cards = localByDate[key] ?? [];
            return (
              <DayColumn key={key} dayKey={key} day={d} isToday={key === todayStr} cards={cards}>
                {cards.length === 0 ? (
                  <div className="rounded border border-dashed border-zinc-200 px-2 py-4 text-center text-[10px] text-zinc-400 dark:border-zinc-800">
                    無排程
                  </div>
                ) : (
                  cards.map((r, idx) => <ReadonlyCard key={r.id} card={r} idx={idx} />)
                )}
              </DayColumn>
            );
          })}
        </div>
      ) : (
        <DndContext
          sensors={sensors}
          collisionDetection={collisionDetection}
          onDragStart={onDragStart}
          onDragOver={onDragOver}
          onDragEnd={onDragEnd}
        >
          <div className="flex gap-2 overflow-x-auto pb-2 lg:grid lg:grid-cols-7 lg:overflow-x-visible lg:pb-0">
            {days.map((d) => {
              const key = formatDate(d);
              const isToday = key === todayStr;
              const cards = localByDate[key] ?? [];
              return (
                <DayColumn key={key} dayKey={key} day={d} isToday={isToday} cards={cards}>
                  <SortableContext
                    id={key}
                    items={cards.map((c) => c.id)}
                    strategy={verticalListSortingStrategy}
                  >
                    {cards.length === 0 ? (
                      <div className="rounded border border-dashed border-zinc-200 px-2 py-4 text-center text-[10px] text-zinc-400 dark:border-zinc-800">
                        無排程
                      </div>
                    ) : (
                      cards.map((r, idx) => (
                        <SortableCard
                          key={r.id}
                          card={r}
                          idx={idx}
                          busy={busy}
                          onRemove={handleRemove}
                        />
                      ))
                    )}
                  </SortableContext>
                  {slates
                    .filter((sl) => sl.slate_date === key)
                    .map((sl) => (
                      <SlateCard key={`s${sl.id}`} slate={sl} name={slateName(sl)} busy={busy}
                                 onAccept={acceptSlate} onSkip={skipSlate} />
                    ))}
                </DayColumn>
              );
            })}
          </div>
        </DndContext>
      )}

      <div className="text-xs text-zinc-400">共 {rows?.length ?? 0} 筆排程{editable ? `・${slates.length} 筆系統預選` : ""}</div>
    </div>
  );
}

function DayColumn({
  dayKey,
  day,
  isToday,
  cards,
  children,
}: {
  dayKey: string;
  day: Date;
  isToday: boolean;
  cards: CalendarCandidate[];
  children: React.ReactNode;
}) {
  // useDroppable so empty columns can accept drops
  const { setNodeRef, isOver } = useDroppable({ id: dayKey });
  return (
    <div
      ref={setNodeRef}
      className={`flex min-h-[200px] w-[200px] shrink-0 flex-col gap-2 rounded-md p-1 transition lg:w-auto lg:min-w-0 ${
        isOver
          ? "bg-amber-50 ring-2 ring-amber-300 dark:bg-amber-950/30 dark:ring-amber-700"
          : ""
      }`}
    >
      <div
        className={`rounded-md px-2 py-1.5 text-center text-xs font-semibold ${
          isToday
            ? "bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900"
            : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
        }`}
      >
        <div>
          {day.getMonth() + 1}/{day.getDate()}
        </div>
        <div className="text-[10px] font-normal opacity-70">週{WEEKDAYS[day.getDay()]}</div>
      </div>
      {children}
    </div>
  );
}

function SortableCard({
  card: r,
  idx,
  busy,
  onRemove,
}: {
  card: CalendarCandidate;
  idx: number;
  busy: boolean;
  onRemove: (r: CalendarCandidate) => void;
}) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: r.id,
  });

  const style: React.CSSProperties = {
    transform: CSS.Transform.toString(transform),
    transition,
    opacity: isDragging ? 0.4 : 1,
  };

  const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
  const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);

  return (
    <div
      ref={setNodeRef}
      style={style}
      className="flex flex-col gap-1.5 rounded-md border border-zinc-200 bg-white p-2 text-xs shadow-sm dark:border-zinc-800 dark:bg-zinc-900"
    >
      <div className="flex items-stretch gap-2">
        <span
          {...attributes}
          {...listeners}
          role="button"
          aria-label="拖拉排序或換日"
          title="拖拉排序 / 換日"
          className="flex w-9 shrink-0 cursor-grab touch-none select-none items-center justify-center rounded-md border border-zinc-200 bg-zinc-50 text-zinc-400 transition hover:border-zinc-300 hover:bg-zinc-100 hover:text-zinc-600 active:cursor-grabbing active:bg-zinc-200 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-500 dark:hover:bg-zinc-700 dark:hover:text-zinc-300 lg:w-5 lg:rounded"
        >
          <svg
            viewBox="0 0 24 24"
            fill="currentColor"
            aria-hidden="true"
            className="h-5 w-5 lg:h-3.5 lg:w-3.5"
          >
            <circle cx="9" cy="6" r="1.6" />
            <circle cx="15" cy="6" r="1.6" />
            <circle cx="9" cy="12" r="1.6" />
            <circle cx="15" cy="12" r="1.6" />
            <circle cx="9" cy="18" r="1.6" />
            <circle cx="15" cy="18" r="1.6" />
          </svg>
        </span>
        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <span className="font-mono text-[10px] font-semibold text-zinc-400 dark:text-zinc-500">
            {suggestedTime(idx)}
          </span>
          <Link
            href={`/community-candidates?highlight=${r.id}`}
            title={r.product_name_hint ?? "（無商品名）"}
            className="line-clamp-2 font-medium leading-snug hover:underline"
          >
            {r.product_name_hint ?? "（無商品名）"}
          </Link>
        </div>
      </div>
      <div className="flex flex-wrap gap-1">
        <span
          className={`inline-flex rounded-full px-1.5 py-0.5 text-[10px] font-medium ${
            ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none
          }`}
        >
          {ACTION_LABEL[r.owner_action] ?? r.owner_action}
        </span>
        <SourceBadge source={r.source} />
        {complete && (
          <span className="inline-flex rounded-full bg-teal-100 px-1.5 py-0.5 text-[10px] font-medium text-teal-700 dark:bg-teal-900/30 dark:text-teal-300">
            已補資料
          </span>
        )}
        {any && !complete && (
          <span className="inline-flex rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
            資料未完整
          </span>
        )}
      </div>
      {any && (
        <div className="space-y-0.5 text-[10px] text-zinc-500 dark:text-zinc-400">
          {r.adopted_supplier_name && <div>廠商：{r.adopted_supplier_name}</div>}
          {r.adopted_cost !== null && <div>成本：{r.adopted_cost}</div>}
          {r.adopted_sale_price !== null && <div>售價：{r.adopted_sale_price}</div>}
        </div>
      )}
      <div className="flex gap-1 pt-0.5">
        <SpinButton
          onClick={() => onRemove(r)}
          disabled={busy}
          className="ml-auto rounded border border-red-300 px-1.5 py-0.5 text-[10px] text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/30 disabled:opacity-50"
          title="移出排程"
        >
          移出
        </SpinButton>
      </div>
    </div>
  );
}

/** 系統預選卡（虛線）：預估、理由、排入 / 略過 */
function SlateCard({
  slate: sl,
  name,
  busy,
  onAccept,
  onSkip,
}: {
  slate: Slate;
  name: string;
  busy: boolean;
  onAccept: (sl: Slate) => void;
  onSkip: (sl: Slate) => void;
}) {
  const p = slatePrediction(sl);
  const explore = sl.pick_kind === "explore";
  // 新嘗試的理由放類別勝率（「零食餅乾近 4 個月 133 團、87 團賣贏中位數」），照預估的放最像的商品
  const why = explore ? sl.reason : (p?.reasons[0] ?? sl.reason);
  return (
    <div className="flex flex-col gap-1 rounded-md border border-dashed border-violet-300 bg-violet-50/60 p-2 text-xs dark:border-violet-800 dark:bg-violet-950/20"
         title={p?.reasons.join("\n") ?? sl.reason ?? ""}>
      <div className="flex items-center gap-1">
        <span className="text-[10px] font-semibold text-violet-600 dark:text-violet-300">系統預選</span>
        {explore && (
          <span className="inline-flex rounded bg-rose-50 px-1.5 py-0.5 text-[10px] text-rose-600 dark:bg-rose-950/40 dark:text-rose-300"
                title="這類商品最近開得少、還看不出準不準，系統挑一個出來試試看；賣得好以後這類就會多推">
            新嘗試
          </span>
        )}
      </div>
      <Link href={`/community-candidates?highlight=${sl.candidate?.id ?? ""}`}
            className="line-clamp-2 font-medium leading-snug hover:underline">
        {name}
      </Link>
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-[11px] font-bold text-zinc-800 dark:text-zinc-100">約 {p?.buyers ?? sl.predicted} 位</span>
        {p && (
          <span className={`inline-flex rounded px-1.5 py-0.5 text-[10px] ${CONF_TAG[p.confidence]}`}>
            {CONF_LABEL[p.confidence]}
          </span>
        )}
        {p && <span className="text-[10px] text-zinc-400">{p.low}～{p.high} 位</span>}
      </div>
      {why && (
        <div className="line-clamp-2 text-[10px] text-zinc-500 dark:text-zinc-400">{why.replace(/^試新：/, "")}</div>
      )}
      <div className="flex gap-1 pt-0.5">
        <SpinButton
          onClick={() => onAccept(sl)}
          disabled={busy}
          className="rounded border border-violet-400 bg-white px-1.5 py-0.5 text-[10px] text-violet-700 hover:bg-violet-100 disabled:opacity-50 dark:bg-zinc-900 dark:text-violet-300"
        >
          排入
        </SpinButton>
        <SpinButton
          onClick={() => onSkip(sl)}
          disabled={busy}
          className="ml-auto rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] text-zinc-500 hover:bg-zinc-50 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          title="不要這一項，之後不會再推"
        >
          略過
        </SpinButton>
      </div>
    </div>
  );
}

/** 店長看的唯讀卡：沒有拖拉、沒有移出、不連到候選池 */
function ReadonlyCard({ card: r, idx }: { card: CalendarCandidate; idx: number }) {
  return (
    <div className="flex flex-col gap-1 rounded-md border border-zinc-200 bg-white p-2 text-xs shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
      <span className="font-mono text-[10px] font-semibold text-zinc-400 dark:text-zinc-500">{suggestedTime(idx)}</span>
      <span className="line-clamp-2 font-medium leading-snug" title={r.product_name_hint ?? "（無商品名）"}>
        {r.product_name_hint ?? "（無商品名）"}
      </span>
      <div className="flex flex-wrap gap-1">
        <SourceBadge source={r.source} />
      </div>
    </div>
  );
}
