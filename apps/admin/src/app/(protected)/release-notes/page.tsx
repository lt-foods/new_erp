import Link from "next/link";
import { withBasePath } from "@/lib/basePath";
import {
  TAG_COLOR,
  TAG_LABEL,
  notesBy,
  countByMenu,
  type ReleaseNote,
  type ReleaseMedia,
} from "@/lib/releaseNotes";
import { MENU_GROUPS, MENU_ITEMS } from "@/lib/menuSections";

function MediaBlock({ m }: { m: ReleaseMedia }) {
  return (
    <figure className="mt-3">
      {m.src.endsWith(".mp4") ? (
        // 影片教學：手機相容性優於大型 GIF。靜態匯出有 basePath，src/poster 需手動加前綴。
        <video
          src={withBasePath(m.src)}
          poster={m.poster ? withBasePath(m.poster) : undefined}
          autoPlay
          loop
          muted
          playsInline
          controls
          aria-label={m.alt}
          className="w-full rounded-lg border border-zinc-200 shadow-sm dark:border-zinc-800"
        />
      ) : (
        // eslint-disable-next-line @next/next/no-img-element
        <img
          src={withBasePath(m.src)}
          alt={m.alt}
          className="w-full rounded-lg border border-zinc-200 shadow-sm dark:border-zinc-800"
        />
      )}
      {m.caption && (
        <figcaption className="mt-2 text-center text-xs text-zinc-500 dark:text-zinc-400">
          {m.caption}
        </figcaption>
      )}
    </figure>
  );
}

function NoteCard({ note }: { note: ReleaseNote }) {
  return (
    <div className="rounded-lg border border-zinc-200 bg-white p-4 shadow-sm dark:border-zinc-800 dark:bg-zinc-900">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h4 className="text-sm font-semibold">{note.title}</h4>
        <span className="font-mono text-[11px] text-zinc-400 dark:text-zinc-500">{note.date}</span>
      </div>
      <ul className="mt-2 space-y-1.5">
        {note.items.map((it, j) => (
          <li key={j} className="flex items-start gap-2 text-sm text-zinc-600 dark:text-zinc-300">
            <span
              className={`mt-0.5 inline-flex shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${TAG_COLOR[it.tag]}`}
            >
              {TAG_LABEL[it.tag]}
            </span>
            <span className="leading-relaxed">{it.text}</span>
          </li>
        ))}
      </ul>
      {note.media?.map((m, k) => <MediaBlock key={k} m={m} />)}
    </div>
  );
}

export default function ReleaseNotesPage() {
  const tutCounts = countByMenu("tutorial");
  const updCounts = countByMenu("update");

  return (
    <div className="mx-auto w-full max-w-6xl px-4 py-6 sm:py-8">
      <div className="mb-5 flex items-center justify-between gap-3">
        <h1 className="text-xl font-semibold tracking-tight">教學與更新</h1>
        <Link
          href="/"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-700 transition hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
        >
          返回首頁
        </Link>
      </div>

      {/* 兩大區快速跳轉 */}
      <div className="mb-8 flex gap-2 text-sm">
        <a href="#tutorials" className="rounded-full bg-violet-100 px-3 py-1 font-medium text-violet-700 dark:bg-violet-900/30 dark:text-violet-300">📚 教學影片</a>
        <a href="#updates" className="rounded-full bg-sky-100 px-3 py-1 font-medium text-sky-700 dark:bg-sky-900/30 dark:text-sky-300">✨ 優化更新</a>
      </div>

      {/* ================= 教學影片 ================= */}
      <section id="tutorials" className="scroll-mt-6">
        <h2 className="flex items-center gap-2 border-b border-zinc-200 pb-2 text-lg font-semibold dark:border-zinc-800">
          📚 教學影片
          <span className="text-xs font-normal text-zinc-400">依功能分類，方便依你用到的功能查看</span>
        </h2>

        {/* 功能索引（只顯示有影片的） */}
        <div className="mt-3 flex flex-wrap gap-1.5">
          {MENU_ITEMS.filter((m) => (tutCounts[m.key] ?? 0) > 0).map((m) => {
            const c = tutCounts[m.key] ?? 0;
            return (
              <a
                key={m.key}
                href={`#tut-${m.key}`}
                className="rounded-full bg-zinc-900 px-2.5 py-1 text-xs font-medium text-white dark:bg-zinc-100 dark:text-zinc-900"
              >
                {m.label} {c}
              </a>
            );
          })}
        </div>

        {/* 依 NAV 群組 → 個別功能（只顯示有影片的） */}
        <div className="mt-6 space-y-8">
          {MENU_GROUPS.map((g, gi) => {
            const items = g.items.filter((it) => (tutCounts[it.key] ?? 0) > 0);
            if (items.length === 0) return null;
            return (
              <div key={gi}>
                {g.group && (
                  <div className="mb-3 text-xs font-semibold tracking-wider text-zinc-400 dark:text-zinc-500">
                    {g.group}
                  </div>
                )}
                <div className="space-y-5">
                  {items.map((item) => (
                    <div key={item.key} id={`tut-${item.key}`} className="scroll-mt-6">
                      <h3 className="mb-2 text-sm font-semibold text-zinc-800 dark:text-zinc-200">
                        {item.label}
                      </h3>
                      <div className="space-y-3">
                        {notesBy("tutorial", item.key).map((n) => <NoteCard key={n.id} note={n} />)}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </section>

      {/* ================= 優化更新 ================= */}
      <section id="updates" className="mt-12 scroll-mt-6">
        <h2 className="flex items-center gap-2 border-b border-zinc-200 pb-2 text-lg font-semibold dark:border-zinc-800">
          ✨ 優化更新
          <span className="text-xs font-normal text-zinc-400">新功能 / 優化 / 修正，依功能分類</span>
        </h2>

        <div className="mt-6 space-y-8">
          {MENU_GROUPS.map((g, gi) => {
            // 只顯示該群組中「有更新」的功能；整組都沒有就略過
            const items = g.items.filter((it) => (updCounts[it.key] ?? 0) > 0);
            if (items.length === 0) return null;
            return (
              <div key={gi}>
                {g.group && (
                  <div className="mb-3 text-xs font-semibold tracking-wider text-zinc-400 dark:text-zinc-500">
                    {g.group}
                  </div>
                )}
                <div className="space-y-5">
                  {items.map((item) => (
                    <div key={item.key} id={`upd-${item.key}`} className="scroll-mt-6">
                      <h3 className="mb-2 text-sm font-semibold text-zinc-800 dark:text-zinc-200">
                        {item.label}
                      </h3>
                      <div className="space-y-3">
                        {notesBy("update", item.key).map((n) => <NoteCard key={n.id} note={n} />)}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            );
          })}
        </div>
      </section>
    </div>
  );
}
