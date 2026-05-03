import Link from "next/link";

export type NotificationRow = {
  id: number;
  category: string;
  title: string;
  body: string | null;
  url: string | null;
  read_at: string | null;
  created_at: string;
};

function fmtRelativeTime(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (Number.isNaN(ms) || ms < 0) return "";
  const min = Math.floor(ms / 60000);
  if (min < 1) return "剛剛";
  if (min < 60) return `${min} 分鐘前`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr} 小時前`;
  const d = Math.floor(hr / 24);
  if (d < 7) return `${d} 天前`;
  return new Date(iso).toLocaleDateString("zh-TW");
}

export default function NotificationCard({ n }: { n: NotificationRow }) {
  const unread = !n.read_at;
  const inner = (
    <article className="relative overflow-hidden rounded-2xl bg-[var(--card-bg)] px-4 py-3 shadow-[0_1px_2px_rgba(0,0,0,0.04)]">
      {unread && (
        <span
          className="absolute left-1.5 top-4 h-2 w-2 rounded-full bg-[var(--brand-strong)]"
          aria-hidden
        />
      )}
      <div className="pl-3">
        <div className="flex items-start justify-between gap-2">
          <h3 className="min-w-0 flex-1 truncate text-[16px] font-semibold text-[var(--foreground)]">
            {n.title}
          </h3>
          <span className="flex-shrink-0 text-[12px] text-[var(--tertiary-label)]">
            {fmtRelativeTime(n.created_at)}
          </span>
        </div>
        {n.body && (
          <p className="mt-1 whitespace-pre-line text-[14px] text-[var(--secondary-label)]">
            {n.body}
          </p>
        )}
      </div>
    </article>
  );
  if (n.url) {
    return (
      <Link href={n.url} className="block">
        {inner}
      </Link>
    );
  }
  return inner;
}
