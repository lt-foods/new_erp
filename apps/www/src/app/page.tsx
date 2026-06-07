import {
  BRAND_NAME,
  TAGLINE,
  SUB_TAGLINE,
  ANNUAL_NOTE,
  PLANS,
  FEATURES,
  PAINS,
  FAQS,
  CONTACT,
  type Plan,
} from "@/lib/site";
import { Nav } from "@/components/Nav";
import { Footer } from "@/components/Footer";

function nf(n: number) {
  return n.toLocaleString("zh-TW");
}

function Hero() {
  return (
    <section id="top" className="relative overflow-hidden">
      <div className="pointer-events-none absolute inset-0 -z-10 bg-[radial-gradient(60%_60%_at_50%_0%,#fff7ed_0%,transparent_70%)]" />
      <div className="mx-auto max-w-6xl px-5 py-20 text-center md:py-28">
        <span className="inline-block rounded-full border border-brand/30 bg-brand/5 px-4 py-1.5 text-sm font-semibold text-brand-dark">
          團購店與加盟總部專用 ERP
        </span>
        <h1 className="mx-auto mt-6 max-w-3xl text-4xl font-extrabold leading-tight tracking-tight md:text-6xl">
          {TAGLINE}。
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg text-muted md:text-xl">
          {BRAND_NAME} 把開團接龍、撿貨派貨、庫存採購、會員 App、多店統管與對帳發票
          串成一條龍。{SUB_TAGLINE}。
        </p>
        <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <a
            href={CONTACT.trialUrl}
            className="w-full rounded-full bg-brand px-7 py-3.5 text-base font-bold text-white shadow-md transition hover:bg-brand-dark sm:w-auto"
          >
            免費試用 14 天・免綁卡
          </a>
          <a
            href={CONTACT.demoUrl}
            className="w-full rounded-full border border-border bg-background px-7 py-3.5 text-base font-bold text-foreground transition hover:bg-surface sm:w-auto"
          >
            預約 15 分鐘 Demo
          </a>
        </div>
        <TrustBadges />
      </div>
    </section>
  );
}

const TRUST = ["免費開始", "免設定費", "免成交手續費", "免綁卡", "隨時取消"];

function TrustBadges() {
  return (
    <div className="mt-6 flex flex-wrap items-center justify-center gap-x-5 gap-y-2 text-sm text-muted">
      {TRUST.map((t) => (
        <span key={t} className="inline-flex items-center gap-1.5">
          <span className="text-brand">✓</span>
          {t}
        </span>
      ))}
    </div>
  );
}

