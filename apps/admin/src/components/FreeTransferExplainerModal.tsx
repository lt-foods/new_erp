"use client";

// 內部調撥運作說明 — 卡通動畫（循環 SVG，GIF 式自動播放）
// 三幕：1) 只有商品移動、不產生訂單  2) 舊庫存也能轉  3) 月結總倉當交易所一加一扣
// 進入 wms/transfers 自動彈出；勾「不再自動顯示」寫 localStorage。

import { useEffect, useState } from "react";
import { Modal } from "@/components/Modal";
import SpinButton from "@/components/SpinButton";

export const FT_EXPLAINER_HIDE_KEY = "freeTransferExplainerHide";

export default function FreeTransferExplainerModal({
  open,
  onClose,
}: {
  open: boolean;
  onClose: () => void;
}) {
  const [hide, setHide] = useState(false);

  useEffect(() => {
    if (!open) return;
    setHide(localStorage.getItem(FT_EXPLAINER_HIDE_KEY) === "1");
  }, [open]);

  const toggleHide = (v: boolean) => {
    setHide(v);
    if (v) localStorage.setItem(FT_EXPLAINER_HIDE_KEY, "1");
    else localStorage.removeItem(FT_EXPLAINER_HIDE_KEY);
  };

  return (
    <Modal open={open} onClose={onClose} title="🔄 內部調撥怎麼運作？" maxWidth="max-w-2xl">
      <div className="space-y-3">
        <ExplainerAnimation />
        <div className="flex flex-wrap items-center justify-between gap-2">
          <label className="flex cursor-pointer items-center gap-2 text-sm text-zinc-500">
            <input
              type="checkbox"
              checked={hide}
              onChange={(e) => toggleHide(e.target.checked)}
              className="h-4 w-4 rounded border-zinc-300"
            />
            進入頁面時不再自動顯示
          </label>
          <SpinButton
            onClick={onClose}
            className="rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 dark:bg-zinc-50 dark:text-zinc-900"
          >
            知道了
          </SpinButton>
        </div>
      </div>
    </Modal>
  );
}

