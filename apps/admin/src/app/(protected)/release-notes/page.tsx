import Link from "next/link";
import {
  RELEASE_NOTES,
  TAG_COLOR,
  TAG_LABEL,
} from "@/lib/releaseNotes";

export default function ReleaseNotesPage() {
  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-6 sm:py-8">
      <div className="mb-6 flex items-center justify-between gap-3">
        <h1 className="flex items-center gap-2 text-xl font-semibold tracking-tight">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="h-5 w-5"
            aria-hidden
          >
            <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
            <path d="M13.73 21a2 2 0 0 1-3.46 0" />
          </svg>
          更新公告
        </h1>
        <Link
          href="/"
          className="rounded-md border border-zinc-300 px-3 py-1.5 text-sm text-zinc-700 transition hover:bg-zinc-100 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-900"
        >
          返回首頁
        </Link>
      </div>

      <div className="space-y-10">
        {RELEASE_NOTES.map((note, i) => (
          <article
            key={note.id}
            id={note.id}
            className="scroll-mt-6 rounded-xl border border-zinc-200 bg-white p-5 shadow-sm dark:border-zinc-800 dark:bg-zinc-900 sm:p-6"
          >
            <header className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
              <h2 className="text-lg font-semibold">
                {note.title}
                {i === 0 && (
                  <span className="ml-2 inline-flex rounded-full bg-rose-100 px-1.5 py-0.5 align-middle text-[11px] font-medium text-rose-700 dark:bg-rose-900/30 dark:text-rose-300">
                    最新
                  </span>
                )}
              </h2>
              <span className="font-mono text-xs text-zinc-400 dark:text-zinc-500">
                {note.date}
              </span>
            </header>

            <ul className="space-y-2.5">
              {note.items.map((it, j) => (
                <li
                  key={j}
                  className="flex items-start gap-2.5 text-sm text-zinc-700 dark:text-zinc-300"
                >
                  <span
                    className={`mt-0.5 inline-flex shrink-0 rounded px-1.5 py-0.5 text-[11px] font-medium ${TAG_COLOR[it.tag]}`}
                  >
                    {TAG_LABEL[it.tag]}
                  </span>
                  <span className="leading-relaxed">{it.text}</span>
                </li>
              ))}
            </ul>

            {note.media?.map((m, k) => (
              <figure key={k} className="mt-5">
                {/* GIF 教學：用原生 img 才能正常播放動畫 */}
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src={m.src}
                  alt={m.alt}
                  className="w-full rounded-lg border border-zinc-200 shadow-sm dark:border-zinc-800"
                />
                {m.caption && (
                  <figcaption className="mt-2 text-center text-xs text-zinc-500 dark:text-zinc-400">
                    {m.caption}
                  </figcaption>
                )}
              </figure>
            ))}
          </article>
        ))}
      </div>
    </div>
  );
}
