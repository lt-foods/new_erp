"use client";

import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { ProductForm, type ProductFormValues } from "@/components/ProductForm";
import { ProductSkuSection } from "@/components/ProductSkuSection";

type ProductRow = {
  id: number;
  product_code: string;
  name: string;
  short_name: string | null;
  brand_id: number | null;
  category_id: number | null;
  description: string | null;
  status: ProductFormValues["status"];
  images: string[] | null;
};

export default function EditProductPage() {
  return (
    <Suspense fallback={<Loading />}>
      <EditProductBody />
    </Suspense>
  );
}

function Loading() {
  return <div className="p-6 text-sm text-zinc-500">載入中…</div>;
}

function EditProductBody() {
  const params = useSearchParams();
  const id = params.get("id");
  const saved = params.get("saved") === "1";
  const [initial, setInitial] = useState<ProductFormValues | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!id) {
      setError("缺少 id 參數");
      return;
    }
    (async () => {
      const { data, error: err } = await getSupabase()
        .from("products")
        .select("id, product_code, name, short_name, brand_id, category_id, description, status, images")
        .eq("id", Number(id))
        .maybeSingle<ProductRow>();
      if (err) {
        setError(err.message);
        return;
      }
      if (!data) {
        setError("找不到此商品");
        return;
      }
      setInitial({
        id: data.id,
        product_code: data.product_code,
        name: data.name,
        short_name: data.short_name ?? "",
        brand_id: data.brand_id,
        category_id: data.category_id,
        description: data.description ?? "",
        status: data.status,
        images: Array.isArray(data.images) ? data.images : [],
      });
    })();
  }, [id]);

  if (error) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      </div>
    );
  }

  if (!initial) return <Loading />;

  return (
    <div className="mx-auto w-full max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-xl font-semibold">編輯商品</h1>
        <p className="text-sm text-zinc-500">
          <span className="font-mono">{initial.product_code}</span> · {initial.name}
        </p>
      </header>
      {saved && (
        <div className="rounded-md bg-green-50 px-3 py-2 text-sm text-green-800 dark:bg-green-950 dark:text-green-300">
          已儲存。
        </div>
      )}
      <ProductForm initial={initial} />
      {initial.id !== null && <ProductSkuSection productId={initial.id} />}
    </div>
  );
}
