import { CampaignForm } from "@/components/CampaignForm";

export default function NewCampaignPage() {
  return (
    <div className="mx-auto w-full max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-xl font-semibold">新增開團</h1>
        <p className="text-sm text-zinc-500">建立後自動回編輯頁，在下一步加商品明細。</p>
      </header>
      <CampaignForm />
    </div>
  );
}
