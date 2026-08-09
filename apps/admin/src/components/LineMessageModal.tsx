"use client";

// 對單一會員經 LINE 官方帳號發訊息（文字 + 截圖）。
// 後端：admin-line-push edge function（函式內驗 staff JWT）。
//
// 圖片流程：不管來源格式，一律 canvas 轉 JPEG 再上傳 line-media bucket —
//   original ≤ 2048px（LINE originalContentUrl 上限 10MB，轉完遠低於此）
//   preview  ≤  800px（LINE previewImageUrl 上限 1MB，聊天室縮圖用）
// 順便鋪白底（截圖常有透明背景，JPEG 沒有 alpha）、去掉 EXIF。
//
// 開啟時先打 action:check 預檢「推不推得到」：404 = 沒加好友或
// Login channel 跟 OA 不同 provider — 這是營運前置條件問題，不是 bug，
// 所以要在發送前就讓店員看到，而不是發了才失敗。

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getSupabase } from "@/lib/supabase";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";
import { translateRpcError } from "@/lib/rpcError";
import { renderPickupImage, type PickupOrder } from "@/lib/pickupImage";

const BUCKET = "line-media";
const FN_URL = `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/admin-line-push`;

type Reachable =
  | { state: "checking" }
  | { state: "ok"; displayName: string | null }
  | { state: "unreachable"; message: string }
  | { state: "not_configured"; message: string }
  | { state: "error"; message: string };

// limit=null = 方案無則數上限。額度只算「主動推播」（這個功能就是），
// OA 後台 1:1 聊天不吃額度，所以這裡的數字跟後台聊天量對不上是正常的。
type Quota = { limit: number | null; used: number };

// OA 後台 1:1 聊天室（chat.line.biz）。走這條發訊息不吃推播額度，
// 但要另外登入 OA 後台、且該帳號要有這支 OA 的權限。
// chatMode "bot" = 後台把「聊天」關掉了、只走 webhook，連過去也不能回。
type Chat = { url: string | null; mode: string | null };

/**
 * 該店 OA 好友名冊裡「還沒配對到會員」的人。
 *
 * webhook 只收得到 LINE 使用者，收不到「他是哪位會員」—— 官方的 account link
 * 是自動化正解但要碰顧客端，還沒做。在那之前讓店員自己挑：他們本來就認得
 * 顧客的 LINE 名稱與頭像，這是最直覺的補救。
 */
type Follower = { line_user_id: string; display_name: string | null; picture_url: string | null };

/** 名冊列在畫面上的稱呼：LINE 暱稱優先，沒有就露一小截 ID（整串太長塞不下） */
function followerLabel(f: Follower): string {
  return f.display_name ?? `${f.line_user_id.slice(0, 8)}…`;
}

// 訊息樣板。連結由後端 links action 給（來自 MEMBER_FRONT_BASE_URL），
// 不在這裡寫死網址 —— 換網域時只要改 secret，不用重新部署前端。
//
// ⚠ 連結一律用會員站自己的網址，不要換成 https://liff.line.me/...
//   （LIFF endpoint 目前跨網域，會員點進去登入會爆，見 CLAUDE.md）。
const TEMPLATES: { label: string; build: (ordersUrl: string) => string }[] = [
  {
    label: "📦 到貨通知",
    build: (ordersUrl) => `您好，您有貨到了！\n查看訂單：${ordersUrl}`,
  },
];

