"use client";

import { useEffect, useMemo, useState } from "react";
import { campaignShareUrl, sharePage } from "@/lib/shareLink";
import { getPiaopiaoAuth, piaopiaoLoginEmail } from "@/lib/piaopiaoAuth";

type Variant = { name: string; cost_price: string; branch_price: string; retail_price: string };
type VariantBatch = { colors: string; sizes: string; cost_price: string; branch_price: string; retail_price: string };
type Product = { name: string; description: string; images: File[]; variants: Variant[]; supplier_name: string; variant_batch: VariantBatch };
type Result = { campaign_id: number; campaign_no: string; name: string; cover_image_path?: string };
type PublishedResult = Result & { url: string; description: string; image?: File };
type BootstrapResponse = { publisher: { lane: "tong" | "chao" } };
type UploadImageResponse = { path: string };
type PublishResponse = { campaigns?: Result[]; reused?: boolean };

const emptyProduct = (): Product => ({
  name: "", description: "", images: [],
  variants: [{ name: "單一規格", cost_price: "", branch_price: "", retail_price: "" }],
  supplier_name: "",
  variant_batch: { colors: "", sizes: "", cost_price: "", branch_price: "", retail_price: "" },
});
const REQUEST_KEY = "piaopiao_pending_request_id";
const MAX_BATCH_VARIANTS = 100;
const SUPPLIER_OPTIONS = ["包子媽", "山瀾商行", "NO21", "精品", "599", "Diz.o", "芭斯特", "祥美", "亞諾"];

