"use client";

// 首頁「在線狀態」卡：同時在線（最近 3 分鐘有心跳）＋ 今日活躍（DAU），
// 店員端／會員端分開數。資料來自 rpc_online_stats（app_presence 彙總，
// 心跳由 PresenceBeacon / 會員端 PresenceHeartbeat 每 60 秒回報）。
// QPS 不自己做 —— 右上角連去 Supabase Reports 現成的 API 流量圖。

import { useEffect, useState } from "react";
import { getSupabase } from "@/lib/supabase";

type OnlineStats = {
  online_staff: number;
  online_members: number;
  online_guests: number;
  dau_staff: number;
  dau_members: number;
  dau_guests: number;
  daily: { date: string; staff: number; members: number; guests: number }[];
};

const REFRESH_MS = 60_000;

export default function OnlineStatsCard() {
  const [stats, setStats] = useState<OnlineStats | null>(null);

  useEffect(() => {
    let cancelled = false;
    const load = async () => {
      const { data, error } = await getSupabase().rpc("rpc_online_stats");
      // 首頁的摘要壞掉不該擋住整個儀表板，維持上一筆靜靜等下一輪
      if (!cancelled && !error && data) setStats(data as OnlineStats);
    };
    void load();
    const timer = setInterval(load, REFRESH_MS);
    window.addEventListener("focus", load);
    return () => {
      cancelled = true;
      clearInterval(timer);
      window.removeEventListener("focus", load);
    };
  }, []);

  const projectRef =
    process.env.NEXT_PUBLIC_SUPABASE_URL?.match(/^https:\/\/([^.]+)\./)?.[1];
  const days = (stats?.daily ?? []).slice(-7);

  return (
    <section className="rounded-md border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex items-center justify-between border-b border-zinc-200 px-4 py-3 dark:border-zinc-800">
        <h2 className="text-sm font-semibold">
          在線狀態 <span className="ml-1 text-xs font-normal text-zinc-500">每分鐘更新</span>
        </h2>
        {projectRef && (
          <a
            href={`https://supabase.com/dashboard/project/${projectRef}/reports/api-overview`}
            target="_blank"
            rel="noreferrer"
            className="text-xs text-blue-600 hover:underline dark:text-blue-400"
          >
            QPS／API 流量（Supabase Reports）→
          </a>
        )}
      </div>

      <div className="grid gap-3 p-4 sm:grid-cols-3 lg:grid-cols-6">
        <Num label="同時在線・店員" value={stats?.online_staff} accent="text-emerald-600 dark:text-emerald-400" />
        <Num label="同時在線・會員" value={stats?.online_members} accent="text-emerald-600 dark:text-emerald-400" />
        <Num label="同時在線・商城訪客" value={stats?.online_guests} accent="text-emerald-600 dark:text-emerald-400" />
        <Num label="今日活躍・店員" value={stats?.dau_staff} accent="text-blue-600 dark:text-blue-400" />
        <Num label="今日活躍・會員" value={stats?.dau_members} accent="text-blue-600 dark:text-blue-400" />
        <Num label="今日活躍・商城訪客" value={stats?.dau_guests} accent="text-blue-600 dark:text-blue-400" />
      </div>

      {days.length > 1 && (
        <div className="overflow-x-auto border-t border-zinc-200 dark:border-zinc-800">
          <table className="min-w-full text-xs">
            <thead className="bg-zinc-50 dark:bg-zinc-950/40">
              <tr>
                <th className="px-3 py-1.5 text-left font-medium text-zinc-500">近 7 日活躍</th>
                {days.map((d) => (
                  <th key={d.date} className="px-2 py-1.5 text-right font-normal text-zinc-500">
                    {d.date.slice(5)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              <tr className="border-t border-zinc-100 dark:border-zinc-800">
                <td className="px-3 py-1.5 text-zinc-500">店員</td>
                {days.map((d) => (
                  <td key={d.date} className="px-2 py-1.5 text-right font-mono">{d.staff}</td>
                ))}
              </tr>
              <tr className="border-t border-zinc-100 dark:border-zinc-800">
                <td className="px-3 py-1.5 text-zinc-500">會員</td>
                {days.map((d) => (
                  <td key={d.date} className="px-2 py-1.5 text-right font-mono">{d.members}</td>
                ))}
              </tr>
              <tr className="border-t border-zinc-100 dark:border-zinc-800">
                <td className="px-3 py-1.5 text-zinc-500">商城訪客</td>
                {days.map((d) => (
                  <td key={d.date} className="px-2 py-1.5 text-right font-mono">{d.guests ?? 0}</td>
                ))}
              </tr>
            </tbody>
          </table>
        </div>
      )}

      <div className="border-t border-zinc-100 px-4 py-2 text-[11px] text-zinc-400 dark:border-zinc-800">
        同時在線＝最近 3 分鐘有心跳；活躍＝當天開過後台／會員站／商城（訪客＝未登入逛商城）。指標自 2026-08-27 起累計。
      </div>
    </section>
  );
}

function Num({ label, value, accent }: { label: string; value: number | undefined; accent?: string }) {
  return (
    <div className="rounded-md border border-zinc-100 p-3 dark:border-zinc-800">
      <div className="text-xs text-zinc-500">{label}</div>
      <div className={`mt-1 text-2xl font-semibold ${accent ?? ""}`}>{value ?? "…"}</div>
    </div>
  );
}