// 12 秒循環、三幕各 4 秒。固定暖色畫布（漫畫格風格，深淺色模式皆同一張圖）。
function ExplainerAnimation() {
  return (
    <div className="overflow-hidden rounded-lg border border-zinc-200 dark:border-zinc-700">
      <svg viewBox="0 0 640 340" className="block w-full" role="img" aria-label="內部調撥運作說明動畫">
        <style>{`
          .s1, .s2, .s3 { animation: 12s linear infinite; }
          .s1 { animation-name: ftScene1; }
          .s2 { animation-name: ftScene2; }
          .s3 { animation-name: ftScene3; }
          @keyframes ftScene1 { 0%,30% { opacity: 1; } 33%,97% { opacity: 0; } 100% { opacity: 1; } }
          @keyframes ftScene2 { 0%,30% { opacity: 0; } 33%,63% { opacity: 1; } 66%,100% { opacity: 0; } }
          @keyframes ftScene3 { 0%,63% { opacity: 0; } 66%,97% { opacity: 1; } 100% { opacity: 0; } }

          .box1 { animation: ftBox1 12s linear infinite; }
          @keyframes ftBox1 {
            0%   { transform: translateX(0); opacity: 0; }
            4%   { opacity: 1; }
            8%   { transform: translateX(0); }
            22%  { transform: translateX(330px); opacity: 1; }
            26%  { transform: translateX(330px); opacity: 0; }
            100% { transform: translateX(330px); opacity: 0; }
          }
          .noOrder { animation: ftNoOrder 12s linear infinite; }
          @keyframes ftNoOrder {
            0%, 12% { opacity: 0; transform: scale(.6); transform-origin: 320px 210px; }
            16%, 30% { opacity: 1; transform: scale(1); transform-origin: 320px 210px; }
            33%, 100% { opacity: 0; }
          }

          .box2 { animation: ftBox2 12s linear infinite; }
          @keyframes ftBox2 {
            0%, 37%  { transform: translate(0,0) rotate(0deg); opacity: 0; }
            39%      { opacity: 1; transform: translate(0,-6px) rotate(-6deg); }
            42%      { transform: translate(6px,-14px) rotate(6deg); }
            45%      { transform: translate(12px,0) rotate(0deg); }
            58%      { transform: translate(330px,0) rotate(0deg); opacity: 1; }
            61%,100% { transform: translate(330px,0); opacity: 0; }
          }
          .dust { animation: ftDust 12s linear infinite; }
          @keyframes ftDust {
            0%, 38% { opacity: 0; }
            41%     { opacity: 1; }
            46%,100%{ opacity: 0; }
          }
          .spark { animation: ftSpark 12s linear infinite; }
          @keyframes ftSpark {
            0%, 56% { opacity: 0; transform: scale(.4); transform-origin: 500px 150px; }
            59%     { opacity: 1; transform: scale(1.1); transform-origin: 500px 150px; }
            62%,100%{ opacity: 0; }
          }

          .coin { animation: ftCoin 12s linear infinite; }
          @keyframes ftCoin {
            0%, 70%  { transform: translateX(0); opacity: 0; }
            72%      { opacity: 1; }
            80%      { transform: translateX(-155px); opacity: 1; }
            84%      { transform: translateX(-155px); opacity: 0; }
            86%      { transform: translateX(-155px); opacity: 1; }
            94%      { transform: translateX(-310px); opacity: 1; }
            96%,100% { transform: translateX(-310px); opacity: 0; }
          }
          .bill { animation: ftBill 12s linear infinite; }
          @keyframes ftBill {
            0%, 72% { opacity: 0; transform: translateY(6px); }
            78%,97% { opacity: 1; transform: translateY(0); }
            100%    { opacity: 0; }
          }

          .dotA { animation: ftDotA 12s linear infinite; }
          .dotB { animation: ftDotB 12s linear infinite; }
          .dotC { animation: ftDotC 12s linear infinite; }
          @keyframes ftDotA { 0%,30% { opacity: 1; } 33%,100% { opacity: .25; } }
          @keyframes ftDotB { 0%,30% { opacity: .25; } 33%,63% { opacity: 1; } 66%,100% { opacity: .25; } }
          @keyframes ftDotC { 0%,63% { opacity: .25; } 66%,97% { opacity: 1; } 100% { opacity: .25; } }
        `}</style>

        {/* 畫布 */}
        <rect x="0" y="0" width="640" height="340" fill="#fef6e9" />
        <rect x="0" y="288" width="640" height="52" fill="#f5e6cc" />

        {/* ===== 第一幕：商品移動、不產生訂單 ===== */}
        <g className="s1">
          <Shop x={60} label="店 A" body="#fcd34d" roof="#f59e0b" />
          <Shop x={470} label="店 B" body="#93c5fd" roof="#3b82f6" />
          {/* 移動的箱子 */}
          <g className="box1">
            <g transform="translate(120,196)">
              <rect x="0" y="0" width="46" height="34" rx="4" fill="#d97706" />
              <rect x="0" y="12" width="46" height="8" fill="#fbbf24" />
              <text x="23" y="26" textAnchor="middle" fontSize="16">📦</text>
            </g>
          </g>
          {/* 訂單 ✕ */}
          <g className="noOrder">
            <rect x="288" y="176" width="64" height="72" rx="6" fill="#ffffff" stroke="#d4d4d8" />
            <text x="320" y="196" textAnchor="middle" fontSize="12" fill="#52525b">訂單</text>
            <line x1="298" y1="206" x2="342" y2="206" stroke="#e4e4e7" strokeWidth="3" />
            <line x1="298" y1="218" x2="342" y2="218" stroke="#e4e4e7" strokeWidth="3" />
            <line x1="298" y1="230" x2="334" y2="230" stroke="#e4e4e7" strokeWidth="3" />
            <line x1="290" y1="180" x2="350" y2="244" stroke="#ef4444" strokeWidth="6" strokeLinecap="round" />
            <line x1="350" y1="180" x2="290" y2="244" stroke="#ef4444" strokeWidth="6" strokeLinecap="round" />
          </g>
          <text x="320" y="312" textAnchor="middle" fontSize="18" fontWeight="700" fill="#78350f">
            只有商品移動 — 不會產生任何訂單
          </text>
        </g>

        {/* ===== 第二幕：舊庫存也能轉 ===== */}
        <g className="s2">
          <Shop x={60} label="店 A" body="#fcd34d" roof="#f59e0b" />
          <Shop x={470} label="店 B" body="#93c5fd" roof="#3b82f6" />
          {/* 店A 的舊庫存疊箱 */}
          <g transform="translate(96,150)">
            <rect x="0" y="46" width="40" height="30" rx="3" fill="#a8a29e" />
            <rect x="6" y="16" width="40" height="30" rx="3" fill="#d6d3d1" />
            <text x="52" y="10" fontSize="14" fill="#78716c">💤</text>
            <rect x="-6" y="-8" width="58" height="18" rx="9" fill="#78716c" />
            <text x="23" y="5" textAnchor="middle" fontSize="11" fill="#fafaf9">舊庫存</text>
          </g>
          {/* 抖灰塵后滑過去的箱子 */}
          <g className="dust">
            <text x="150" y="180" fontSize="12" fill="#a8a29e">･ﾟ</text>
            <text x="168" y="168" fontSize="12" fill="#a8a29e">°･</text>
          </g>
          <g className="box2">
            <g transform="translate(120,196)">
              <rect x="0" y="0" width="46" height="34" rx="4" fill="#a16207" />
              <rect x="0" y="12" width="46" height="8" fill="#eab308" />
              <text x="23" y="26" textAnchor="middle" fontSize="16">📦</text>
            </g>
          </g>
          <g className="spark">
            <text x="486" y="150" fontSize="20">✨</text>
            <text x="516" y="136" fontSize="14">✨</text>
          </g>
          <text x="320" y="312" textAnchor="middle" fontSize="18" fontWeight="700" fill="#78350f">
            店裡的舊庫存，也能轉給需要的店
          </text>
        </g>

        {/* ===== 第三幕：月結總倉當交易所 ===== */}
        <g className="s3">
          <Shop x={40} label="店 A（出貨）" body="#fcd34d" roof="#f59e0b" small />
          <Shop x={510} label="店 B（收貨）" body="#93c5fd" roof="#3b82f6" small />
          {/* 總倉＝交易所（銀行風） */}
          <g transform="translate(258,150)">
            <polygon points="62,-26 0,6 124,6" fill="#64748b" />
            <rect x="6" y="6" width="112" height="82" fill="#94a3b8" />
            <rect x="18" y="22" width="12" height="66" fill="#e2e8f0" />
            <rect x="44" y="22" width="12" height="66" fill="#e2e8f0" />
            <rect x="70" y="22" width="12" height="66" fill="#e2e8f0" />
            <rect x="96" y="22" width="12" height="66" fill="#e2e8f0" />
            <rect x="26" y="-20" width="72" height="20" rx="10" fill="#334155" />
            <text x="62" y="-5" textAnchor="middle" fontSize="12" fill="#f8fafc">總倉＝交易所</text>
          </g>
          {/* 錢幣 店B → 總倉 → 店A */}
          <g className="coin">
            <g transform="translate(524,204)">
              <circle cx="0" cy="0" r="15" fill="#fbbf24" stroke="#d97706" strokeWidth="3" />
              <text x="0" y="6" textAnchor="middle" fontSize="15" fontWeight="700" fill="#92400e">$</text>
            </g>
          </g>
          {/* 兩張月結帳單 */}
          <g className="bill">
            <rect x="42" y="120" width="96" height="34" rx="8" fill="#dcfce7" stroke="#22c55e" />
            <text x="90" y="142" textAnchor="middle" fontSize="14" fontWeight="700" fill="#15803d">月結 −$100</text>
            <rect x="502" y="120" width="96" height="34" rx="8" fill="#ffe4e6" stroke="#f43f5e" />
            <text x="550" y="142" textAnchor="middle" fontSize="14" fontWeight="700" fill="#be123c">月結 +$100</text>
          </g>
          <text x="320" y="312" textAnchor="middle" fontSize="18" fontWeight="700" fill="#78350f">
            月結時總倉幫你記帳：收貨店加、出貨店扣
          </text>
        </g>

        {/* 進度點 */}
        <circle className="dotA" cx="596" cy="24" r="5" fill="#f59e0b" />
        <circle className="dotB" cx="612" cy="24" r="5" fill="#f59e0b" />
        <circle className="dotC" cx="628" cy="24" r="5" fill="#f59e0b" />
      </svg>
    </div>
  );
}

// 小房子（卡通店面）
function Shop({
  x,
  label,
  body,
  roof,
  small = false,
}: {
  x: number;
  label: string;
  body: string;
  roof: string;
  small?: boolean;
}) {
  const w = small ? 86 : 110;
  const h = small ? 66 : 84;
  const y = 240 - h;
  return (
    <g transform={`translate(${x},${y})`}>
      <rect x="0" y="0" width={w} height={h} rx="6" fill={body} />
      <polygon points={`${-10},0 ${w / 2},${small ? -26 : -34} ${w + 10},0`} fill={roof} />
      {/* 門 + 窗 */}
      <rect x={w / 2 - 11} y={h - 30} width="22" height="30" rx="3" fill="#7c2d12" opacity=".75" />
      <rect x={10} y={14} width={w / 2 - 26} height="18" rx="3" fill="#ffffff" opacity=".7" />
      <rect x={w / 2 + 16} y={14} width={w / 2 - 26} height="18" rx="3" fill="#ffffff" opacity=".7" />
      <text x={w / 2} y={h + 22} textAnchor="middle" fontSize="14" fontWeight="700" fill="#57534e">
        {label}
      </text>
    </g>
  );
}
