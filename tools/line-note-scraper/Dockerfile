# line-notes worker：常駐程序，輪詢 Supabase 佇列、跟 LINE 講話。
# 只需要 Node 22；sharp（PNG→JPEG）有 linux-x64 prebuilt，不用另裝 libvips。
FROM node:22-slim

WORKDIR /app
ENV NODE_ENV=production

# 先裝相依（.npmrc 把 @jsr 指到 npm.jsr.io，一定要跟著進來）
COPY package.json .npmrc ./
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

# LINE token 存這裡；一定要掛 volume，不然重啟就要重掃 QR
VOLUME ["/app/storage"]
ENV LINE_STORAGE_DIR=/app/storage

# 跟 .env 無關：雲端用平台的環境變數（SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY）
CMD ["node", "src/worker.mjs"]
