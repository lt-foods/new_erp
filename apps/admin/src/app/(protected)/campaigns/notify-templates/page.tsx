"use client";

// 上架通知文本設定：依收單類型各一版（美食列車優先）。
// 佔位符 {團名} {團號} {收單時間}；清空儲存 = 恢復內建預設。
// 排程與即時廣播（美食列車開團）都吃這裡的文本。

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { getSupabase } from "@/lib/supabase";
import SpinButton from "@/components/SpinButton";
import { useRole, isAdmin } from "@/lib/role";
import {
  DEFAULT_NOTIFY_TEMPLATE,
  NOTIFY_PLACEHOLDERS,
  renderNotifyText,
  type CloseType,
  type NotifyTemplate,
} from "@/lib/campaignNotifyText";

const TYPES: { value: CloseType; label: string; hint?: string }[] = [
  { value: "food_train", label: "美食列車", hint: "開團上架時的廣播 / 排程上架通知都用這一版" },
  { value: "regular", label: "常規" },
  { value: "fast", label: "快團" },
  { value: "limited", label: "限量" },
];

const PREVIEW_SAMPLE = {
  name: "週三美食列車＃麻辣鴨血",
  campaign_no: "GRP-20260814-001",
  end_at: (() => {
    const d = new Date();
    d.setDate(d.getDate() + 1);
    d.setHours(12, 0, 0, 0);
    return d.toISOString();
  })(),
};

export default function NotifyTemplatesPage() {
  const role = useRole();
  const admin = isAdmin(role);
  const [drafts, setDrafts] = useState<Record<CloseType, NotifyTemplate>>({ ...DEFAULT_NOTIFY_TEMPLATE });
  const [customized, setCustomized] = useState<Set<CloseType>>(new Set());
  const [loading, setLoading] = useState(true);
  const [savingType, setSavingType] = useState<CloseType | null>(null);
  const [savedType, setSavedType] = useState<CloseType | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("campaign_notify_templates")
        .select("close_type, title, body");
      if (cancelled) return;
      if (err) { setError(err.message); setLoading(false); return; }
      const next = { ...DEFAULT_NOTIFY_TEMPLATE };
      const custom = new Set<CloseType>();
      for (const row of data ?? []) {
        const t = row.close_type as CloseType;
        if (t in next) {
          next[t] = { title: row.title, body: row.body };
          custom.add(t);
        }
      }
      setDrafts(next);
      setCustomized(custom);
      setLoading(false);
    })();
    return () => { cancelled = true; };
  }, []);

  async function save(type: CloseType, template: NotifyTemplate) {
    setSavingType(type); setSavedType(null); setError(null);
    try {
      const { error: err } = await getSupabase().rpc("rpc_upsert_campaign_notify_template", {
        p_close_type: type,
        p_title: template.title,
        p_body: template.body,
      });
      if (err) throw err;
      const isReset = !template.title.trim() && !template.body.trim();
      setCustomized((prev) => {
        const next = new Set(prev);
        if (isReset) next.delete(type); else next.add(type);
        return next;
      });
      if (isReset) {
        setDrafts((prev) => ({ ...prev, [type]: DEFAULT_NOTIFY_TEMPLATE[type] }));
      }
      setSavedType(type);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSavingType(null);
    }
  }

  return (
    <div className="mx-auto max-w-3xl space-y-4 p-4">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-100">上架通知文本</h1>
          <p className="mt-0.5 text-xs text-zinc-500 dark:text-zinc-400">
            依收單類型各一版；開團設定裡開啟「上架通知」或美食列車開團即時廣播時套用。
          </p>
        </div>
        <Link href="/campaigns" className="text-sm text-blue-600 hover:underline dark:text-blue-400">
          ← 回開團列表
        </Link>
      </div>

      <div className="rounded-md border border-zinc-200 bg-zinc-50 px-3 py-2 text-xs text-zinc-600 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-300">
        可用佔位符：{NOTIFY_PLACEHOLDERS.map((p) => (
          <code key={p} className="mx-1 rounded bg-zinc-200 px-1 py-0.5 font-mono text-[11px] dark:bg-zinc-700">{p}</code>
        ))}
        ，發送時自動代入該團資料（收單時間為台北時區 月/日 時:分）。
        標題與內文都清空後儲存＝恢復內建預設。
      </div>

      {error && (
        <div className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">{error}</div>
      )}
      {role !== null && !admin && (
        <p className="text-xs text-zinc-500">僅管理員可編輯通知文本（目前唯讀）。</p>
      )}

      {loading ? (
        <p className="text-sm text-zinc-500">載入中…</p>
      ) : (
        TYPES.map(({ value, label, hint }) => (
          <TemplateEditor
            key={value}
            type={value}
            label={label}
            hint={hint}
            template={drafts[value]}
            isCustomized={customized.has(value)}
            readOnly={!admin}
            saving={savingType === value}
            saved={savedType === value}
            onChange={(t) => { setDrafts((prev) => ({ ...prev, [value]: t })); setSavedType(null); }}
            onSave={() => save(value, drafts[value])}
            onReset={() => save(value, { title: "", body: "" })}
          />
        ))
      )}
    </div>
  );
}

