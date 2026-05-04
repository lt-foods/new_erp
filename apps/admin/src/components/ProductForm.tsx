"use client";

import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import { getSupabase } from "@/lib/supabase";
import { ProductImagesField } from "@/components/ProductImagesField";
import { CategoryCombobox, type CategoryOption } from "@/components/CategoryCombobox";
import { RichTextEditor } from "@/components/RichTextEditor";

type Status = "draft" | "active" | "inactive" | "discontinued";
type StorageType = "room_temp" | "refrigerated" | "frozen" | "meal_train";

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
  storage_type: StorageType | null;
  default_supplier_id: number | null;
  stop_shipping: boolean;
  is_for_shop: boolean;
  customized_id: string;
  customized_text: string;
  storage_location: string;
  user_note: string;
  user_note_public: string;
  vip_level_min: number;
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
  storage_type: null,
  default_supplier_id: null,
  stop_shipping: false,
  is_for_shop: true,
  customized_id: "",
  customized_text: "",
  storage_location: "",
  user_note: "",
  user_note_public: "",
  vip_level_min: 0,
};

const STORAGE_TYPE_LABEL: Record<StorageType, string> = {
  room_temp: "常溫",
  refrigerated: "冷藏",
  frozen: "冷凍",
  meal_train: "餐車",
};

type LookupRow = { id: number; name: string; code: string };

