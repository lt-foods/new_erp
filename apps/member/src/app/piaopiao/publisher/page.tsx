"use client";

import { useEffect, useMemo, useState } from "react";
import { campaignShareUrl, sharePage } from "@/lib/shareLink";
import { getPiaopiaoAuth, piaopiaoLoginEmail } from "@/lib/piaopiaoAuth";

type Variant = { name: string; cost_price: string; branch_price: string; retail_price: string };
type Product = { name: string; description: string; images: File[]; variants: Variant[]; supplier_id: string; supplier_name: string };
type Supplier = { id: number; name: string };
type Result = { campaign_id: number; campaign_no: string; name: string; cover_image_path?: string };
type PublishedResult = Result & { url: string; image?: File };

const emptyProduct = (): Product => ({
  name: "", description: "", images: [],
  variants: [{ name: "單一規格", cost_price: "", branch_price: "", retail_price: "" }],
  supplier_id: "", supplier_name: "",
});
const REQUEST_KEY = "piaopiao_pending_request_id";

export default function PiaopiaoPublisherPage() {
  const [token, setToken] = useState("");
  const [loginId, setLoginId] = useState("");
  const [password, setPassword] = useState("");
  const [lane, setLane] = useState<"tong" | "chao" | null>(null);
  const [supplierList, setSupplierList] = useState<Supplier[]>([]);
  const [products, setProducts] = useState<Product[]>([emptyProduct()]);
  const [endAt, setEndAt] = useState("");
  const [pickupDeadline, setPickupDeadline] = useState("");
  const [error, setError] = useState("");
  const [shareNotice, setShareNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<PublishedResult[]>([]);

  useEffect(() => {
    const auth = getPiaopiaoAuth();
    void auth.auth.getSession().then(({ data }) => setToken(data.session?.access_token ?? ""));
    const { data } = auth.auth.onAuthStateChange((_event, session) => setToken(session?.access_token ?? ""));
    return () => data.subscription.unsubscribe();
  }, []);

  useEffect(() => {
    if (!token) return;
    void api(token, { action: "bootstrap" }).then((r) => {
      setLane(r.publisher.lane);
      setSupplierList(r.suppliers ?? []);
    }).catch((e) => {
      setToken("");
      setError(e instanceof Error ? e.message : "登入已失效");
    });
  }, [token]);

  const heading = lane === "chao" ? "漂漂潮上架" : lane === "tong" ? "漂漂彤上架" : "漂漂館上架";
  const canAdd = products.length < 5;
  const publishLabel = useMemo(() => `建立 ${products.length} 個商品團`, [products.length]);

  function updateProduct(index: number, patch: Partial<Product>) {
    setProducts((all) => all.map((item, i) => i === index ? { ...item, ...patch } : item));
  }
  function updateVariant(productIndex: number, variantIndex: number, patch: Partial<Variant>) {
    setProducts((all) => all.map((product, i) => i !== productIndex ? product : {
      ...product,
      variants: product.variants.map((variant, j) => j === variantIndex ? { ...variant, ...patch } : variant),
    }));
  }
  function addVariant(productIndex: number) {
    setProducts((all) => all.map((product, i) => i === productIndex ? {
      ...product,
      variants: [...product.variants, { name: "", cost_price: "", branch_price: "", retail_price: "" }],
    } : product));
  }
  function removeVariant(productIndex: number, variantIndex: number) {
    setProducts((all) => all.map((product, i) => i === productIndex ? {
      ...product, variants: product.variants.filter((_, j) => j !== variantIndex),
    } : product));
  }

  async function submit() {
    setError(""); setShareNotice("");
    if (!token || !lane || busy) return;
    if (!endAt || !pickupDeadline) return setError("請先填收單時間與取貨日");
    if (new Date(endAt).getTime() <= Date.now()) return setError("收單時間必須晚於現在");
    if (pickupDeadline < endAt.slice(0, 10)) return setError("取貨日不可早於收單日");
    for (const [i, product] of products.entries()) {
      if (!product.name.trim() || !product.description.trim() || product.images.length === 0) return setError(`第 ${i + 1} 樣商品請填名稱、介紹並至少上傳一張圖`);
      if (lane === "tong" && !product.supplier_id && !product.supplier_name.trim()) return setError(`第 ${i + 1} 樣商品請選擇或填寫供應商`);
      if (product.variants.length === 0 || product.variants.some((v) => !validVariant(v))) return setError(`第 ${i + 1} 樣商品的每個規格都要填成本、分店價、售價，且成本 ≤ 分店價 < 售價`);
    }
    setBusy(true);
    try {
      const uploaded: Array<Record<string, unknown>> = [];
      for (const product of products) {
        const images: string[] = [];
        for (const file of product.images) {
          const uploadedImage = await api(token, { action: "upload_image", mime: file.type, base64: await fileToBase64(file) });
          images.push(uploadedImage.path);
        }
        uploaded.push({
          name: product.name.trim(), description: product.description.trim(), images,
          variants: product.variants.map((v) => ({ ...v, name: v.name.trim() })),
          ...(lane === "tong" ? (product.supplier_id ? { supplier_id: product.supplier_id } : { supplier_name: product.supplier_name.trim() }) : {}),
        });
      }
      const requestId = localStorage.getItem(REQUEST_KEY) || crypto.randomUUID();
      localStorage.setItem(REQUEST_KEY, requestId);
      const response = await api(token, {
        action: "publish", request_id: requestId,
        end_at: new Date(endAt).toISOString(), pickup_deadline: pickupDeadline, items: uploaded,
      });
      setResults((response.campaigns ?? []).map((campaign: Result, index: number) => ({
        ...campaign,
        url: campaignShareUrl(Number(campaign.campaign_id), "/piaopiao/c"),
        image: response.reused ? undefined : products[index]?.images[0],
      })));
      localStorage.removeItem(REQUEST_KEY);
    } catch (e) {
      setError(e instanceof Error ? e.message : "建立失敗；沒有建立半套商品，請確認後再試");
    } finally {
      setBusy(false);
    }
  }

  async function share(result: PublishedResult) {
    setError(""); setShareNotice("");
    const image = result.image ?? await imageFromPath(result.cover_image_path);
    const outcome = await sharePage({
      title: result.name,
      text: `${result.name}｜漂漂館・立即下單`,
      url: result.url,
      files: image ? [image] : undefined,
    });
    if (outcome === "cancelled") return;
    if (outcome === "shared_native_with_file") {
      setShareNotice("已開啟分享；請在 LINE 選要分享的群組，商品圖和下單連結會一起帶入。");
    } else if (["shared_native", "shared_in_line", "opened_line"].includes(outcome)) {
      setShareNotice("已開啟 LINE 分享；請自行選群組。此裝置不支援自動帶圖時，請在 LINE 補選第一張商品圖。");
    } else if (outcome === "copied") {
      setShareNotice("連結已複製，請自行貼到 LINE 群組；此裝置不支援自動帶圖。");
    } else {
      setError("這台裝置無法開啟分享，請複製下方連結後自行貼到 LINE 群組。");
    }
  }

  async function login() {
    setError("");
    if (!loginId.trim() || !password) return setError("請輸入上架帳號與密碼");
    const { error: loginError } = await getPiaopiaoAuth().auth.signInWithPassword({ email: piaopiaoLoginEmail(loginId), password });
    if (loginError) setError("帳號或密碼不正確，或此帳號已停用");
  }

  if (!token) return <main className="mx-auto flex min-h-[100dvh] max-w-md items-center px-6"><div className="w-full rounded-3xl bg-white p-7 text-center shadow-xl"><div className="text-5xl">🛍️</div><h1 className="mt-4 text-2xl font-bold">漂漂館上架後台</h1><p className="mt-3 leading-7 text-zinc-600">使用總部發給你的漂漂館上架帳號。這不是 ERP 帳號，也不綁私人 LINE。</p>{error && <p className="mt-4 text-sm text-red-600">{error}</p>}<input className="input mt-5" autoComplete="username" placeholder="上架帳號，例如 piao.tong" value={loginId} onChange={(e) => setLoginId(e.target.value)} /><input className="input mt-3" autoComplete="current-password" type="password" placeholder="密碼" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") void login(); }} /><button onClick={() => void login()} className="mt-4 min-h-11 w-full rounded-xl bg-rose-600 px-4 text-base font-semibold text-white">登入上架後台</button></div></main>;

  return <main className="mx-auto min-h-[100dvh] max-w-3xl bg-zinc-50 px-4 py-6 text-zinc-900"><header className="mb-5 rounded-3xl bg-gradient-to-br from-rose-500 to-rose-700 px-6 py-6 text-white shadow-lg"><div className="flex items-start justify-between gap-3"><div><p className="text-sm opacity-90">漂漂館專屬・不會上到主商城首頁</p><h1 className="mt-1 text-3xl font-bold">{heading}</h1><p className="mt-2 text-sm leading-6 opacity-90">一次建立 1～5 樣商品；每樣都是獨立下單連結。建立後由你自己按分享、自己選 LINE 群組。</p></div><button onClick={() => void getPiaopiaoAuth().auth.signOut()} className="min-h-11 shrink-0 rounded-lg border border-white/50 px-3 text-sm font-semibold">登出</button></div></header>
    {error && <p className="mb-4 rounded-xl bg-red-50 p-3 text-red-700">{error}</p>}{shareNotice && <p className="mb-4 rounded-xl bg-emerald-50 p-3 text-emerald-800">{shareNotice}</p>}
    {results.length > 0 ? <section className="rounded-3xl bg-white p-5 shadow-sm"><h2 className="text-xl font-bold">建立完成，請逐一分享</h2><p className="mt-2 text-sm text-zinc-600">按每一樣商品的分享鈕，再由 LINE 選群組。支援的手機／電腦會帶入商品圖和連結。</p><div className="mt-4 space-y-3">{results.map((result) => <div key={result.campaign_id} className="rounded-2xl border p-4"><p className="font-semibold">{result.name}</p><a className="mt-1 block break-all text-rose-700 underline" href={result.url} target="_blank" rel="noreferrer">{result.url}</a><button onClick={() => void share(result)} className="mt-3 min-h-11 rounded-lg bg-[#06C755] px-4 text-sm font-semibold text-white">分享至 LINE 群組</button></div>)}</div><button onClick={() => { setResults([]); setProducts([emptyProduct()]); }} className="mt-5 min-h-11 rounded-xl bg-rose-600 px-4 font-semibold text-white">再建立一批</button></section> : <>
      <section className="rounded-3xl bg-white p-5 shadow-sm"><h2 className="text-lg font-bold">共同資料</h2><div className="mt-4 grid gap-4 sm:grid-cols-2"><Field label="收單時間"><input className="input" type="datetime-local" value={endAt} onChange={(e) => setEndAt(e.target.value)} /></Field><Field label="取貨日"><input className="input" type="date" value={pickupDeadline} onChange={(e) => setPickupDeadline(e.target.value)} /></Field></div></section>
      <div className="mt-4 space-y-4">{products.map((product, index) => <section key={index} className="rounded-3xl bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><h2 className="text-lg font-bold">商品 {index + 1}</h2>{products.length > 1 && <button onClick={() => setProducts((all) => all.filter((_, i) => i !== index))} className="min-h-11 text-sm text-red-600">移除此商品</button>}</div><div className="mt-4 grid gap-4"><Field label="商品名稱"><input className="input" value={product.name} onChange={(e) => updateProduct(index, { name: e.target.value })} /></Field><Field label="商品介紹"><textarea className="input min-h-28" value={product.description} onChange={(e) => updateProduct(index, { description: e.target.value })} /></Field><Field label="商品圖片（至少一張）"><input className="block min-h-11 w-full text-base" type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(e) => updateProduct(index, { images: Array.from(e.target.files ?? []) })} />{product.images.length > 0 && <p className="text-sm text-emerald-700">已選 {product.images.length} 張圖片</p>}</Field>{lane === "tong" && <Field label="供應商"><select className="input" value={product.supplier_id} onChange={(e) => updateProduct(index, { supplier_id: e.target.value })}><option value="">新增供應商（填在下一格）</option>{supplierList.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</select>{!product.supplier_id && <input className="input mt-2" placeholder="新供應商名稱" value={product.supplier_name} onChange={(e) => updateProduct(index, { supplier_name: e.target.value })} />}</Field>}{lane === "chao" && <p className="rounded-xl bg-zinc-100 p-3 text-sm">供應商固定：潮包子</p>}</div><h3 className="mt-6 font-bold">規格與價格</h3><div className="mt-2 space-y-3">{product.variants.map((variant, variantIndex) => <div key={variantIndex} className="rounded-2xl bg-zinc-50 p-3"><div className="grid gap-2 sm:grid-cols-4"><input className="input" placeholder="規格名，例如 黑色 M" value={variant.name} onChange={(e) => updateVariant(index, variantIndex, { name: e.target.value })} /><input className="input" inputMode="decimal" placeholder="成本價" value={variant.cost_price} onChange={(e) => updateVariant(index, variantIndex, { cost_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="分店價" value={variant.branch_price} onChange={(e) => updateVariant(index, variantIndex, { branch_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="售價" value={variant.retail_price} onChange={(e) => updateVariant(index, variantIndex, { retail_price: e.target.value })} /></div>{product.variants.length > 1 && <button onClick={() => removeVariant(index, variantIndex)} className="mt-2 text-sm text-red-600">刪除此規格</button>}</div>)}</div><button onClick={() => addVariant(index)} className="mt-3 min-h-11 rounded-xl border px-3 text-sm font-semibold">＋ 新增規格</button></section>)}</div>
      {canAdd && <button onClick={() => setProducts((all) => [...all, emptyProduct()])} className="mt-4 min-h-11 rounded-xl border border-rose-300 bg-white px-4 font-semibold text-rose-700">＋ 再加一樣商品（最多 5 樣）</button>}<button disabled={busy} onClick={() => void submit()} className="mt-6 min-h-14 w-full rounded-2xl bg-rose-600 px-5 text-lg font-bold text-white disabled:opacity-50">{busy ? "正在建立，請不要關閉…" : publishLabel}</button>
    </>}</main>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block text-sm font-semibold">{label}<div className="mt-1.5">{children}</div></label>; }
function validVariant(variant: Variant) { const cost = Number(variant.cost_price); const branch = Number(variant.branch_price); const retail = Number(variant.retail_price); return !!variant.name.trim() && Number.isFinite(cost) && Number.isFinite(branch) && Number.isFinite(retail) && cost >= 0 && branch > 0 && retail > 0 && cost <= branch && branch < retail; }
async function api(token: string, body: Record<string, unknown>): Promise<any> { const base = process.env.NEXT_PUBLIC_SUPABASE_URL; if (!base) throw new Error("系統尚未設定連線"); const response = await fetch(`${base}/functions/v1/piaopiao-api`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }); const data = await response.json().catch(() => ({})); if (!response.ok) throw new Error(data.error || `系統錯誤 ${response.status}`); return data; }
async function fileToBase64(file: File) { const buffer = await file.arrayBuffer(); let binary = ""; for (const value of new Uint8Array(buffer)) binary += String.fromCharCode(value); return btoa(binary); }
async function imageFromPath(path?: string): Promise<File | undefined> { try { if (!path) return undefined; const base = process.env.NEXT_PUBLIC_SUPABASE_URL; if (!base) return undefined; const url = `${base}/storage/v1/object/public/products/${path.split("/").map(encodeURIComponent).join("/")}`; const response = await fetch(url); if (!response.ok) return undefined; const blob = await response.blob(); return new File([blob], "piaopiao-product-image", { type: blob.type || "image/jpeg" }); } catch { return undefined; } }