async function callFn(body: Record<string, unknown>) {
  const sb = getSupabase();
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("尚未登入");
  const resp = await fetch(FN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${session.access_token}`,
    },
    body: JSON.stringify(body),
  });
  const result = await resp.json().catch(() => ({}));
  return { status: resp.status, result };
}

/** canvas 轉 JPEG：縮到 maxDim 內、鋪白底（透明截圖）、去 EXIF */
async function encodeJpeg(file: File, maxDim: number, quality: number): Promise<Blob> {
  const bmp = await createImageBitmap(file);
  try {
    const scale = Math.min(1, maxDim / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale));
    const h = Math.max(1, Math.round(bmp.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("無法建立 canvas");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(bmp, 0, 0, w, h);
    const blob = await new Promise<Blob | null>((res) => canvas.toBlob(res, "image/jpeg", quality));
    if (!blob) throw new Error("圖片轉檔失敗");
    return blob;
  } finally {
    bmp.close();
  }
}

export function LineMessageModal({
  open, onClose, member, tenantId, homeStoreId = null, storeName = null,
}: {
  open: boolean;
  onClose: () => void;
  member: { id: number; name: string | null; member_no: string };
  tenantId: string;
  /** 會員取貨店 —— 決定要看哪一家店的 OA 名冊 */
  homeStoreId?: number | null;
  /** 取貨店名稱，印在可取貨訂單圖的抬頭 */
  storeName?: string | null;
}) {
  const [reachable, setReachable] = useState<Reachable>({ state: "checking" });
  const [quota, setQuota] = useState<Quota | null>(null);
  const [chat, setChat] = useState<Chat | null>(null);
  const [ordersUrl, setOrdersUrl] = useState<string | null>(null);
  const [followers, setFollowers] = useState<Follower[]>([]);
  /** 這位會員目前配對到的名冊列（null = 還沒配對）。有值才給得出「解除」這條退路。 */
  const [bound, setBound] = useState<Follower | null>(null);
  const [binding, setBinding] = useState<string | null>(null);
  // 解除之後要強制把選單留在畫面上：此時 check 多半已翻成「推不到」，
  // 但萬一舊的 members.line_user_id 剛好推得到，選單會被條件藏起來，
  // 店員就會停在「解除了、然後呢」。
  const [pickerOpen, setPickerOpen] = useState(false);
  const [unbinding, setUnbinding] = useState(false);
  const [buildingImage, setBuildingImage] = useState(false);
  const [text, setText] = useState("");
  const [image, setImage] = useState<File | null>(null);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  /**
   * 打一次可達性預檢並把結果畫上去。開啟時跑一次；配對 / 解除配對之後也要再跑
   * 一次，畫面才會從「推不到」翻成「可發送」（或反過來）。
   *
   * 刻意**不**在這裡把 state 設回 checking：開啟時的初始 state 就是 checking，
   * 在 effect 裡同步 setState 會被 react-hooks/set-state-in-effect 擋下。
   * 需要「重新檢查中…」的呼叫端自己先設（見 recheck）。
   */
  const runCheck = useCallback(async () => {
    try {
      const { status, result } = await callFn({ action: "check", member_id: member.id });
      if (result.ok) setChat({ url: result.chat_url ?? null, mode: result.chat_mode ?? null });
      if (result.ok && result.reachable) {
        setReachable({ state: "ok", displayName: result.display_name ?? null });
      } else if (result.ok && !result.reachable) {
        setReachable({ state: "unreachable", message: result.message });
      } else if (result.error === "not_configured") {
        setReachable({ state: "not_configured", message: result.message });
      } else {
        // detail 一定要帶上：只顯示 error code（line_api_error）等於沒說，
        // 之前就是因為這樣得回資料庫撈 line_push_logs 才知道真正原因
        setReachable({
          state: "error",
          message: result.message || result.detail || result.error || `HTTP ${status}`,
        });
      }
    } catch (e) {
      setReachable({ state: "error", message: e instanceof Error ? e.message : String(e) });
    }
  }, [member.id]);

  const recheck = useCallback(async () => {
    setReachable({ state: "checking" });
    await runCheck();
  }, [runCheck]);

  /**
   * 該店名冊的兩份資料：還沒配對的（可選）+ 這位會員目前配對到的那筆（可解除）。
   * 配對 / 解除之後都要重抓 —— 被解除的那筆會回到「還沒配對」那份裡，
   * 店員才選得回來。
   */
  const loadFollowers = useCallback(async (): Promise<{
    list: Follower[]; bound: Follower | null; error: string | null;
  }> => {
    if (homeStoreId == null) return { list: [], bound: null, error: null };
    const sb = getSupabase();
    const cols = "line_user_id, display_name, picture_url";
    const [unlinked, mine] = await Promise.all([
      sb.from("store_line_followers").select(cols)
        .eq("store_id", homeStoreId).is("member_id", null).eq("followed", true).limit(50),
      // 不用 maybeSingle：萬一歷史資料留下同一會員兩列，maybeSingle 會直接報錯，
      // 反而把「解除配對」這條退路一起弄不見 —— 而那正是要來清理它的工具。
      sb.from("store_line_followers").select(cols)
        .eq("store_id", homeStoreId).eq("member_id", member.id).limit(1),
    ]);
    // 不能吞掉錯誤：查詢失敗時清單會是空的，選單就整個不見，
    // 畫面上卻什麼都沒說 —— 店員只會覺得「這功能壞了」而無從回報。
    const err = unlinked.error ?? mine.error;
    if (err) return { list: [], bound: null, error: `讀取本店 LINE 名冊失敗：${err.message}` };
    return {
      list: (unlinked.data as Follower[]) ?? [],
      bound: ((mine.data as Follower[]) ?? [])[0] ?? null,
      error: null,
    };
  }, [homeStoreId, member.id]);

  // 開啟時預檢可達性（modal 是條件渲染、每次開啟重新 mount，初始 state 即 checking）
  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    (async () => { await runCheck(); })();
    // 額度另外抓，失敗就不顯示（不擋發送流程）
    (async () => {
      try {
        const { result } = await callFn({ action: "quota" });
        if (!cancelled && result.ok) setQuota({ limit: result.limit ?? null, used: result.used ?? 0 });
      } catch { /* 額度顯示是輔助資訊，抓不到就算了 */ }
    })();
    // 該店還沒配對的 OA 好友：推不到時要讓店員手動挑；
    // 順便撈目前已配對的那筆，綁錯時才有得解除。
    (async () => {
      const r = await loadFollowers();
      if (cancelled) return;
      if (r.error) { setError(r.error); return; }
      setFollowers(r.list);
      setBound(r.bound);
    })();
    // 樣板用的會員站連結（不需要 LINE token，所以 token 沒設也拿得到）
    (async () => {
      try {
        const { result } = await callFn({ action: "links" });
        if (!cancelled && result.ok) setOrdersUrl(result.orders_url ?? null);
      } catch { /* 拿不到就不顯示樣板按鈕 */ }
    })();
    return () => { cancelled = true; };
  }, [open, member.id, homeStoreId, runCheck, loadFollowers]);

  // 貼上截圖（Ctrl/Cmd+V）— modal 開著時掛在 document 上，不用先點進哪個欄位
  useEffect(() => {
    if (!open) return;
    function onPaste(e: ClipboardEvent) {
      const item = Array.from(e.clipboardData?.items ?? []).find((i) => i.type.startsWith("image/"));
      const file = item?.getAsFile();
      if (file) {
        e.preventDefault();
        setError(null);
        setImage(file);
      }
    }
    document.addEventListener("paste", onPaste);
    return () => document.removeEventListener("paste", onPaste);
  }, [open]);

  // objectURL 隨 image 換發 / 卸載時回收
  const imagePreview = useMemo(() => (image ? URL.createObjectURL(image) : null), [image]);
  useEffect(() => {
    return () => { if (imagePreview) URL.revokeObjectURL(imagePreview); };
  }, [imagePreview]);

  /**
   * 把該會員的可取貨品項畫成一張圖，直接放進附圖欄。
   *
   * 「可取貨」判斷在**單頭**（status = ready / partially_completed），不在品項 ——
   * 這個租戶的品項狀態實際上只用 pending（未取）/ picked_up（已取）/ cancelled：
   * 全庫 5.1 萬筆 pending、ready 只有 3 筆（2026-08-08 查證；一開始篩品項
   * status='ready' 導致永遠回「沒有可取貨的品項」）。
   * 所以：單頭已可取貨的訂單裡，「還沒取又沒取消」的品項就是要給顧客看的清單。
   */
  async function buildPickupImage() {
    setBuildingImage(true);
    setError(null);
    try {
      const { data, error: qErr } = await getSupabase()
        .from("customer_orders")
        .select("order_no, status, campaign:group_buy_campaigns(name), customer_order_items(qty, unit_price, status, skus(sku_code, products(name)))")
        .eq("member_id", member.id)
        .in("status", ["ready", "partially_completed"])
        .order("created_at", { ascending: false });
      if (qErr) { setError(qErr.message); return; }

      type Row = {
        order_no: string;
        campaign: { name: string } | { name: string }[] | null;
        customer_order_items: {
          qty: number; unit_price: number | null; status: string | null;
          skus: { sku_code: string | null; products: { name: string } | { name: string }[] | null } | null;
        }[] | null;
      };
      const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? v[0] ?? null : v);

      const orders: PickupOrder[] = ((data ?? []) as unknown as Row[])
        .map((o) => ({
          orderNo: o.order_no,
          campaign: one(o.campaign)?.name ?? null,
          lines: (o.customer_order_items ?? [])
            // pending/reserved/ready 都是「尚未取貨」的細分（見 lib/orderStatus.ts）；
            // 排除 picked_up（已拿走）與 cancelled/expired（斷貨，錢跟數量都不能算）
            .filter((it) => ["pending", "reserved", "ready"].includes(it.status ?? ""))
            .map((it) => ({
              name: one(one(it.skus)?.products ?? null)?.name
                ?? one(it.skus)?.sku_code
                ?? "（品項）",
              qty: Number(it.qty ?? 0),
              unitPrice: it.unit_price == null ? null : Number(it.unit_price),
            })),
        }))
        .filter((o) => o.lines.length > 0);

      if (orders.length === 0) {
        setError("這位會員目前沒有可取貨的品項");
        return;
      }

      const blob = await renderPickupImage({
        storeName,
        memberName: member.name,
        orders,
      });
      setImage(new File([blob], "pickup.jpg", { type: "image/jpeg" }));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBuildingImage(false);
    }
  }

  /** 把名冊裡的一位配對到這位會員（RPC 會先解掉這位會員在該店的舊配對） */
  async function bind(f: Follower) {
    setBinding(f.line_user_id);
    setError(null);
    try {
      const { error } = await getSupabase().rpc("rpc_bind_store_line_follower", {
        p_member_id: member.id,
        p_line_user_id: f.line_user_id,
      });
      if (error) { setError(translateRpcError(error)); return; }
      // 選單裡少一個、上方多一列「目前配對」—— 綁完馬上就看得到綁到誰，
      // 也馬上就有「解除」可按。以前這裡是 setFollowers([])，綁錯就沒有回頭路。
      setBound(f);
      setPickerOpen(false);
      setFollowers((prev) => prev.filter((x) => x.line_user_id !== f.line_user_id));
      await recheck();
    } finally {
      setBinding(null);
    }
  }

  /**
   * 解除配對 = 綁錯人的退路。
   *
   * 綁錯的後果是「訊息推給別的顧客」（可取貨訂單圖上有姓名與品項），
   * 所以這顆按鈕要一直在，不能只在推不到的時候出現 —— 推得到但推錯人，
   * 正是最需要它的情況。
   */
  async function unbind() {
    if (!bound) return;
    if (!window.confirm(
      `要解除與「${followerLabel(bound)}」的配對嗎？\n解除後這位會員暫時收不到訊息，需要重新選一次。`
    )) return;
    setUnbinding(true);
    setError(null);
    try {
      const { error } = await getSupabase().rpc("rpc_unbind_store_line_follower", {
        p_member_id: member.id,
        p_line_user_id: bound.line_user_id,
      });
      if (error) { setError(translateRpcError(error)); return; }
      setBound(null);
      setPickerOpen(true);
      const r = await loadFollowers();
      if (r.error) setError(r.error);
      else { setFollowers(r.list); setBound(r.bound); }
      await recheck();
    } finally {
      setUnbinding(false);
    }
  }

  function pickImage(file: File) {
    if (!file.type.startsWith("image/")) {
      setError("只能附圖片檔");
      return;
    }
    setError(null);
    setImage(file);
  }

  async function send() {
    if (!text.trim() && !image) {
      setError("請輸入訊息或附上截圖");
      return;
    }
    setSending(true);
    setError(null);
    try {
      let imageUrl: string | undefined;
      let previewUrl: string | undefined;

      if (image) {
        const sb = getSupabase();
        const [original, preview] = await Promise.all([
          encodeJpeg(image, 2048, 0.9),
          encodeJpeg(image, 800, 0.8),
        ]);
        const base = `${tenantId}/${crypto.randomUUID()}`;
        for (const [path, blob] of [[`${base}.jpg`, original], [`${base}_preview.jpg`, preview]] as const) {
          const { error: upErr } = await sb.storage
            .from(BUCKET)
            .upload(path, blob, { contentType: "image/jpeg", cacheControl: "3600", upsert: false });
          if (upErr) throw new Error(`截圖上傳失敗：${upErr.message}`);
        }
        imageUrl = sb.storage.from(BUCKET).getPublicUrl(`${base}.jpg`).data.publicUrl;
        previewUrl = sb.storage.from(BUCKET).getPublicUrl(`${base}_preview.jpg`).data.publicUrl;
      }

      const { status, result } = await callFn({
        action: "send",
        member_id: member.id,
        text: text.trim() || undefined,
        image_url: imageUrl,
        preview_url: previewUrl,
      });

      if (result.ok) {
        alert("已發送 ✓");
        setText("");
        setImage(null);
        onClose();
      } else {
        const parts = [result.message || result.error || `HTTP ${status}`];
        if (result.hint) parts.push(result.hint);
        // 後端沒能翻譯的錯誤，至少要把 LINE 的原文露出來
        if (result.detail && !result.message) parts.push(String(result.detail));
        setError(parts.join("\n"));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setSending(false);
    }
  }

  const canSend = !sending
    && reachable.state !== "checking"
    && reachable.state !== "not_configured"
    && (text.trim().length > 0 || !!image);

  return (
    <Modal open={open} onClose={onClose} title={`發送 LINE 訊息 — ${member.name ?? `#${member.member_no}`}`} maxWidth="max-w-lg">
      <div className="space-y-4">
        {/* 可達性預檢 */}
        {reachable.state === "checking" && (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-xs text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            檢查會員是否可接收 LINE 訊息…
          </div>
        )}
        {reachable.state === "ok" && (
          <div className="rounded-md border border-emerald-200 bg-emerald-50 p-2 text-xs text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-300">
            ✓ 可發送{reachable.displayName ? `（LINE 名稱：${reachable.displayName}）` : ""}
          </div>
        )}
        {reachable.state === "unreachable" && (
          <div className="rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-300">
            ⚠ {reachable.message}（仍可嘗試發送，但預期會失敗）
          </div>
        )}
        {(reachable.state === "not_configured" || reachable.state === "error") && (
          <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {reachable.message}
          </div>
        )}

        {/* 本月推播額度（只算主動推播；OA 後台 1:1 聊天不吃額度） */}
        {quota && (
          quota.limit !== null && quota.used >= quota.limit ? (
            <div className="rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
              本月推播額度已用完（{quota.used} / {quota.limit} 則），發送會失敗。額度每月 1 號重置；OA 後台 1:1 聊天不受影響。
            </div>
          ) : (
            <div className="text-xs text-zinc-500" title="只計算主動推播（此功能 / 群發）；官方帳號後台 1:1 聊天不吃額度">
              本月推播已用 {quota.used} / {quota.limit ?? "無上限"} 則
            </div>
          )
        )}

        {/* 目前配對到誰 + 綁錯人的退路。推得到也要顯示 —— 推得到但推錯人，
            正是最需要「解除」的情況（訊息會連同姓名、品項送到別人手機上）。 */}
        {bound && (
          <div className="flex flex-wrap items-center gap-2 rounded-md border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <span className="text-xs text-zinc-500">目前配對：</span>
            {bound.picture_url && (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={bound.picture_url} alt="" className="h-5 w-5 rounded-full object-cover" />
            )}
            <span className="text-xs font-medium">{followerLabel(bound)}</span>
            <SpinButton
              onClick={unbind}
              disabled={unbinding || binding !== null}
              className="ml-auto rounded-md border border-amber-300 px-2 py-1 text-[11px] text-amber-800 hover:bg-amber-50 disabled:opacity-50 dark:border-amber-800 dark:text-amber-300 dark:hover:bg-amber-950"
            >
              ↩ 不是這個人，解除配對
            </SpinButton>
          </div>
        )}

        {/* 推不到（或剛解除配對）+ 該店名冊有人 → 讓店員手動配對 */}
        {(reachable.state === "unreachable" || reachable.state === "error" || pickerOpen)
          && followers.length > 0 && (
          <div className="rounded-md border border-sky-200 bg-sky-50 p-2 dark:border-sky-900 dark:bg-sky-950/40">
            <div className="mb-1 text-xs font-medium text-sky-900 dark:text-sky-200">
              這位會員在本店官方帳號是哪一個？
            </div>
            <p className="mb-2 text-[11px] text-sky-800/80 dark:text-sky-300/80">
              以下是已加入本店官方帳號、但還沒對應到會員的人。選對之後就能發送；選錯了可以按上方的「解除配對」重選。
            </p>
            <div className="flex flex-wrap gap-2">
              {followers.map((f) => (
                <SpinButton
                  key={f.line_user_id}
                  disabled={binding !== null || unbinding}
                  onClick={() => bind(f)}
                  className="flex items-center gap-2 rounded-md border border-sky-300 bg-white px-2 py-1 text-xs hover:bg-sky-100 disabled:opacity-50 dark:border-sky-800 dark:bg-zinc-900 dark:hover:bg-sky-950"
                >
                  {f.picture_url && (
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={f.picture_url} alt="" className="h-5 w-5 rounded-full object-cover" />
                  )}
                  {followerLabel(f)}
                </SpinButton>
              ))}
            </div>
          </div>
        )}

        {/* 解除之後名冊沒有其他人可選：不講一句的話畫面等於什麼都沒發生 */}
        {pickerOpen && followers.length === 0 && (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 text-[11px] text-zinc-500 dark:border-zinc-800 dark:bg-zinc-900">
            已解除配對。本店官方帳號名冊裡目前沒有其他「還沒對應到會員」的人 ——
            請先請顧客在本店官方帳號傳一則訊息（webhook 收到才會進名冊），再回來配對。
          </div>
        )}

        {/* 免額度替代路徑：OA 後台 1:1 聊天室。額度用完時這條仍然能發。 */}
        {chat?.url && (
          <div className="rounded-md border border-zinc-200 bg-zinc-50 p-2 dark:border-zinc-800 dark:bg-zinc-900">
            <a
              href={chat.url}
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs font-medium text-sky-700 underline hover:text-sky-900 dark:text-sky-400 dark:hover:text-sky-300"
            >
              💬 在官方帳號後台開啟與此會員的 1:1 聊天 ↗
            </a>
            <p className="mt-1 text-[11px] text-zinc-500">
              後台聊天<strong className="font-semibold">不吃推播額度</strong>，但需另外登入 LINE 官方帳號後台。
            </p>
            {/* 聊天室網址也是用同一組 line_user_id 組的：profile 查不到（provider
                不一致）時，這條連結一樣會開到不存在的對話，不能讓它看起來可用 */}
            {reachable.state === "unreachable" && (
              <p className="mt-1 text-[11px] text-amber-700 dark:text-amber-400">
                ⚠ 此會員的 LINE ID 在這支官方帳號查不到，這條連結可能開不到正確的對話 —
                請改用官方帳號後台自行搜尋該顧客。
              </p>
            )}
            {chat.mode === "bot" && (
              <p className="mt-1 text-[11px] text-amber-700 dark:text-amber-400">
                ⚠ 此官方帳號目前是「Bot 模式」，後台聊天已關閉 —
                需先到官方帳號設定把回應方式改成「聊天模式」才能在後台回覆。
              </p>
            )}
          </div>
        )}

        {/* 樣板：填進 textarea 後仍可自由編輯再送 */}
        {ordersUrl && (
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-zinc-500">套用樣板：</span>
            {TEMPLATES.map((t) => (
              <SpinButton
                key={t.label}
                onClick={() => {
                  const next = t.build(ordersUrl);
                  // 已經打了字才確認，避免手滑蓋掉寫好的內容
                  if (text.trim() && !window.confirm("要用樣板取代目前已輸入的訊息嗎？")) return;
                  setText(next);
                }}
                className="rounded-md border border-zinc-300 px-2 py-1 text-xs hover:bg-zinc-100 dark:border-zinc-700 dark:hover:bg-zinc-800"
              >
                {t.label}
              </SpinButton>
            ))}
          </div>
        )}

        <label className="block text-sm">
          <span className="mb-1 block text-xs text-zinc-500">訊息內容</span>
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            rows={4}
            maxLength={5000}
            placeholder="輸入要發給會員的訊息…"
            className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm dark:border-zinc-700 dark:bg-zinc-900"
          />
        </label>

        <div>
          <span className="mb-1 block text-xs text-zinc-500">
            截圖 / 圖片（可直接 Ctrl+V 貼上）
          </span>
          {!imagePreview && (
            <SpinButton
              onClick={buildPickupImage}
              disabled={buildingImage}
              className="mb-2 mr-2 rounded-md border border-emerald-300 px-3 py-1.5 text-xs font-medium text-emerald-700 hover:bg-emerald-50 disabled:opacity-50 dark:border-emerald-800 dark:text-emerald-300 dark:hover:bg-emerald-950"
            >
              {buildingImage ? "產生中…" : "📋 帶入可取貨訂單圖"}
            </SpinButton>
          )}
          {imagePreview ? (
            <div className="relative inline-block">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={imagePreview} alt="附圖預覽" className="max-h-48 rounded-md border border-zinc-200 dark:border-zinc-800" />
              <SpinButton
                onClick={() => setImage(null)}
                aria-label="移除圖片"
                className="absolute -right-2 -top-2 rounded-full bg-zinc-700 px-1.5 py-0.5 text-xs text-white hover:bg-zinc-900"
              >
                ✕
              </SpinButton>
            </div>
          ) : (
            <SpinButton
              onClick={() => fileInputRef.current?.click()}
              className="rounded-md border border-dashed border-zinc-300 px-4 py-3 text-xs text-zinc-500 hover:bg-zinc-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
            >
              📎 選擇圖片或直接貼上截圖
            </SpinButton>
          )}
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={(e) => {
              const f = e.target.files?.[0];
              if (f) pickImage(f);
              e.target.value = "";
            }}
          />
        </div>

        {error && (
          <div className="whitespace-pre-wrap rounded-md border border-red-200 bg-red-50 p-2 text-xs text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300">
            {error}
          </div>
        )}

        <div className="flex justify-end gap-2">
          <SpinButton
            onClick={onClose}
            disabled={sending}
            className="rounded-md border border-zinc-300 px-4 py-2 text-sm hover:bg-zinc-100 disabled:opacity-50 dark:border-zinc-700 dark:hover:bg-zinc-800"
          >
            取消
          </SpinButton>
          <SpinButton
            onClick={send}
            disabled={!canSend}
            className="rounded-md bg-green-600 px-4 py-2 text-sm font-semibold text-white hover:bg-green-700 disabled:opacity-50"
          >
            {sending ? "發送中…" : "💬 發送"}
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}