export function ProductForm({
  initial,
  onSaved,
  onCancel,
  midSlot,
}: {
  initial?: ProductFormValues;
  onSaved?: (id: number) => void;
  onCancel?: () => void;
  midSlot?: ReactNode;
}) {
  const router = useRouter();
  const [values, setValues] = useState<ProductFormValues>(initial ?? EMPTY);
  const [brands, setBrands] = useState<LookupRow[]>([]);
  const [categories, setCategories] = useState<CategoryOption[]>([]);
  const [suppliers, setSuppliers] = useState<LookupRow[]>([]);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [advancedOpen, setAdvancedOpen] = useState(false);

  useEffect(() => {
    (async () => {
      const sb = getSupabase();
      const [b, c, s] = await Promise.all([
        sb.from("brands").select("id, name, code").order("name"),
        sb.from("categories").select("id, name, code").order("level").order("sort_order"),
        sb.from("suppliers").select("id, name, code").eq("is_active", true).order("name"),
      ]);
      if (b.data) setBrands(b.data as LookupRow[]);
      if (c.data) setCategories(c.data as CategoryOption[]);
      if (s.data) setSuppliers(s.data as LookupRow[]);
    })();
  }, []);

  function set<K extends keyof ProductFormValues>(key: K, value: ProductFormValues[K]) {
    setValues((v) => ({ ...v, [key]: value }));
  }

  // 新建商品時：選溫層就（重新）產生商品編號；之後可手動改
  const [codeIsAuto, setCodeIsAuto] = useState(true);
  useEffect(() => {
    if (values.id != null) return;
    if (!codeIsAuto) return;
    (async () => {
      const { data } = await getSupabase().rpc("rpc_next_product_code", {
        p_storage_type: values.storage_type,
      });
      if (typeof data === "string") setValues((v) => ({ ...v, product_code: data }));
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [values.storage_type, values.id, codeIsAuto]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);

    if (values.customized_text && values.customized_text.length > 7) {
      setError("客製文字最多 7 字");
      return;
    }

    // 上架驗證：至少一個規格要有零售價 (cost / branch 改成可選,留待採購/分店流程補)
    if (values.status === "active") {
      if (values.id == null) {
        setError("新商品請先儲存為「草稿」、補完一個規格的零售價後再切到「上架」");
        return;
      }
      const sb = getSupabase();
      const { data: skus } = await sb.from("skus").select("id").eq("product_id", values.id);
      if (!skus?.length) {
        setError("上架前需先新增至少一個規格");
        return;
      }
      const skuIds = skus.map((s) => s.id);
      const { data: prices } = await sb
        .from("prices")
        .select("sku_id, scope")
        .in("sku_id", skuIds)
        .eq("scope", "retail")
        .is("effective_to", null);
      const skusWithRetail = new Set(((prices ?? []) as { sku_id: number }[]).map((p) => p.sku_id));
      if (skusWithRetail.size === 0) {
        setError("上架需至少一個規格已設定零售價");
        return;
      }
    }

    let code = values.product_code;
    if (!code && values.id == null) {
      const { data } = await getSupabase().rpc("rpc_next_product_code", {
        p_storage_type: values.storage_type,
      });
      if (typeof data === "string") code = data;
    }

    setSaving(true);
    const { data, error: err } = await getSupabase().rpc("rpc_upsert_product", {
      p_id: values.id,
      p_product_code: code,
      p_name: values.name,
      p_short_name: values.short_name || null,
      p_brand_id: values.brand_id,
      p_category_id: values.category_id,
      p_description: values.description || null,
      p_status: values.status,
      p_images: values.images,
      p_storage_type: values.storage_type,
      p_customized_id: values.customized_id || null,
      p_customized_text: values.customized_text || null,
      p_storage_location: values.storage_location || null,
      p_default_supplier_id: values.default_supplier_id,
      p_user_note: values.user_note || null,
      p_user_note_public: values.user_note_public || null,
      p_stop_shipping: values.stop_shipping,
      p_is_for_shop: values.is_for_shop,
      p_vip_level_min: values.vip_level_min,
      p_reason: null,
    });
    setSaving(false);
    if (err) {
      setError(err.message);
      return;
    }
    const newId = Number(data);
    if (onSaved) onSaved(newId);
    else router.replace(`/products`);
  }

  const inputClass =
    "w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm focus:border-zinc-500 focus:outline-none dark:border-zinc-700 dark:bg-zinc-800";
  const selectClass =
    "w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-800";

  return (
    <form onSubmit={onSubmit} className="space-y-5">
      <Grid>
        <Field label="商品編號">
          <input
            value={values.product_code}
            onChange={(e) => { setCodeIsAuto(false); set("product_code", e.target.value); }}
            placeholder={values.id == null ? "選溫層後自動產生（可手動覆蓋）" : ""}
            className={inputClass}
          />
          {values.id == null && (
            <p className="mt-1 text-[11px] text-zinc-500">
              {codeIsAuto ? "自動依溫層產生 — " : "已手動指定 — "}
              前綴：F=冷凍 / R=冷藏 / A=常溫 / M=餐車 / G=未指定
            </p>
          )}
        </Field>
        <Field label="狀態" required>
          <select
            value={values.status}
            onChange={(e) => set("status", e.target.value as Status)}
            className={selectClass}
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
          className={inputClass}
        />
      </Field>

      <Field label="簡稱">
        <input
          value={values.short_name}
          onChange={(e) => set("short_name", e.target.value)}
          className={inputClass}
        />
      </Field>

      <Grid>
        <Field label="品牌">
          <select
            value={values.brand_id ?? ""}
            onChange={(e) => set("brand_id", e.target.value ? Number(e.target.value) : null)}
            className={selectClass}
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
          <CategoryCombobox
            value={values.category_id}
            options={categories}
            onChange={(id) => set("category_id", id)}
            onCreated={(cat) => setCategories((arr) => [...arr, cat])}
          />
        </Field>
      </Grid>

      {midSlot}

      <Grid>
        <Field label="儲存溫層">
          <select
            value={values.storage_type ?? ""}
            onChange={(e) =>
              set("storage_type", e.target.value ? (e.target.value as StorageType) : null)
            }
            className={selectClass}
          >
            <option value="">—（未設定）</option>
            {(Object.keys(STORAGE_TYPE_LABEL) as StorageType[]).map((k) => (
              <option key={k} value={k}>
                {STORAGE_TYPE_LABEL[k]}
              </option>
            ))}
          </select>
        </Field>
        <Field label="預設供應商">
          <select
            value={values.default_supplier_id ?? ""}
            onChange={(e) =>
              set("default_supplier_id", e.target.value ? Number(e.target.value) : null)
            }
            className={selectClass}
          >
            <option value="">—（不設定）</option>
            {suppliers.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name} ({s.code})
              </option>
            ))}
          </select>
        </Field>
      </Grid>

      <div className="flex flex-wrap gap-4">
        <Checkbox
          label="上架個人賣場"
          checked={values.is_for_shop}
          onChange={(v) => set("is_for_shop", v)}
        />
        <Checkbox
          label="暫停出貨"
          checked={values.stop_shipping}
          onChange={(v) => set("stop_shipping", v)}
        />
      </div>

      <Field label="描述">
        <RichTextEditor
          value={values.description}
          onChange={(html) => set("description", html)}
          placeholder="輸入商品描述、可加粗體、列表、連結…"
        />
      </Field>

      <Field label="圖片">
        <ProductImagesField
          value={values.images}
          onChange={(next) => set("images", next)}
        />
      </Field>

      <details
        open={advancedOpen}
        onToggle={(e) => setAdvancedOpen((e.currentTarget as HTMLDetailsElement).open)}
        className="rounded-md border border-zinc-200 dark:border-zinc-800"
      >
        <summary className="cursor-pointer select-none px-4 py-2 text-sm font-medium text-zinc-700 hover:bg-zinc-50 dark:text-zinc-300 dark:hover:bg-zinc-900">
          進階設定
        </summary>
        <div className="space-y-5 border-t border-zinc-200 p-4 dark:border-zinc-800">
          <Grid>
            <Field label="客製編號">
              <input
                value={values.customized_id}
                onChange={(e) => set("customized_id", e.target.value)}
                className={inputClass}
              />
            </Field>
            <Field label="客製文字（≤ 7 字）">
              <input
                maxLength={7}
                value={values.customized_text}
                onChange={(e) => set("customized_text", e.target.value)}
                className={inputClass}
              />
            </Field>
          </Grid>

          <Grid>
            <Field label="存放位置">
              <input
                value={values.storage_location}
                onChange={(e) => set("storage_location", e.target.value)}
                className={inputClass}
              />
            </Field>
            <Field label="VIP 最低等級（0-10）">
              <input
                type="number"
                min={0}
                max={10}
                step={1}
                value={values.vip_level_min}
                onChange={(e) =>
                  set("vip_level_min", Math.max(0, Math.min(10, Number(e.target.value) || 0)))
                }
                className={inputClass}
              />
            </Field>
          </Grid>

          <Field label="內部備註">
            <textarea
              rows={2}
              value={values.user_note}
              onChange={(e) => set("user_note", e.target.value)}
              className={inputClass}
            />
          </Field>

          <Field label="公開備註（顯示給客人）">
            <textarea
              rows={2}
              value={values.user_note_public}
              onChange={(e) => set("user_note_public", e.target.value)}
              className={inputClass}
            />
          </Field>
        </div>
      </details>

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
          onClick={() => (onCancel ? onCancel() : router.push("/products"))}
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

function Checkbox({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <label className="inline-flex cursor-pointer select-none items-center gap-2 text-sm">
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
        className="h-4 w-4 rounded border-zinc-300 dark:border-zinc-700"
      />
      <span>{label}</span>
    </label>
  );
}
