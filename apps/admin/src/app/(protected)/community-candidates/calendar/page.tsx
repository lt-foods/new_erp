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

type CalendarCandidate = {
  id: number;
  product_name_hint: string | null;
  scheduled_open_at: string | null;
  scheduled_slot_index: number | null;
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

// 09:00 → 21:00 共 13 個整點時段
const SLOT_COUNT = 13;
const SLOT_START_HOUR = 9;

function slotTime(idx: number): string {
  return `${String(SLOT_START_HOUR + idx).padStart(2, "0")}:00`;
}

function clampSlot(idx: number | null | undefined): number {
  if (idx === null || idx === undefined) return 0;
  if (idx < 0) return 0;
  if (idx > SLOT_COUNT - 1) return SLOT_COUNT - 1;
  return idx;
}

function formatDate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

// droppable id 格式：YYYY-MM-DD#slotIdx
function cellId(dayKey: string, slotIdx: number): string {
  return `${dayKey}#${slotIdx}`;
}

function parseCellId(id: string): { day: string; slot: number } | null {
  const m = id.match(/^(\d{4}-\d{2}-\d{2})#(\d+)$/);
  if (!m) return null;
  return { day: m[1], slot: parseInt(m[2], 10) };
}

export default function CommunityCandidatesCalendarPage() {
  const [rows, setRows] = useState<CalendarCandidate[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

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
        "id, product_name_hint, scheduled_open_at, scheduled_slot_index, scheduled_sort_order, owner_action, created_at, adopted_supplier_name, adopted_cost, adopted_sale_price"
      )
      .not("scheduled_open_at", "is", null)
      .gte("scheduled_open_at", startStr)
      .lte("scheduled_open_at", endStr)
      .order("scheduled_open_at", { ascending: true })
      .order("scheduled_slot_index", { ascending: true, nullsFirst: true })
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

  // Local mirror keyed by `${dayKey}#${slotIdx}` so drag can produce optimistic updates
  const [localByCell, setLocalByCell] = useState<Record<string, CalendarCandidate[]>>({});

  useEffect(() => {
    const map: Record<string, CalendarCandidate[]> = {};
    for (const d of days) {
      const dayKey = formatDate(d);
      for (let s = 0; s < SLOT_COUNT; s++) {
        map[cellId(dayKey, s)] = [];
      }
    }
    for (const r of rows ?? []) {
      if (!r.scheduled_open_at) continue;
      const dayKey = r.scheduled_open_at.slice(0, 10);
      const slot = clampSlot(r.scheduled_slot_index);
      const k = cellId(dayKey, slot);
      if (map[k]) map[k].push(r);
    }
    setLocalByCell(map);
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
          scheduled_slot_index: null,
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
    if (typeof id === "string" && parseCellId(id)) return id;
    const numId = Number(id);
    for (const [cell, cards] of Object.entries(localByCell)) {
      if (cards.some((c) => c.id === numId)) return cell;
    }
    return null;
  }

  const collisionDetection: CollisionDetection = useCallback((args) => {
    const pointerCollisions = pointerWithin(args);
    if (pointerCollisions.length > 0) return pointerCollisions;
    const rectCollisions = rectIntersection(args);
    if (rectCollisions.length > 0) return rectCollisions;
    return closestCorners(args);
  }, []);

  const onDragStart = (e: DragStartEvent) => {
    const id = Number(e.active.id);
    for (const cards of Object.values(localByCell)) {
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

    setLocalByCell((prev) => {
      const src = [...(prev[activeContainer] ?? [])];
      const dst = [...(prev[overContainer] ?? [])];
      const idx = src.findIndex((c) => c.id === activeId);
      if (idx < 0) return prev;
      const [card] = src.splice(idx, 1);
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
    const originalDay = card.scheduled_open_at?.slice(0, 10) ?? null;
    const originalSlot = clampSlot(card.scheduled_slot_index);
    const originalContainer = originalDay ? cellId(originalDay, originalSlot) : null;
    if (!overContainer) return;

    const currentContainer = findContainer(activeId);
    if (!currentContainer) return;

    if (currentContainer === originalContainer) {
      // Same-cell reorder
      const items = localByCell[currentContainer] ?? [];
      const oldIdx = items.findIndex((c) => c.id === activeId);
      const newIdx =
        typeof over.id === "number"
          ? items.findIndex((c) => c.id === Number(over.id))
          : items.length - 1;
      if (oldIdx < 0 || newIdx < 0 || oldIdx === newIdx) return;
      const newItems = arrayMove(items, oldIdx, newIdx);
      setLocalByCell((p) => ({ ...p, [currentContainer]: newItems }));
      await persistCell(currentContainer, newItems);
      await reload();
    } else {
      // Cross-cell move: source already updated in onDragOver
      const srcItems = originalContainer ? localByCell[originalContainer] ?? [] : [];
      const dstItems = localByCell[currentContainer] ?? [];
      setBusy(true);
      try {
        await persistCell(currentContainer, dstItems);
        if (originalContainer) await persistCell(originalContainer, srcItems);
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err));
      } finally {
        setBusy(false);
      }
      await reload();
    }
  };

  async function persistCell(cellKey: string, items: CalendarCandidate[]) {
    const parsed = parseCellId(cellKey);
    if (!parsed) return;
    const { day, slot } = parsed;
    const sb = getSupabase();
    const now = new Date().toISOString();
    const { data: userRes } = await sb.auth.getUser();
    const operator = userRes?.user?.id ?? null;
    for (let i = 0; i < items.length; i++) {
      const order = i + 1;
      const { error: err } = await sb
        .from("community_product_candidates")
        .update({
          scheduled_open_at: day,
          scheduled_slot_index: slot,
          scheduled_sort_order: order,
          updated_at: now,
        })
        .eq("id", items[i].id);
      if (err) throw new Error(err.message);

      if (operator) {
        const { error: rpcErr } = await sb.rpc("rpc_reorder_candidate_campaign", {
          p_candidate_id: items[i].id,
          p_day_key: day,
          p_slot_index: slot,
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
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">選品週曆</h1>
          <p className="mt-0.5 text-sm text-zinc-500">未來 7 天 · 每整點時段（09:00–21:00）可放多商品 · 拖拉換時段或換日</p>
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
          collisionDetection={collisionDetection}
          onDragStart={onDragStart}
          onDragOver={onDragOver}
          onDragEnd={onDragEnd}
        >
          <div className="flex gap-2 overflow-x-auto pb-2 lg:grid lg:grid-cols-7 lg:overflow-x-visible lg:pb-0">
            {days.map((d) => {
              const dayKey = formatDate(d);
              const isToday = dayKey === todayStr;
              return (
                <DayColumn key={dayKey} day={d} isToday={isToday}>
                  {Array.from({ length: SLOT_COUNT }, (_, slotIdx) => {
                    const k = cellId(dayKey, slotIdx);
                    const cards = localByCell[k] ?? [];
                    return (
                      <SlotCell
                        key={k}
                        cellKey={k}
                        time={slotTime(slotIdx)}
                        empty={cards.length === 0}
                      >
                        <SortableContext
                          id={k}
                          items={cards.map((c) => c.id)}
                          strategy={verticalListSortingStrategy}
                        >
                          {cards.map((r) => (
                            <SortableCard
                              key={r.id}
                              card={r}
                              busy={busy}
                              onRemove={handleRemove}
                            />
                          ))}
                        </SortableContext>
                      </SlotCell>
                    );
                  })}
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
  day,
  isToday,
  children,
}: {
  day: Date;
  isToday: boolean;
  children: React.ReactNode;
}) {
  return (
    <div className="flex w-[220px] shrink-0 flex-col gap-1 lg:w-auto lg:min-w-0">
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
      <div className="flex flex-col gap-0.5">{children}</div>
    </div>
  );
}

function SlotCell({
  cellKey,
  time,
  empty,
  children,
}: {
  cellKey: string;
  time: string;
  empty: boolean;
  children: React.ReactNode;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: cellKey });
  return (
    <div
      ref={setNodeRef}
      className={`flex gap-1.5 rounded-md p-1 transition ${
        isOver
          ? "bg-amber-50 ring-1 ring-amber-300 dark:bg-amber-950/30 dark:ring-amber-700"
          : ""
      }`}
    >
      <div className="w-9 shrink-0 pt-1 text-right font-mono text-[10px] font-medium text-zinc-400 dark:text-zinc-500">
        {time}
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        {empty ? (
          <div className="rounded border border-dashed border-zinc-200 px-2 py-2 text-center text-[10px] text-zinc-300 dark:border-zinc-800 dark:text-zinc-600">
            —
          </div>
        ) : (
          children
        )}
      </div>
    </div>
  );
}

function SortableCard({
  card: r,
  busy,
  onRemove,
}: {
  card: CalendarCandidate;
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
          aria-label="拖拉排序或換時段"
          title="拖拉排序 / 換時段"
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
          <Link
            href={`/community-candidates?highlight=${r.id}`}
            className="font-medium leading-snug hover:underline"
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
