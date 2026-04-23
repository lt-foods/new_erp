"use client";

import { Suspense, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { CampaignForm, type CampaignFormValues } from "@/components/CampaignForm";
import { CampaignItemsTable } from "@/components/CampaignItemsTable";

type Row = {
  id: number;
  campaign_no: string;
  name: string;
  description: string | null;
  status: CampaignFormValues["status"];
  close_type: CampaignFormValues["close_type"];
  start_at: string | null;
  end_at: string | null;
  pickup_deadline: string | null;
  pickup_days: number | null;
  total_cap_qty: number | null;
  notes: string | null;
};

export default function EditCampaignPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <Body />
    </Suspense>
  );
}

function Body() {
  const params = useSearchParams();
  const id = params.get("id");
  const saved = params.get("saved") === "1";
  const [initial, setInitial] = useState<CampaignFormValues | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) { setError("缺少 id 參數"); return; }
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("group_buy_campaigns")
        .select("id, campaign_no, name, description, status, close_type, start_at, end_at, pickup_deadline, pickup_days, total_cap_qty, notes")
        .eq("id", Number(id)).maybeSingle<Row>();
      if (err) { setError(err.message); return; }
      if (!data) { setError("找不到這個開團"); return; }
      setInitial({
        id: data.id,
        campaign_no: data.campaign_no,
        name: data.name,
        description: data.description,
        status: data.status,
        close_type: data.close_type,
        start_at: data.start_at,
        end_at: data.end_at,
        pickup_deadline: data.pickup_deadline,
        pickup_days: data.pickup_days,
        total_cap_qty: data.total_cap_qty != null ? Number(data.total_cap_qty) : null,
        notes: data.notes,
      });
    })();
  }, [id]);

  if (error) return <div className="mx-auto max-w-3xl p-6"><div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div></div>;
  if (!initial) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <div className="mx-auto w-full max-w-4xl space-y-8 p-6">
      <header>
        <Link href="/campaigns" className="text-sm text-zinc-500 hover:text-zinc-800 dark:hover:text-zinc-200">← 開團列表</Link>
        <h1 className="mt-1 text-xl font-semibold">編輯開團 <span className="font-mono text-sm text-zinc-500">#{initial.campaign_no}</span></h1>
      </header>
      {saved && (
        <div className="rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300">已儲存</div>
      )}
      <CampaignForm initial={initial} />
      <div className="border-t border-zinc-200 pt-6 dark:border-zinc-800">
        <CampaignItemsTable campaignId={initial.id!} />
      </div>
    </div>
  );
}
