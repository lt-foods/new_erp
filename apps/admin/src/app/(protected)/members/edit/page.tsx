"use client";

import { Suspense, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { MemberForm, type MemberFormValues } from "@/components/MemberForm";

type MemberRow = {
  id: number;
  member_no: string;
  phone: string | null;
  name: string | null;
  gender: "M" | "F" | "O" | null;
  birthday: string | null;
  email: string | null;
  tier_id: number | null;
  home_store_id: number | null;
  status: MemberFormValues["status"];
  notes: string | null;
};

export default function EditMemberPage() {
  return (
    <Suspense fallback={<div className="p-6 text-sm text-zinc-500">載入中…</div>}>
      <EditMemberBody />
    </Suspense>
  );
}

function EditMemberBody() {
  const params = useSearchParams();
  const id = params.get("id");
  const saved = params.get("saved") === "1";
  const [initial, setInitial] = useState<MemberFormValues | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) {
      setError("缺少 id 參數");
      return;
    }
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("members")
        .select("id, member_no, phone, name, gender, birthday, email, tier_id, home_store_id, status, notes")
        .eq("id", Number(id))
        .maybeSingle<MemberRow>();
      if (err) {
        setError(err.message);
        return;
      }
      if (!data) {
        setError("找不到這位會員");
        return;
      }
      setInitial({
        id: data.id,
        member_no: data.member_no,
        phone: data.phone ?? "",
        name: data.name ?? "",
        gender: data.gender,
        birthday: data.birthday,
        email: data.email,
        tier_id: data.tier_id,
        home_store_id: data.home_store_id,
        status: data.status,
        notes: data.notes,
      });
    })();
  }, [id]);

  if (error) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <div className="rounded-md border border-red-200 bg-red-50 p-4 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
          {error}
        </div>
      </div>
    );
  }
  if (!initial) return <div className="p-6 text-sm text-zinc-500">載入中…</div>;

  return (
    <div className="mx-auto w-full max-w-3xl space-y-6 p-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold">編輯會員</h1>
          <p className="text-sm text-zinc-500">#{initial.member_no}</p>
        </div>
        <Link
          href={`/members/detail?id=${initial.id}`}
          className="rounded-md border border-zinc-300 px-3 py-2 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          詳細
        </Link>
      </header>
      {saved && (
        <div className="rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300">
          已儲存
        </div>
      )}
      <MemberForm initial={initial} />
    </div>
  );
}