export default function PiaopiaoPublisherPage() {
  const [token, setToken] = useState("");
  const [loginId, setLoginId] = useState("");
  const [password, setPassword] = useState("");
  const [lane, setLane] = useState<"tong" | "chao" | null>(null);
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
    void api<BootstrapResponse>(token, { action: "bootstrap" }).then((r) => {
      setLane(r.publisher.lane);
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
  function moveProductImage(productIndex: number, imageIndex: number, direction: -1 | 1) {
    setProducts((all) => all.map((product, i) => {
      if (i !== productIndex) return product;
      const nextIndex = imageIndex + direction;
      if (nextIndex < 0 || nextIndex >= product.images.length) return product;
      const images = [...product.images];
      [images[imageIndex], images[nextIndex]] = [images[nextIndex], images[imageIndex]];
      return { ...product, images };
    }));
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
  function removeProduct(productIndex: number) {
    const product = products[productIndex];
    const title = product?.name.trim() || `商品 ${productIndex + 1}`;
    if (!window.confirm(products.length > 1 ? `確定刪除「${title}」？` : "確定清空這個商品？")) return;
    setError("");
    setProducts((all) => all.length > 1 ? all.filter((_, i) => i !== productIndex) : [emptyProduct()]);
  }
  function removeProductImage(productIndex: number, imageIndex: number) {
    setProducts((all) => all.map((product, i) => i === productIndex ? {
      ...product,
      images: product.images.filter((_, j) => j !== imageIndex),
    } : product));
  }
  function updateVariantBatch(productIndex: number, patch: Partial<VariantBatch>) {
    const product = products[productIndex];
    if (!product) return;
    updateProduct(productIndex, { variant_batch: { ...product.variant_batch, ...patch } });
  }
  function createVariantBatch(productIndex: number) {
    const product = products[productIndex];
    if (!product) return;
    const colors = splitVariantTokens(product.variant_batch.colors);
    const sizes = splitVariantTokens(product.variant_batch.sizes);
    const prices = product.variant_batch;
    if (colors.length === 0 || sizes.length === 0) return setError("請先填顏色與尺寸；多個項目用逗號或換行分開");
    if (colors.length * sizes.length > MAX_BATCH_VARIANTS) return setError(`一次最多建立 ${MAX_BATCH_VARIANTS} 個規格；請拆成兩樣商品再建立`);
    if (!validVariant({ name: "批次規格", ...prices })) return setError("批次規格請填成本、分店價、售價，且成本 ≤ 分店價 < 售價");
    const existing = product.variants.filter((variant) => variant.name !== "單一規格" || variant.cost_price || variant.branch_price || variant.retail_price);
    const knownNames = new Set(existing.map((variant) => variantNameKey(variant.name)));
    const created = colors.flatMap((color) => sizes.map((size) => `${color} ${size}`))
      .filter((name) => {
        const key = variantNameKey(name);
        if (knownNames.has(key)) return false;
        knownNames.add(key);
        return true;
      })
      .map((name) => ({ name, cost_price: prices.cost_price, branch_price: prices.branch_price, retail_price: prices.retail_price }));
    if (created.length === 0) return setError("這些顏色與尺寸的規格已經在下方，沒有重複新增");
    setError("");
    updateProduct(productIndex, { variants: [...existing, ...created] });
  }

  async function submit() {
    setError(""); setShareNotice("");
    if (!token || !lane || busy) return;
    if (!endAt || !pickupDeadline) return setError("請先填收單時間與取貨日");
    if (new Date(endAt).getTime() <= Date.now()) return setError("收單時間必須晚於現在");
    if (pickupDeadline < endAt.slice(0, 10)) return setError("取貨日不可早於收單日");
    for (const [i, product] of products.entries()) {
      if (!product.name.trim() || !product.description.trim() || product.images.length === 0) return setError(`第 ${i + 1} 樣商品請填名稱、介紹並至少上傳一張圖`);
      if (lane === "tong" && !product.supplier_name.trim()) return setError(`第 ${i + 1} 樣商品請填廠商`);
      if (product.variants.length === 0 || product.variants.some((v) => !validVariant(v))) return setError(`第 ${i + 1} 樣商品的每個規格都要填成本、分店價、售價，且成本 ≤ 分店價 < 售價`);
    }
    setBusy(true);
    try {
      const uploaded: Array<Record<string, unknown>> = [];
      for (const product of products) {
        const images: string[] = [];
        for (const file of product.images) {
          const uploadedImage = await api<UploadImageResponse>(token, { action: "upload_image", mime: file.type, base64: await fileToBase64(file) });
          images.push(uploadedImage.path);
        }
        uploaded.push({
          name: product.name.trim(), description: product.description.trim(), images,
          variants: product.variants.map((v) => ({ ...v, name: v.name.trim() })),
          ...(lane === "tong" ? { supplier_name: product.supplier_name.trim() } : {}),
        });
      }
      const requestId = localStorage.getItem(REQUEST_KEY) || crypto.randomUUID();
      localStorage.setItem(REQUEST_KEY, requestId);
      const response = await api<PublishResponse>(token, {
        action: "publish", request_id: requestId,
        end_at: new Date(endAt).toISOString(), pickup_deadline: pickupDeadline, items: uploaded,
      });
      setResults((response.campaigns ?? []).map((campaign: Result, index: number) => ({
        ...campaign,
        url: campaignShareUrl(Number(campaign.campaign_id), "/piaopiao/c"),
        description: products[index]?.description.trim() ?? "",
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
      text: [result.name, result.description].filter(Boolean).join("\n\n"),
      url: result.url,
      files: image ? [image] : undefined,
    });
    if (outcome === "cancelled") return;
    if (outcome === "shared_native_with_file") {
      setShareNotice("已開啟分享；請在 LINE 選要分享的群組，商品圖、文案和下單連結會一起帶入。");
    } else if (["shared_native", "shared_in_line", "opened_line"].includes(outcome)) {
      setShareNotice("已開啟 LINE 分享；請自行選群組。文案和下單連結會帶入；此裝置不支援自動帶圖時，請在 LINE 補選第一張商品圖。");
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
    <p className="mb-4 rounded-2xl border border-rose-200 bg-white p-3 text-sm font-semibold text-rose-700">團型／收單類型：漂漂館專區（固定，不可修改，不會上到主商城首頁）</p>
    {results.length > 0 ? <section className="rounded-3xl bg-white p-5 shadow-sm"><h2 className="text-xl font-bold">建立完成，請逐一分享</h2><p className="mt-2 text-sm text-zinc-600">按每一樣商品的分享鈕，再由 LINE 選群組。支援的手機／電腦會帶入商品圖、文案和連結。</p><div className="mt-4 space-y-3">{results.map((result) => <div key={result.campaign_id} className="rounded-2xl border p-4"><p className="font-semibold">{result.name}</p><a className="mt-1 block break-all text-rose-700 underline" href={result.url} target="_blank" rel="noreferrer">{result.url}</a><button onClick={() => void share(result)} className="mt-3 min-h-11 rounded-lg bg-[#06C755] px-4 text-sm font-semibold text-white">分享至 LINE 群組</button></div>)}</div><button onClick={() => { setResults([]); setProducts([emptyProduct()]); }} className="mt-5 min-h-11 rounded-xl bg-rose-600 px-4 font-semibold text-white">再建立一批</button></section> : <>
      <section className="rounded-3xl bg-white p-5 shadow-sm"><h2 className="text-lg font-bold">共同資料</h2><div className="mt-4 grid gap-4 sm:grid-cols-2"><Field label="收單時間"><input className="input" type="datetime-local" value={endAt} onChange={(e) => setEndAt(e.target.value)} /></Field><Field label="取貨日"><input className="input" type="date" value={pickupDeadline} onChange={(e) => setPickupDeadline(e.target.value)} /></Field></div></section>
      <div className="mt-4 space-y-4">{products.map((product, index) => <section key={index} className="rounded-3xl bg-white p-5 shadow-sm"><div className="flex items-center justify-between"><h2 className="text-lg font-bold">商品 {index + 1}</h2><button type="button" onClick={() => removeProduct(index)} className="min-h-11 text-sm text-red-600">{products.length > 1 ? "刪除此商品" : "清空此商品"}</button></div><div className="mt-4 grid gap-4"><Field label="商品名稱"><input className="input" value={product.name} onChange={(e) => updateProduct(index, { name: e.target.value })} /></Field><Field label="商品介紹"><textarea className="input min-h-28" value={product.description} onChange={(e) => updateProduct(index, { description: e.target.value })} /></Field><ProductImagesField images={product.images} onChange={(images) => updateProduct(index, { images })} onMove={(imageIndex, direction) => moveProductImage(index, imageIndex, direction)} onRemove={(imageIndex) => removeProductImage(index, imageIndex)} />{lane === "tong" && <SupplierField value={product.supplier_name} onChange={(supplier_name) => updateProduct(index, { supplier_name })} />}{lane === "chao" && <p className="rounded-xl bg-zinc-100 p-3 text-sm">廠商固定：潮包子</p>}</div><VariantFields product={product} onUpdateVariant={(variantIndex, patch) => updateVariant(index, variantIndex, patch)} onAddVariant={() => addVariant(index)} onRemoveVariant={(variantIndex) => removeVariant(index, variantIndex)} onUpdateBatch={(patch) => updateVariantBatch(index, patch)} onCreateBatch={() => createVariantBatch(index)} /></section>)}</div>
      {canAdd && <button onClick={() => setProducts((all) => [...all, emptyProduct()])} className="mt-4 min-h-11 rounded-xl border border-rose-300 bg-white px-4 font-semibold text-rose-700">＋ 再加一樣商品（最多 5 樣）</button>}<button disabled={busy} onClick={() => void submit()} className="mt-6 min-h-14 w-full rounded-2xl bg-rose-600 px-5 text-lg font-bold text-white disabled:opacity-50">{busy ? "正在建立，請不要關閉…" : publishLabel}</button>
    </>}</main>;
}

function VariantFields({ product, onUpdateVariant, onAddVariant, onRemoveVariant, onUpdateBatch, onCreateBatch }: { product: Product; onUpdateVariant: (variantIndex: number, patch: Partial<Variant>) => void; onAddVariant: () => void; onRemoveVariant: (variantIndex: number) => void; onUpdateBatch: (patch: Partial<VariantBatch>) => void; onCreateBatch: () => void }) {
  const [showDetails, setShowDetails] = useState(false);
  const knownNames = new Set(product.variants.filter((variant) => variant.name !== "單一規格" || variant.cost_price || variant.branch_price || variant.retail_price).map((variant) => variantNameKey(variant.name)));
  const batchCount = splitVariantTokens(product.variant_batch.colors).flatMap((color) => splitVariantTokens(product.variant_batch.sizes).map((size) => `${color} ${size}`)).filter((name) => {
    const key = variantNameKey(name);
    if (knownNames.has(key)) return false;
    knownNames.add(key);
    return true;
  }).length;
  const collapsed = product.variants.length > 8 && !showDetails;
  return <>
    <h3 className="mt-6 font-bold">規格與價格</h3>
    <section className="mt-2 rounded-2xl border border-rose-200 bg-rose-50 p-4">
      <div className="flex items-baseline justify-between gap-3"><div><h4 className="font-semibold text-rose-900">衣服一次建立多個規格</h4><p className="mt-1 text-sm leading-6 text-rose-900/80">顏色和尺寸各填一次，價格也只填一次。客人會先選顏色、再選尺寸；一次最多 {MAX_BATCH_VARIANTS} 個。</p></div>{batchCount > 0 && <span className="shrink-0 rounded-full bg-white px-2.5 py-1 text-sm font-semibold text-rose-700">會建立 {batchCount} 個</span>}</div>
      <div className="mt-4 grid gap-3 sm:grid-cols-2"><Field label="顏色（逗號或換行分開）"><textarea className="input min-h-20" placeholder={"黑色\n白色\n卡其"} value={product.variant_batch.colors} onChange={(e) => onUpdateBatch({ colors: e.target.value })} /></Field><Field label="尺寸（逗號或換行分開）"><textarea className="input min-h-20" placeholder={"S\nM\nL\nXL"} value={product.variant_batch.sizes} onChange={(e) => onUpdateBatch({ sizes: e.target.value })} /></Field></div>
      <div className="mt-3 grid gap-2 sm:grid-cols-3"><input className="input" inputMode="decimal" placeholder="成本價（只填一次）" value={product.variant_batch.cost_price} onChange={(e) => onUpdateBatch({ cost_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="分店價（只填一次）" value={product.variant_batch.branch_price} onChange={(e) => onUpdateBatch({ branch_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="售價（只填一次）" value={product.variant_batch.retail_price} onChange={(e) => onUpdateBatch({ retail_price: e.target.value })} /></div>
      <button type="button" onClick={onCreateBatch} className="mt-4 min-h-11 rounded-xl bg-rose-600 px-4 text-sm font-semibold text-white">{batchCount > 0 ? `產生 ${batchCount} 個規格` : "產生批次規格"}</button>
    </section>
    {product.variants.length > 0 && <div className="mt-3 rounded-2xl bg-zinc-50 p-3 text-sm text-zinc-700"><div className="flex flex-wrap items-center justify-between gap-2"><span>已建立 {product.variants.length} 個規格；共同價格已套用，不用逐格重打。</span>{product.variants.length > 8 && <button type="button" onClick={() => setShowDetails((value) => !value)} className="min-h-10 rounded-lg border bg-white px-3 font-semibold text-zinc-900">{showDetails ? "收起明細" : "展開修改"}</button>}</div>{collapsed && <div className="mt-2 line-clamp-2 text-xs text-zinc-500">{product.variants.map((variant) => variant.name).join("、")}</div>}</div>}
    {!collapsed && <div className="mt-3 space-y-3">{product.variants.map((variant, variantIndex) => <div key={variantIndex} className="rounded-2xl bg-zinc-50 p-3"><div className="grid gap-2 sm:grid-cols-4"><input className="input" placeholder="規格名，例如 黑色 M" value={variant.name} onChange={(e) => onUpdateVariant(variantIndex, { name: e.target.value })} /><input className="input" inputMode="decimal" placeholder="成本價" value={variant.cost_price} onChange={(e) => onUpdateVariant(variantIndex, { cost_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="分店價" value={variant.branch_price} onChange={(e) => onUpdateVariant(variantIndex, { branch_price: e.target.value })} /><input className="input" inputMode="decimal" placeholder="售價" value={variant.retail_price} onChange={(e) => onUpdateVariant(variantIndex, { retail_price: e.target.value })} /></div>{product.variants.length > 1 && <button type="button" onClick={() => onRemoveVariant(variantIndex)} className="mt-2 text-sm text-red-600">刪除此規格</button>}</div>)}</div>}
    <button type="button" onClick={() => { setShowDetails(true); onAddVariant(); }} className="mt-3 min-h-11 rounded-xl border px-3 text-sm font-semibold">＋ 新增規格</button>
  </>;
}

function SupplierField({ value, onChange }: { value: string; onChange: (value: string) => void }) {
  const isPreset = SUPPLIER_OPTIONS.includes(value);
  const [custom, setCustom] = useState(Boolean(value) && !isPreset);
  return <Field label="廠商">
    <select className="input" value={custom ? "__custom" : isPreset ? value : ""} onChange={(e) => {
      if (e.target.value === "__custom") {
        setCustom(true);
        onChange("");
        return;
      }
      setCustom(false);
      onChange(e.target.value);
    }}>
      <option value="">請選擇廠商</option>
      {SUPPLIER_OPTIONS.map((supplier) => <option key={supplier} value={supplier}>{supplier}</option>)}
      <option value="__custom">自訂</option>
    </select>
    {custom && <input className="input mt-2" placeholder="自訂廠商名稱" value={value} onChange={(e) => onChange(e.target.value)} />}
  </Field>;
}

function ProductImagesField({ images, onChange, onMove, onRemove }: { images: File[]; onChange: (images: File[]) => void; onMove: (imageIndex: number, direction: -1 | 1) => void; onRemove: (imageIndex: number) => void }) {
  const previews = useMemo(() => images.map((file) => ({ file, url: URL.createObjectURL(file) })), [images]);
  useEffect(() => () => previews.forEach((item) => URL.revokeObjectURL(item.url)), [previews]);

  return <Field label="商品圖片（至少一張）">
    <input className="block min-h-11 w-full text-base" type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(e) => onChange(Array.from(e.target.files ?? []))} />
    {images.length > 0 && <div className="mt-3 space-y-2">{previews.map((item, imageIndex) => <div key={`${item.file.name}-${imageIndex}`} className="flex items-center gap-3 rounded-2xl bg-zinc-50 p-2">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={item.url} alt="" className="h-14 w-14 rounded-xl object-cover" />
      <div className="min-w-0 flex-1"><p className="truncate text-sm font-semibold">{imageIndex === 0 ? "封面／分享圖" : `第 ${imageIndex + 1} 張`}</p><p className="truncate text-xs text-zinc-500">{item.file.name}</p></div>
      <div className="flex flex-wrap justify-end gap-1"><button type="button" disabled={imageIndex === 0} onClick={() => onMove(imageIndex, -1)} className="min-h-10 rounded-lg border px-2 text-sm disabled:opacity-30">上移</button><button type="button" disabled={imageIndex === images.length - 1} onClick={() => onMove(imageIndex, 1)} className="min-h-10 rounded-lg border px-2 text-sm disabled:opacity-30">下移</button><button type="button" onClick={() => onRemove(imageIndex)} className="min-h-10 rounded-lg border border-red-200 px-2 text-sm font-semibold text-red-600">刪除</button></div>
    </div>)}</div>}
  </Field>;
}

function Field({ label, children }: { label: string; children: React.ReactNode }) { return <label className="block text-sm font-semibold">{label}<div className="mt-1.5">{children}</div></label>; }
function variantNameKey(value: string) { return value.trim().replace(/\s+/g, " ").toLocaleLowerCase(); }
function splitVariantTokens(value: string) { const seen = new Set<string>(); return value.split(/[\n,、]+/).map((item) => item.trim()).filter((item) => { const key = variantNameKey(item); if (!key || seen.has(key)) return false; seen.add(key); return true; }); }
function validVariant(variant: Variant) { const cost = Number(variant.cost_price); const branch = Number(variant.branch_price); const retail = Number(variant.retail_price); return !!variant.name.trim() && Number.isFinite(cost) && Number.isFinite(branch) && Number.isFinite(retail) && cost >= 0 && branch > 0 && retail > 0 && cost <= branch && branch < retail; }
async function api<T>(token: string, body: Record<string, unknown>): Promise<T> { const base = process.env.NEXT_PUBLIC_SUPABASE_URL; if (!base) throw new Error("系統尚未設定連線"); const response = await fetch(`${base}/functions/v1/piaopiao-api`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` }, body: JSON.stringify(body) }); const data = await response.json().catch(() => ({})); if (!response.ok) throw new Error(data.error || `系統錯誤 ${response.status}`); return data as T; }
async function fileToBase64(file: File) { const buffer = await file.arrayBuffer(); let binary = ""; for (const value of new Uint8Array(buffer)) binary += String.fromCharCode(value); return btoa(binary); }
async function imageFromPath(path?: string): Promise<File | undefined> { try { if (!path) return undefined; const base = process.env.NEXT_PUBLIC_SUPABASE_URL; if (!base) return undefined; const url = `${base}/storage/v1/object/public/products/${path.split("/").map(encodeURIComponent).join("/")}`; const response = await fetch(url); if (!response.ok) return undefined; const blob = await response.blob(); return new File([blob], "piaopiao-product-image", { type: blob.type || "image/jpeg" }); } catch { return undefined; } }
