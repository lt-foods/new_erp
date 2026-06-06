# member-app — Capacitor 原生殼（iOS / Android）

把 `apps/member`（Next.js PWA）的**靜態輸出**包成原生 App，上 App Store / Google Play。
前端程式碼**唯一真實來源**仍是 `apps/member`，這裡只放原生殼設定與平台專案。

> ⚠️ 本資料夾的 `cap add ios` / 簽章 / 送審等步驟**需要 macOS + Xcode**（iOS）與
> Android SDK（Android），無法在純 Linux CI 容器完成。以下標出哪些要在 dev 機跑。

---

## 架構

```
apps/
  member/       ← Next.js 前端（build:export → out/ 靜態輸出）
  member-app/   ← 本資料夾：Capacitor 殼
    capacitor.config.ts   appId=com.baozima.member, webDir=../member/out
    ios/        ← cap add ios 後產生（在 Mac 上）
    android/    ← cap add android 後產生
```

- **不用 `server.url` 指遠端網站**：Apple App Review 4.2 會把「純網站殼」退件，
  所以一律把 `apps/member/out` 靜態資源 bundle 進原生專案。
- 推播走原生：iOS → APNs、Android → FCM（見下方）。前端推播抽象層在
  `apps/member/src/lib/nativePush.ts` + `platform.ts`，於 `usePushNotification.ts` 分流。

---

## 首次建置（dev 機）

```bash
# 0) 安裝相依（monorepo 根目錄）
npm install

# 1) 產生前端靜態輸出（任何平台都可）
npm run build:web --workspace member-app      # = member 的 build:export，產出 apps/member/out

# 2) 加平台（iOS 需 macOS + Xcode + CocoaPods）
cd apps/member-app
npm run add:ios        # 產生 ios/（僅 macOS）
npm run add:android    # 產生 android/

# 3) 同步靜態資源 + 外掛到原生專案
npm run sync           # = build:web && cap sync

# 4) 開原生 IDE 出包 / 跑模擬器
npm run open:ios       # Xcode（簽章、TestFlight、App Store）
npm run open:android   # Android Studio（簽章、Play）
```

之後每次改前端：`npm run sync` 再回 IDE build 即可。

---

## 推播設定（上線必做，dev 機）

### Android — FCM
1. Firebase 專案 → 下載 `google-services.json` 放到 `android/app/`。
2. 後端發送 secret：`FCM_SERVICE_ACCOUNT_JSON`（service account 私鑰）。

### iOS — APNs
1. Apple Developer → 建 APNs Key（.p8），記下 Key ID / Team ID。
2. Xcode 開啟 Push Notifications + Background Modes(Remote notifications) capability。
3. 後端發送 secret：`APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_BUNDLE_ID`。

> 前端訂閱流程已完成：原生平台會自動走 `registerNativePush()`，
> 拿到 device token 後呼叫 `liff-api: upsert_push_subscription`，
> 帶 `provider=fcm|apns`、`device_token`、`platform`，寫入 `push_subscriptions`
> （DB migration：`supabase/migrations/20260606120000_push_subscriptions_native.sql`）。

**尚未完成（後端發送端）**：通知發送目前只有 `web-push`（VAPID）。
需在通知發送 Edge Function 依 `provider` 分流到 FCM / APNs，
並在收到 token 失效（FCM `NotRegistered` / APNs `Unregistered` / HTTP 410）時停用該筆。
詳見 `docs/PRD-行動App-Capacitor.md` §5.4。

---

## 上架前清單

| 平台 | 項目 |
|------|------|
| iOS | Apple Developer($99/年)、App ID、APNs Key、App Privacy 標籤、隱私權政策 URL、**app 內刪帳號** |
| Android | Play Console($25 一次)、App signing、`google-services.json`、Data safety 表單、隱私權政策 |
| 共同 | app icon / splash、版本號、深連結（推播點擊跳頁）、TestFlight / Play 內測軌道 |

詳細規劃見 `docs/PRD-行動App-Capacitor.md`。
</content>