function Pains() {
  return (
    <section className="bg-surface py-20">
      <div className="mx-auto max-w-5xl px-5">
        <h2 className="text-center text-3xl font-extrabold tracking-tight md:text-4xl">
          團購生意的痛，系統幫你扛
        </h2>
        <div className="mt-12 grid gap-4">
          {PAINS.map((p) => (
            <div
              key={p.problem}
              className="grid items-center gap-3 rounded-2xl border bg-background p-5 sm:grid-cols-[1fr_auto_1fr]"
            >
              <div className="text-muted">
                <span className="mr-2">😩</span>
                {p.problem}
              </div>
              <div className="hidden text-brand sm:block">→</div>
              <div className="font-semibold">
                <span className="mr-2">✅</span>
                {p.solution}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Features() {
  return (
    <section id="features" className="py-20">
      <div className="mx-auto max-w-6xl px-5">
        <h2 className="text-center text-3xl font-extrabold tracking-tight md:text-4xl">
          一個系統，全包整條團購鏈
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-center text-muted">
          從開團到對帳，每一步都不用切換工具、不用手動搬資料。
        </p>
        <div className="mt-12 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {FEATURES.map((f) => (
            <div
              key={f.title}
              className="rounded-2xl border bg-background p-6 transition hover:shadow-md"
            >
              <div className="text-3xl">{f.icon}</div>
              <h3 className="mt-4 text-lg font-bold">{f.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted">{f.desc}</p>
            </div>
          ))}
        </div>
        <div className="mt-10 text-center">
          <a
            href="/features/"
            className="inline-block rounded-full border border-border px-6 py-3 text-sm font-bold transition hover:bg-surface"
          >
            深入了解每個功能 →
          </a>
        </div>
      </div>
    </section>
  );
}

const FRANCHISE_POINTS = [
  { t: "多店總部統管", d: "一個後台俯瞰全體門市營運" },
  { t: "跨店調撥", d: "A 店缺、B 店多，系統內直接調" },
  { t: "加盟拆帳", d: "總部與門市帳目自動分清楚" },
  { t: "進銷存後台", d: "採購、庫存 SSOT、應付帳款全打通" },
];

function Franchise() {
  return (
    <section className="py-20">
      <div className="mx-auto max-w-6xl px-5">
        <div className="overflow-hidden rounded-3xl bg-foreground text-background">
          <div className="grid gap-10 p-10 md:grid-cols-2 md:p-14">
            <div>
              <span className="inline-block rounded-full bg-brand/20 px-4 py-1.5 text-sm font-semibold text-brand">
                不只是整單工具
              </span>
              <h2 className="mt-5 text-3xl font-extrabold tracking-tight md:text-4xl">
                開分店、做加盟？<br />一個後台管 100 家門市
              </h2>
              <p className="mt-5 leading-relaxed opacity-80">
                只能整單的工具，生意一做大、想開第二家店或跑加盟就撞牆。揪好團原生支援
                多店與加盟總部——後端多租戶、列級安全隔離，總部俯瞰全局、門市各看各的。
                這是團做大之後，整單工具給不了的後台。
              </p>
              <a
                href="/features/franchise/"
                className="mt-7 inline-block rounded-full bg-brand px-6 py-3 text-sm font-bold text-white transition hover:bg-brand-dark"
              >
                看加盟總部方案 →
              </a>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              {FRANCHISE_POINTS.map((p) => (
                <div key={p.t} className="rounded-2xl bg-white/5 p-5 ring-1 ring-white/10">
                  <div className="font-bold">{p.t}</div>
                  <div className="mt-1.5 text-sm opacity-75">{p.d}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function PriceTag({ plan }: { plan: Plan }) {
  if (plan.monthly == null) {
    return (
      <div className="mt-5">
        <div className="text-3xl font-extrabold">客製報價</div>
        <div className="mt-1 text-sm text-muted">依門市規模與需求</div>
      </div>
    );
  }
  if (plan.monthly === 0) {
    return (
      <div className="mt-5">
        <div className="text-4xl font-extrabold">免費</div>
        <div className="mt-1 text-sm text-muted">NT$0／月・不限時間</div>
      </div>
    );
  }
  // 年繳 = 月費 × 10，故年省 = 月費 × 2
  const saved = plan.yearly != null ? plan.monthly * 12 - plan.yearly : 0;
  return (
    <div className="mt-5">
      <div className="flex items-baseline gap-1">
        <span className="text-sm font-semibold text-muted">NT$</span>
        <span className="text-4xl font-extrabold">{nf(plan.monthly)}</span>
        <span className="text-sm text-muted">/月</span>
      </div>
      {plan.yearly != null && (
        <div className="mt-1 text-sm text-muted">
          年繳 NT${nf(plan.yearly)}
          {saved > 0 && (
            <span className="ml-1 font-semibold text-brand-dark">
              年省 NT${nf(saved)}
            </span>
          )}
        </div>
      )}
    </div>
  );
}

function Pricing() {
  return (
    <section id="pricing" className="bg-surface py-20">
      <div className="mx-auto max-w-7xl px-5">
        <h2 className="text-center text-3xl font-extrabold tracking-tight md:text-4xl">
          從免費版到加盟總部，都有方案
        </h2>
        <p className="mx-auto mt-4 max-w-2xl text-center text-muted">
          免費開始，月租制可年繳・{ANNUAL_NOTE}。隨生意成長無痛升級。
        </p>
        <div className="mt-12 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
          {PLANS.map((plan) => (
            <div
              key={plan.id}
              className={`relative flex flex-col rounded-3xl border bg-background p-5 ${
                plan.highlight ? "border-brand shadow-lg ring-1 ring-brand/30" : ""
              }`}
            >
              {plan.badge && (
                <span className="absolute -top-3 left-1/2 -translate-x-1/2 rounded-full bg-brand px-3 py-1 text-xs font-bold text-white">
                  {plan.badge}
                </span>
              )}
              <h3 className="text-lg font-bold">{plan.name}</h3>
              <p className="mt-1 text-sm text-muted">{plan.audience}</p>
              <PriceTag plan={plan} />

              <ul className="mt-5 space-y-1.5 border-t pt-5 text-sm text-muted">
                {plan.limits.map((l) => (
                  <li key={l}>· {l}</li>
                ))}
              </ul>
              <ul className="mt-4 space-y-2 text-sm">
                {plan.features.map((f) => (
                  <li key={f} className="flex gap-2">
                    <span className="text-brand">✓</span>
                    <span>{f}</span>
                  </li>
                ))}
              </ul>

              <a
                href={plan.monthly == null ? CONTACT.demoUrl : CONTACT.trialUrl}
                className={`mt-6 rounded-full px-5 py-3 text-center text-sm font-bold transition ${
                  plan.highlight
                    ? "bg-brand text-white hover:bg-brand-dark"
                    : "border border-border hover:bg-surface"
                }`}
              >
                {plan.cta}
              </a>
            </div>
          ))}
        </div>
        <TrustBadges />
        <p className="mt-6 text-center text-sm text-muted">
          所有方案均為新台幣未稅・另有導入輔導、資料搬遷、白標等加購服務。
        </p>
      </div>
    </section>
  );
}

function Faq() {
  return (
    <section id="faq" className="py-20">
      <div className="mx-auto max-w-3xl px-5">
        <h2 className="text-center text-3xl font-extrabold tracking-tight md:text-4xl">
          常見問題
        </h2>
        <div className="mt-10 divide-y rounded-2xl border bg-background">
          {FAQS.map((f) => (
            <details key={f.q} className="group p-5">
              <summary className="flex cursor-pointer list-none items-center justify-between font-semibold">
                {f.q}
                <span className="text-brand transition group-open:rotate-45">＋</span>
              </summary>
              <p className="mt-3 text-sm leading-relaxed text-muted">{f.a}</p>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}

function FinalCta() {
  return (
    <section id="trial" className="bg-brand py-20 text-white">
      <div className="mx-auto max-w-3xl px-5 text-center">
        <h2 className="text-3xl font-extrabold tracking-tight md:text-4xl">
          少請一個人，多賺一整團
        </h2>
        <p className="mt-4 text-white/90">
          免費試用 14 天，免綁卡。把開團到對帳交給 {BRAND_NAME}。
        </p>
        <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
          <a
            href={CONTACT.trialUrl}
            className="w-full rounded-full bg-white px-7 py-3.5 text-base font-bold text-brand-dark shadow-md transition hover:bg-white/90 sm:w-auto"
          >
            立即免費試用
          </a>
          <a
            href={`mailto:${CONTACT.email}`}
            className="w-full rounded-full border border-white/40 px-7 py-3.5 text-base font-bold text-white transition hover:bg-white/10 sm:w-auto"
          >
            聯絡我們
          </a>
        </div>
      </div>
    </section>
  );
}

export default function Home() {
  return (
    <>
      <Nav />
      <main>
        <Hero />
        <Pains />
        <Features />
        <Franchise />
        <Pricing />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
    </>
  );
}
