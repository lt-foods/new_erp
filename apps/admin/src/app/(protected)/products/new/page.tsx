import { ProductForm } from "@/components/ProductForm";

export default function NewProductPage() {
  return (
    <div className="mx-auto w-full max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-xl font-semibold">新增商品</h1>
        <p className="text-sm text-zinc-500">建立後會自動回編輯頁；SKU / 條碼 / 價格請在下一步加入。</p>
      </header>
      <ProductForm />
    </div>
  );
}