function TemplateEditor({
  type, label, hint, template, isCustomized, readOnly, saving, saved, onChange, onSave, onReset,
}: {
  type: CloseType;
  label: string;
  hint?: string;
  template: NotifyTemplate;
  isCustomized: boolean;
  readOnly: boolean;
  saving: boolean;
  saved: boolean;
  onChange: (t: NotifyTemplate) => void;
  onSave: () => void;
  onReset: () => void;
}) {
  const preview = useMemo(
    () => ({
      title: renderNotifyText(template.title || DEFAULT_NOTIFY_TEMPLATE[type].title, PREVIEW_SAMPLE),
      body: renderNotifyText(template.body || DEFAULT_NOTIFY_TEMPLATE[type].body, PREVIEW_SAMPLE),
    }),
    [template, type],
  );

  return (
    <section className="space-y-3 rounded-md border border-zinc-200 p-4 dark:border-zinc-700">
      <div className="flex items-center gap-2">
        <h2 className="text-sm font-semibold text-zinc-800 dark:text-zinc-100">{label}</h2>
        <span className={`rounded-full px-2 py-0.5 text-[11px] ${
          isCustomized
            ? "bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300"
            : "bg-zinc-100 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-400"
        }`}>
          {isCustomized ? "已自訂" : "內建預設"}
        </span>
      </div>
      {hint && <p className="text-[11px] text-zinc-500 dark:text-zinc-400">{hint}</p>}

      <label className="flex flex-col gap-1 text-sm">
        <span className="text-zinc-600 dark:text-zinc-400">標題</span>
        <input
          type="text"
          value={template.title}
          maxLength={100}
          disabled={readOnly}
          onChange={(e) => onChange({ ...template, title: e.target.value })}
          className={inputCls}
        />
      </label>
      <label className="flex flex-col gap-1 text-sm">
        <span className="text-zinc-600 dark:text-zinc-400">內文</span>
        <textarea
          value={template.body}
          rows={3}
          maxLength={500}
          disabled={readOnly}
          onChange={(e) => onChange({ ...template, body: e.target.value })}
          className={inputCls}
        />
      </label>

      <div className="rounded-md bg-zinc-50 px-3 py-2 text-xs dark:bg-zinc-900">
        <span className="text-zinc-400">預覽：</span>
        <span className="font-medium text-zinc-800 dark:text-zinc-100">{preview.title}</span>
        {preview.body && <span className="text-zinc-600 dark:text-zinc-300">｜{preview.body}</span>}
      </div>

      {!readOnly && (
        <div className="flex items-center gap-2">
          <SpinButton
            type="button"
            disabled={saving}
            onClick={onSave}
            className="rounded-md bg-zinc-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
          >
            {saving ? "儲存中…" : "儲存"}
          </SpinButton>
          {isCustomized && (
            <SpinButton
              type="button"
              disabled={saving}
              onClick={onReset}
              className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              恢復預設
            </SpinButton>
          )}
          {saved && <span className="text-xs text-emerald-600 dark:text-emerald-400">已儲存 ✓</span>}
        </div>
      )}
    </section>
  );
}

const inputCls =
  "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none disabled:bg-zinc-50 disabled:text-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:disabled:bg-zinc-900";
