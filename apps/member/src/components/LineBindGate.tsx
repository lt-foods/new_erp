"use client";

// 限量商品下單前的「店家 LINE 綁定」彈窗。
//
// 觸發：place_member_order 回 code === "line_binding_required"。
// 流程：start_line_binding 拿綁定碼 → 開店家 OA 對話（訊息已預填）→ 會員按
// 送出（順手加了好友）→ line-webhook 完成綁定 → 這裡輪詢到 bound=true →
// onBound()（呼叫端自動重送訂單）。會員視角：按一次「前往 LINE」再按一次
// 「送出」，回來訂單自己完成 —— 不需要理解「綁定」是什麼。
//
// 沒辦法真的全程無感：LINE 不允許替使用者加好友 / 代發訊息，
// 「預填好、按一下送出」已是平台允許的最短路徑。

import { useCallback, useEffect, useRef, useState } from "react";
import { getSession } from "@/lib/session";
import { callLiffApi } from "@/lib/supabase";
import { openLineOaChat } from "@/lib/lineInquiry";
import { logCaught } from "@/lib/clientLog";
import Spinner from "@/components/Spinner";

type StartResp = {
  bound: boolean;
  code?: string;
  oa_id?: string | null;
  store_name?: string | null;
  message_text?: string;
};

type StateResp = { bound: boolean; bindable: boolean };

export default function LineBindGate({
  storeId,
  onBound,
  onClose,
}: {
  storeId: number;
  /** 綁定完成（含「其實早就綁好」）。呼叫端拿到這個訊號後自動重送訂單 */
  onBound: () => void;
  onClose: () => void;
}) {
  const [info, setInfo] = useState<StartResp | null>(null);
  const [waiting, setWaiting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // onBound 只能發一次：輪詢與 visibilitychange 可能同時命中
  const firedRef = useRef(false);

  const fireBound = useCallback(() => {
    if (firedRef.current) return;
    firedRef.current = true;
    onBound();
  }, [onBound]);

  // 進場就發碼（已綁定的話後端直接回 bound=true，彈窗一閃而過）
  useEffect(() => {
    const s = getSession();
    if (!s) return;
    (async () => {
      try {
        const r = await callLiffApi<StartResp>(s.token, {
          action: "start_line_binding",
          store_id: storeId,
        });
        if (r.bound) {
          fireBound();
          return;
        }
        setInfo(r);
      } catch (e) {
        // 會員只會卡在這個彈窗裡，一定要留 log（clientLog 規則）
        logCaught("start_line_binding_failed", e, { store_id: storeId });
        setError(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [storeId, fireBound]);

  // 輪詢綁定狀態；切回前景（從 LINE 回來的那一刻）立刻補查一次
  useEffect(() => {
    const s = getSession();
    if (!s) return;
    let stopped = false;
    const check = async () => {
      try {
        const r = await callLiffApi<StateResp>(s.token, {
          action: "get_line_bind_state",
          store_id: storeId,
        });
        if (!stopped && r.bound) fireBound();
      } catch {
        // 輪詢失敗下一輪再試；不打擾使用者
      }
    };
    const timer = window.setInterval(check, 3000);
    const onVisible = () => {
      if (document.visibilityState === "visible") void check();
    };
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);
    return () => {
      stopped = true;
      window.clearInterval(timer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
    };
  }, [storeId, fireBound]);

  const goLine = async () => {
    if (!info?.oa_id || !info.message_text) return;
    setWaiting(true);
    await openLineOaChat(info.oa_id, info.message_text);
  };

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center bg-black/50 px-6">
      <div className="w-full max-w-sm rounded-2xl bg-white p-6 text-center">
        <div className="text-5xl">🔒</div>
        <h3 className="mt-3 text-[20px] font-bold text-[var(--foreground)]">
          限量商品需要綁定店家 LINE
        </h3>

        {error ? (
          <p className="mt-3 text-[14px] text-red-600">{error}</p>
        ) : !info ? (
          <div className="mt-5 flex justify-center"><Spinner /></div>
        ) : (
          <>
            <p className="mt-2 text-[14px] leading-relaxed text-[var(--secondary-label)]">
              限量商品到貨與訂單通知會從
              {info.store_name ? `「${info.store_name}」` : "店家"}
              的 LINE 發送。點下方按鈕開啟 LINE，
              <span className="font-semibold text-[var(--foreground)]">
                把已填好的訊息按「送出」
              </span>
              就完成綁定，回來會自動繼續下單。
            </p>

            <button
              onClick={goLine}
              className="mt-5 w-full rounded-xl bg-[#06C755] py-3.5 text-[16px] font-bold text-white active:opacity-80"
            >
              前往 LINE 完成綁定
            </button>

            {waiting && (
              <div className="mt-3 flex items-center justify-center gap-2 text-[13px] text-[var(--secondary-label)]">
                <Spinner />
                等待綁定完成…送出訊息後回到這裡即可
              </div>
            )}
          </>
        )}

        <button
          onClick={onClose}
          className="mt-4 w-full rounded-xl bg-[#7676801f] py-3 text-[15px] font-medium text-[var(--foreground)] active:bg-[#76768033]"
        >
          先不要，返回
        </button>
      </div>
    </div>
  );
}
