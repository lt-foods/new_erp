"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import {
  DndContext,
  closestCorners,
  PointerSensor,
  useSensor,
  useSensors,
  useDroppable,
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
  const [selectedDayIdx, setSelectedDayIdx] = useState(0);

  const days = useMemo(() => {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return Array.from({ length: 7 }, (_, i) => {
      const d = new Date(today);
      d.setDate(d.getDate() + i);
      return d;
    });
  }, []);

  const reload = useCallback(async () => {
    const startStr = formatDate(days[0]);
    const endStr = formatDate(days[6]);
    const { data, error: err } = await getSupabase()
      .from("community_product_candidates")
      .select(
        "id, product_name_hint, scheduled_open_at, scheduled_sort_order, owner_action, created_at, adopted_supplier_name, adopted_cost, adopted_sale_price"
      )
      .not("scheduled_open_at", "is", null)
      .gte("scheduled_open_at", startStr)
      .lte("scheduled_open_at", endStr)
      .order("scheduled_open_at", { ascending: true })
      .order("scheduled_sort_order", { ascending: true, nullsFirst: false })
      .order("created_at", { ascending: true });
    if (err) setError(err.message);
    else {
      setError(null);
      setRows((data as CalendarCandidate[]) ?? []);
    }
  }, [days]);

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

  const handleReschedule = async (r: CalendarCandidate, newDateStr: string) => {
    if (!newDateStr) return;
    if (r.scheduled_open_at?.slice(0, 10) === newDateStr) return;
    setBusy(true);
    try {
      const sb = getSupabase();
      // 取目標日的下一個 sort order（end of day）
      const { data: existing } = await sb
        .from("community_product_candidates")
        .select("scheduled_sort_order")
        .eq("scheduled_open_at", newDateStr)
        .order("scheduled_sort_order", { ascending: false, nullsFirst: false })
        .limit(1);
      const nextOrder =
        ((existing as { scheduled_sort_order: number | null }[] | null)?.[0]
          ?.scheduled_sort_order ?? -1) + 1;
      const { error: err } = await sb
        .from("community_product_candidates")
        .update({
          scheduled_open_at: newDateStr,
          scheduled_sort_order: nextOrder,
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
    for (let i = 0; i < items.length; i++) {
      const { error: err } = await sb
        .from("community_product_candidates")
        .update({
          scheduled_open_at: dayKey,
          scheduled_sort_order: i + 1,
          updated_at: now,
        })
        .eq("id", items[i].id);
      if (err) throw new Error(err.message);
    }
  }

  const todayStr = formatDate(days[0]);
  const selectedDay = days[selectedDayIdx];
  const selectedDayKey = formatDate(selectedDay);
  const selectedDayCards = byDate.get(selectedDayKey) ?? [];

  function renderCard(r: CalendarCandidate, idx: number, total: number) {
    const any = r.adopted_supplier_name || r.adopted_cost !== null || r.adopted_sale_price !== null;
    const complete = !!(r.adopted_supplier_name && r.adopted_cost !== null && r.adopted_sale_price !== null);
    const isFirst = idx === 0;
    const isLast = idx === total - 1;
    const curDay = r.scheduled_open_at?.slice(0, 10) ?? "";
    return (
      <div
        key={r.id}
        className="flex flex-col gap-1.5 rounded-md border border-zinc-200 bg-white p-2 text-xs dark:border-zinc-800 dark:bg-zinc-900"
      >
        <div className="flex items-baseline gap-1.5">
          <span className="font-mono text-[10px] font-semibold text-zinc-500 dark:text-zinc-400">
            {suggestedTime(idx)}
          </span>
          <Link
            href={`/community-candidates?highlight=${r.id}`}
            className="font-medium leading-snug hover:underline"
          >
            {r.product_name_hint ?? "（無商品名）"}
          </Link>
        </div>
        <div className="flex flex-wrap gap-1">
          <span
            className={`inline-flex rounded-full px-1.5 py-0.5 text-[10px] font-medium ${
              ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none
            }`}
          >
            {ACTION_LABEL[r.owner_action] ?? r.owner_action}
          </span>
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
        <div className="flex flex-wrap items-center gap-1 pt-0.5">
          {!isFirst && (
            <button
              onClick={() => handleMoveUp(r)}
              disabled={busy}
              className="rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800 disabled:opacity-50"
              title="上移"
            >
              上移
            </button>
          )}
          {!isLast && (
            <button
              onClick={() => handleMoveDown(r)}
              disabled={busy}
              className="rounded border border-zinc-300 px-1.5 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800 disabled:opacity-50"
              title="下移"
            >
              下移
            </button>
          )}
          <select
            value={curDay}
            disabled={busy}
            onChange={(e) => handleReschedule(r, e.target.value)}
            title="改排程日"
            className="rounded border border-zinc-300 bg-white px-1 py-0.5 text-[10px] text-zinc-600 hover:bg-zinc-50 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300 dark:hover:bg-zinc-800 disabled:opacity-50"
          >
            {days.map((d) => {
              const ds = formatDate(d);
              const label = `${d.getMonth() + 1}/${d.getDate()} (${WEEKDAYS[d.getDay()]})`;
              return (
                <option key={ds} value={ds}>
                  {ds === curDay ? `📌 ${label}` : label}
                </option>
              );
            })}
          </select>
          <button
            onClick={() => handleRemove(r)}
            disabled={busy}
            className="ml-auto rounded border border-red-300 px-1.5 py-0.5 text-[10px] text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/30 disabled:opacity-50"
            title="移出排程"
          >
            移出
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-1 flex-col gap-4 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">選品週曆</h1>
          <p className="mt-0.5 text-sm text-zinc-500">未來 7 天 · 拖拉卡片排序或換日</p>
        </div>
        <Link
          href="/community-candidates"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-900"
        >
          候選池
        </Link>
      </header>

      {error && (
        <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      )}

      {rows === null ? (
        <div className="text-sm text-zinc-400">載入中…</div>
      ) : (
        <DndContext
          sensors={sensors}
          collisionDetection={closestCorners}
          onDragStart={onDragStart}
          onDragOver={onDragOver}
          onDragEnd={onDragEnd}
        >
          <div className="grid grid-cols-7 gap-2 overflow-x-auto">
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
                </DayColumn>
              );
            })}
          </div>
        </DndContext>
      )}

      <div className="text-xs text-zinc-400">共 {rows?.length ?? 0} 筆</div>
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
      className={`flex min-w-[120px] flex-col gap-2 rounded-md p-1 transition ${
        isOver && cards.length === 0
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
      <div className="flex items-baseline gap-1.5">
        <span
          {...attributes}
          {...listeners}
          className="cursor-grab select-none touch-none font-mono text-[10px] font-semibold text-zinc-400 hover:text-zinc-700 active:cursor-grabbing dark:text-zinc-500 dark:hover:text-zinc-200"
          title="拖拉排序 / 換日"
        >
          ⋮⋮ {suggestedTime(idx)}
        </span>
        <Link
          href={`/community-candidates?highlight=${r.id}`}
          className="font-medium leading-snug hover:underline"
        >
          {r.product_name_hint ?? "（無商品名）"}
        </Link>
      </div>
      <div className="flex flex-wrap gap-1">
        <span
          className={`inline-flex rounded-full px-1.5 py-0.5 text-[10px] font-medium ${
            ACTION_COLOR[r.owner_action] ?? ACTION_COLOR.none
          }`}
        >
          {ACTION_LABEL[r.owner_action] ?? r.owner_action}
        </span>
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
        <button
          onClick={() => onRemove(r)}
          disabled={busy}
          className="ml-auto rounded border border-red-300 px-1.5 py-0.5 text-[10px] text-red-600 hover:bg-red-50 dark:border-red-800 dark:text-red-400 dark:hover:bg-red-950/30 disabled:opacity-50"
          title="移出排程"
        >
          移出
        </button>
      </div>
    </div>
  );
}
