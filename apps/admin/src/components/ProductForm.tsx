"use client";

import { useEffect, useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { ProductImagesField } from "@/components/ProductImagesField";

type Status = "draft" | "active" | "inactive" | "discontinued";

export type ProductFormValues = {
  id: number | null;
  product_code: string;
  name: string;
  short_name: string;
  brand_id: number | null;
  category_id: number | null;
  description: string;
  status: Status;
  images: string[];
};

const EMPTY: ProductFormValues = {
  id: null,
  product_code: "",
  name: "",
  short_name: "",
  brand_id: null,
  category_id: null,
  description: "",
  status: "draft",
  images: [],
};

type LookupRow = { id: number; name: string; code: string };

export function ProductForm({ initial }: { initial?: ProductFormValues }) {
  const router = useRouter();
  const [values, setValues] = useState<ProductFormValues>(initial ?? EMPTY);
  const [brands, setBrands] = useState<LookupRow[]>([]);
  const [categories, setCategories] = useState<LookupRow[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [b, c] = await Promise.all([
        sb.from("brands").select("id, name, code").order("name"),
        sb.from("categories").select("id, name, code").order("level").order("sort_order"),
      ]);
      if (b.data) setBrands(b.data as LookupRow[]);
      if (c.data) setCategories(c.data as LookupRow[]);
    })();
  }, []);

  function set<K extends keyof ProductFormValues>(key: K, value: ProductFormValues[K]) {
    setValues((v) => ({ ...v, [key]: value }));
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSaving(true);
    const { data, error: err } = await getSupabase().rpc("rpc_upsert_product", {
      p_id: values.id,
      p_product_code: values.product_code,
      p_name: values.name,
      p_short_name: values.short_name || null,
      p_brand_id: values.brand_id,
      p_category_id: values.category_id,
      p_description: values.description || null,
      p_status: values.status,
      p_images: values.images,
      p_reason: null,
    });
    setSaving(false);
    if (err) {
      setError(err.message);
      return;
    }
    router.replace(`/products/edit?id=${data}&saved=1`);
  }

  return (
    <form onSubmit={onSubmit} className="space-y-5">
      <Grid>
        <Field label="商品編號" required>
          <input
            required
            value={values.product_code}
            onChange={(e) => set("product_code", e.target.value)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
          />
        </Field>
        <Field label="狀態" required>
          <select
            value={values.status}
            onChange={(e) => set("status", e.target.value as Status)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="draft">草稿</option>
            <option value="active">上架</option>
            <option value="inactive">下架</option>
            <option value="discontinued">停產</option>
          </select>
        </Field>
      </Grid>

      <Field label="名稱" required>
        <input
          required
          value={values.name}
          onChange={(e) => set("name", e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      </Field>

      <Field label="簡稱">
        <input
          value={values.short_name}
          onChange={(e) => set("short_name", e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      </Field>

      <Grid>
        <Field label="品牌">
          <select
            value={values.brand_id ?? ""}
            onChange={(e) => set("brand_id", e.target.value ? Number(e.target.value) : null)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">—（不設定）</option>
            {brands.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name} ({b.code})
              </option>
            ))}
          </select>
        </Field>
        <Field label="分類">
          <select
            value={values.category_id ?? ""}
            onChange={(e) => set("category_id", e.target.value ? Number(e.target.value) : null)}
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800"
          >
            <option value="">—（不設定）</option>
            {categories.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name} ({c.code})
              </option>
            ))}
          </select>
        </Field>
      </Grid>

      <Field label="描述">
        <textarea
          rows={4}
          value={values.description}
          onChange={(e) => set("description", e.target.value)}
          className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800"
        />
      </Field>

      <Field label="圖片">
        <ProductImagesField
          value={values.images}
          onChange={(next) => set("images", next)}
        />
      </Field>

      {error && (
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700 dark:bg-red-950 dark:text-red-300">
          {error}
        </p>
      )}

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={saving}
          className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          {saving ? "儲存中…" : values.id === null ? "建立" : "儲存"}
        </button>
        <button
          type="button"
          onClick={() => router.push("/products")}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm text-zinc-700 hover:bg-zinc-50 dark:border-zinc-700 dark:text-zinc-300 dark:hover:bg-zinc-800"
        >
          取消
        </button>
      </div>
    </form>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  return <div className="grid gap-4 sm:grid-cols-2">{children}</div>;
}

function Field({
  label,
  required,
  children,
}: {
  label: string;
  required?: boolean;
  children: React.ReactNode;
}) {
  return (
    <label className="block space-y-1">
      <span className="text-sm font-medium">
        {label}
        {required && <span className="text-red-500"> *</span>}
      </span>
      {children}
    </label>
  );
}
