import { MemberForm } from "@/components/MemberForm";

export default function NewMemberPage() {
  return (
    <div className="mx-auto w-full max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-xl font-semibold">新增會員</h1>
        <p className="text-sm text-zinc-500">建立後會自動回編輯頁。</p>
      </header>
      <MemberForm />
    </div>
  );
}
