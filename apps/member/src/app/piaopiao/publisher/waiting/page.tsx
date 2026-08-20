import Link from "next/link";

export default function PiaopiaoPublisherWaitingPage() {
  return <main className="mx-auto flex min-h-[100dvh] max-w-md items-center px-6"><div className="w-full rounded-3xl bg-white p-7 text-center shadow-xl"><div className="text-5xl">⏳</div><h1 className="mt-4 text-2xl font-bold">等待總部開通</h1><p className="mt-3 leading-7 text-zinc-600">LINE 身分已送出。總部開通後，回到此網址重新用 LINE 登入即可。</p><Link href="/piaopiao/publisher" className="mt-6 inline-block rounded-xl bg-rose-500 px-5 py-3 font-semibold text-white">回登入頁</Link></div></main>;
}
