"use client";

import { useState } from "react";
import { callLiffApi } from "@/lib/supabase";
import { saveSession } from "@/lib/session";
import { logCaught, reportLogsToBackend } from "@/lib/clientLog";
import { LINE_BROWSER_HINT } from "@/lib/lineAuth";
import { useLineLogin } from "@/lib/useLineLogin";
import Spinner, { LoadingScreen } from "@/components/Spinner";

/**
 * 首頁 = 登入頁。
 *
 * 登入本身的所有分支（LIFF 自動登入、LINE 內建瀏覽器、PWA 配對…）都在
 * useLineLogin 裡，這裡只負責畫面與「驗證碼手動同步」這條退路。
 */
export default function LandingPage() {
  const {
    status, setStatus,
    error, setError,
    storeId, chooseStore, stores,
    standalone, lineStuck, pwaLoginUrl, canRetryLiff,
    start, retryLiffLogin,
  } = useLineLogin();

  const [inputStoreId, setInputStoreId] = useState("");
  const [linkCopied, setLinkCopied] = useState(false);
  /** 驗證碼是退路，預設收起來，不跟「用 LINE 登入」並列 */
  const [showSyncCode, setShowSyncCode] = useState(false);
  const [reportState, setReportState] = useState<"idle" | "sending" | "sent" | "failed">("idle");

  // 6 位數驗證碼 fallback
  const [syncCode, setSyncCode] = useState("");
  const [syncing, setSyncing] = useState(false);

  /** 把本機錯誤紀錄整包送到後端（client_error_logs 的 user_report），給客服後續分析 */
  const reportProblem = async () => {
    if (reportState === "sending") return;
    setReportState("sending");
    const ok = await reportLogsToBackend(error ?? undefined);
    setReportState(ok ? "sent" : "failed");
  };

  /** 卡在 LINE 內建瀏覽器時唯一的出路：把網址帶去外部瀏覽器 */
  const copyLoginLink = async () => {
    const url = storeId
      ? `${window.location.origin}/?store=${encodeURIComponent(storeId)}`
      : window.location.origin;
    try {
      await navigator.clipboard.writeText(url);
      setLinkCopied(true);
      setTimeout(() => setLinkCopied(false), 3000);
    } catch (e) {
      // LINE webview 常擋剪貼簿 —— 退回顯示網址讓使用者自己長按複製
      logCaught("copy_login_link_failed", e, { store: storeId });
      setError(`請手動開啟：${url}`);
    }
  };

  const handleManualStoreSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const s = inputStoreId.trim().toUpperCase();
    if (!s) return;
    chooseStore(s);
  };

  const handleSyncSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (syncCode.length !== 6 || syncing) return;

    setSyncing(true);
    setError(null);
    try {
      const data = await callLiffApi<{
        token: string;
        store: string;
        member_id: number;
        line_user_id: string;
        line_name: string | null;
        line_picture: string | null;
      }>("", { action: "claim_pwa_auth_code", code: syncCode });

      saveSession({
        token:       data.token,
        storeId:     data.store,
        memberId:    data.member_id,
        lineUserId:  data.line_user_id,
        lineName:    data.line_name,
        linePicture: data.line_picture,
      });
      window.location.href = "/shop";
    } catch (e) {
      logCaught("pwa_sync_code_failed", e);
      setError(e instanceof Error ? e.message : "驗證碼無效或已過期");
    } finally {
      setSyncing(false);
    }
  };

  return (
    <main className="mx-auto flex min-h-[100dvh] w-full max-w-md flex-col items-center px-6 pb-10 pt-12">
      {/* 品牌主視覺：店家實際 banner（含 logo + 店名 + 服務項目） */}
      <div className="w-full overflow-hidden rounded-[20px] shadow-[0_18px_40px_-14px_rgba(158,47,80,0.42)]">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src="/brand/banner.jpg"
          alt="包子媽生鮮小舖 — 新鮮直送・社區團購"
          className="block w-full"
        />
      </div>

      <div className="mt-9 w-full">
        {status === "loading" && <LoadingScreen className="py-14" />}

        {status === "liff_auth" && <LoadingScreen className="py-14" />}

        {status === "pwa_waiting" && (
          <div className="card space-y-4 p-6 text-center">
            <Spinner size={28} />
            <p className="text-[17px] font-bold text-[var(--foreground)]">
              請完成 LINE 登入
            </p>
            <p className="text-[14px] leading-relaxed text-[var(--secondary-label)]">
              完成後請回到本 App，我們會自動帶您進入，不需要輸入任何驗證碼。
            </p>
            {/* 回來的路不只一條，而使用者不見得找得到 —— 明講兩種。
                改走 OAuth 後多數情況是在瀏覽器視窗完成，關掉即可回到這裡 */}
            <div className="w-full rounded-xl bg-[var(--fill-quaternary,rgba(120,120,128,0.08))] p-3 text-left text-[13px] leading-relaxed text-[var(--secondary-label)]">
              回來的方式：
              <br />
              1. 點登入畫面左上角的「✕」或「◀」關閉
              <br />
              2. 或從手機桌面重新點開本 App
            </div>
            {/* LINE 沒被開起來時的自救 —— 沒有這顆就只能乾等，
                而使用者無從判斷是「還沒好」還是「根本沒開」 */}
            {pwaLoginUrl && (
              <a
                href={pwaLoginUrl}
                className="block w-full rounded-xl bg-[#06C755] px-4 py-3 text-[15px] font-semibold text-white transition active:scale-[0.98]"
              >
                登入畫面沒開啟？點這裡再試一次
              </a>
            )}
            <button
              onClick={() => setStatus("idle")}
              className="text-[14px] font-medium text-[var(--secondary-label)] underline underline-offset-4"
            >
              返回
            </button>
          </div>
        )}

        {status === "pair_done" && (
          <div className="card p-6 text-center">
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-[#06C755]/12 text-[28px] text-[#06C755]">
              ✓
            </div>
            <p className="mt-3 text-[17px] font-bold text-[var(--foreground)]">登入完成</p>
            {/* 「PWA 圖示」是黑話，會員看不懂；而且回去的路有兩條，都要講 */}
            <p className="mt-2 text-left text-[14px] leading-relaxed text-[var(--secondary-label)]">
              請回到「包子媽生鮮小舖」App：
              <br />
              1. 點左上角的「◀ 包子媽生鮮小舖」
              <br />
              2. 或關閉 LINE，從手機桌面重新點開本 App
            </p>
          </div>
        )}

        {status === "idle" && (
          <div className="w-full space-y-5">
            {error && (
              <div className="w-full space-y-2 rounded-2xl bg-[var(--ios-red)]/10 p-3 text-left text-[14px] text-[#c4271d]">
                <p>發生錯誤：{error}</p>
                <button
                  onClick={reportProblem}
                  disabled={reportState === "sending"}
                  className="w-full rounded-lg border border-[#c4271d]/30 px-3 py-2 text-[13px] font-semibold text-[#c4271d] transition active:scale-[0.98] disabled:opacity-60"
                >
                  {reportState === "sending" && "傳送中…"}
                  {reportState === "sent" && "✓ 已傳送，客服會盡快處理"}
                  {reportState === "failed" && "傳送失敗，請截圖給客服"}
                  {reportState === "idle" && "回報此問題給客服"}
                </button>
              </div>
            )}

            {!storeId ? (
              <div className="card space-y-4 p-5">
                <p className="text-[15px] font-medium text-[var(--foreground)]">
                  歡迎！請選擇您的門市以開始
                </p>
                <form onSubmit={handleManualStoreSubmit} className="flex flex-col gap-3">
                  {stores.length > 0 ? (
                    <select
                      value={inputStoreId}
                      onChange={(e) => setInputStoreId(e.target.value)}
                      className="w-full appearance-none rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] text-[var(--foreground)] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                      required
                      autoFocus
                    >
                      <option value="" disabled>請選擇門市…</option>
                      {stores.map((s) => (
                        <option key={s.id} value={s.code}>
                          {s.name}（{s.code}）
                        </option>
                      ))}
                    </select>
                  ) : (
                    <input
                      type="text"
                      placeholder="例如: S001"
                      value={inputStoreId}
                      onChange={(e) => setInputStoreId(e.target.value)}
                      className="w-full rounded-xl border border-[var(--separator)] bg-[var(--background)] px-4 py-3 text-[16px] focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                      autoFocus
                    />
                  )}
                  <button
                    type="submit"
                    disabled={!inputStoreId}
                    className="w-full rounded-xl brand-gradient px-4 py-3 text-[16px] font-semibold text-white shadow-[0_10px_24px_-10px_rgba(158,47,80,0.6)] transition active:scale-[0.98] disabled:opacity-40"
                  >
                    進入門市
                  </button>
                </form>
              </div>
            ) : (
              <div className="space-y-6">
                <div className="card space-y-4 p-5 text-center">
                  <p className="text-[15px] text-[var(--secondary-label)]">
                    您目前位於{" "}
                    <span className="font-bold text-[var(--brand-strong)]">
                      {stores.find((s) => s.code === storeId)?.name ?? storeId}
                    </span>{" "}
                    門市
                  </p>
                  {lineStuck ? (
                    <div className="space-y-3 text-left">
                      <p className="text-[14px] leading-relaxed text-[var(--foreground)]">
                        {LINE_BROWSER_HINT}
                      </p>
                      <button
                        onClick={copyLoginLink}
                        className="w-full rounded-xl brand-gradient px-4 py-3 text-[15px] font-semibold text-white transition active:scale-[0.98]"
                      >
                        {linkCopied ? "已複製，請貼到瀏覽器開啟" : "複製本頁連結"}
                      </button>
                      {canRetryLiff && (
                        <button
                          onClick={retryLiffLogin}
                          className="w-full rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[14px] font-medium text-[var(--secondary-label)] transition active:scale-[0.98]"
                        >
                          仍要在 LINE 內再試一次
                        </button>
                      )}
                      <button
                        onClick={reportProblem}
                        disabled={reportState === "sending"}
                        className="w-full rounded-xl border border-[var(--separator)] px-4 py-2.5 text-[14px] font-medium text-[var(--secondary-label)] transition active:scale-[0.98] disabled:opacity-60"
                      >
                        {reportState === "sending" && "傳送中…"}
                        {reportState === "sent" && "✓ 已回報，客服會盡快處理"}
                        {reportState === "failed" && "回報失敗，請截圖給客服"}
                        {reportState === "idle" && "回報此問題給客服"}
                      </button>
                    </div>
                  ) : (
                    <button
                      onClick={start}
                      className="flex w-full items-center justify-center gap-2 rounded-xl bg-[#06C755] px-4 py-3.5 text-[16px] font-semibold text-white shadow-[0_10px_24px_-10px_rgba(6,199,85,0.7)] transition active:scale-[0.98]"
                    >
                      <svg viewBox="0 0 24 24" fill="currentColor" className="h-5 w-5">
                        <path d="M12 3C6.5 3 2 6.6 2 11c0 3.9 3.5 7.2 8.3 7.9.3.06.7.2.8.45.08.23.05.58.03.81l-.13.8c-.04.24-.19.93.81.51 1-.42 5.4-3.2 7.36-5.47C20.5 14.5 22 12.9 22 11c0-4.4-4.5-8-10-8Z" />
                      </svg>
                      {standalone ? "用 LINE 登入" : "用 LINE 註冊 / 登入"}
                    </button>
                  )}
                  {standalone && (
                    <p className="text-[12px] text-[var(--tertiary-label)]">
                      將開啟 LINE 登入頁，完成後自動回到此 App。
                    </p>
                  )}
                </div>

                {/* 驗證碼是「自動配對失敗」時的救命繩，不是並列的登入選項。
                    平鋪出來會讓會員以為登入本來就要打一組碼 —— 而那段流程
                    （自己先去瀏覽器登入、記下 6 碼、切回來輸入）對一般人根本走不完。
                    預設收起來，只有真的卡住的人才會展開。 */}
                {standalone && !showSyncCode && (
                  <button
                    onClick={() => setShowSyncCode(true)}
                    className="mx-auto block text-[13px] text-[var(--tertiary-label)] underline underline-offset-4"
                  >
                    登入遇到問題？用驗證碼手動同步
                  </button>
                )}

                {standalone && showSyncCode && (
                  <>
                    <div className="card space-y-3 p-5">
                      <p className="text-[14px] text-[var(--secondary-label)]">
                        僅在自動登入失敗時需要：請先用手機瀏覽器開啟本站登入，
                        再把該畫面顯示的 6 位數驗證碼輸入這裡。
                      </p>
                      <form onSubmit={handleSyncSubmit} className="flex gap-2">
                        <input
                          type="text"
                          inputMode="numeric"
                          pattern="[0-9]*"
                          maxLength={6}
                          placeholder="6 位數驗證碼"
                          value={syncCode}
                          onChange={(e) => setSyncCode(e.target.value)}
                          className="flex-1 rounded-xl border border-[var(--separator)] bg-[var(--background)] px-3 py-2.5 text-center font-mono text-xl tracking-widest focus:border-[var(--brand)] focus:outline-none focus:ring-2 focus:ring-[var(--brand-soft)]"
                        />
                        <button
                          type="submit"
                          disabled={syncCode.length !== 6 || syncing}
                          className="flex items-center justify-center gap-2 rounded-xl brand-gradient px-5 py-2.5 text-[15px] font-semibold text-white transition active:scale-[0.97] disabled:opacity-40"
                        >
                          {syncing ? <Spinner size={16} onColor /> : "驗證"}
                        </button>
                      </form>
                    </div>
                  </>
                )}

                <button
                  onClick={() => { chooseStore(null); setInputStoreId(""); }}
                  className="mx-auto block text-[14px] font-medium text-[var(--secondary-label)] underline underline-offset-4"
                >
                  更換其他門市
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      <div className="mt-auto pt-10 text-center text-[12px] text-[var(--tertiary-label)]">
        <p className="font-medium">包子媽生鮮小舖</p>
        <p className="mt-0.5 tracking-wide">Baozi Ma Group Buying</p>
      </div>
    </main>
  );
}
