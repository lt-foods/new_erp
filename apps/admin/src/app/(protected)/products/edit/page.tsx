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
  storage_type: ProductFormValues["storage_type"];
  sale_mode: ProductFormValues["sale_mode"];
  default_supplier_id: number | null;
  count_for_start_sale: number | null;
  limit_time: string | null;
  stop_shipping: boolean | null;
  is_for_shop: boolean | null;
  customized_id: string | null;
  customized_text: string | null;
  storage_location: string | null;
  user_note: string | null;
  user_note_public: string | null;
  vip_level_min: number | null;
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

function toDatetimeLocal(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
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
        .select(
          "id, product_code, name, short_name, brand_id, category_id, description, status, images, " +
            "storage_type, sale_mode, default_supplier_id, count_for_start_sale, limit_time, " +
            "stop_shipping, is_for_shop, customized_id, customized_text, storage_location, " +
            "user_note, user_note_public, vip_level_min"
        )
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
        storage_type: data.storage_type ?? null,
        sale_mode: data.sale_mode ?? "preorder",
        default_supplier_id: data.default_supplier_id,
        count_for_start_sale: data.count_for_start_sale,
        limit_time: data.limit_time ? toDatetimeLocal(data.limit_time) : "",
        stop_shipping: data.stop_shipping ?? false,
        is_for_shop: data.is_for_shop ?? true,
        customized_id: data.customized_id ?? "",
        customized_text: data.customized_text ?? "",
        storage_location: data.storage_location ?? "",
        user_note: data.user_note ?? "",
        user_note_public: data.user_note_public ?? "",
        vip_level_min: data.vip_level_min ?? 0,
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
