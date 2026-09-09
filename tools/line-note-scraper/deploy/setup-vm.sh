#!/usr/bin/env bash
# 在一台全新的 Ubuntu 22.04 / 24.04 VM 上一鍵裝好 worker（Docker + compose + 開機自啟）。
#
#   curl -fsSL https://raw.githubusercontent.com/lt-foods/new_erp/main/tools/line-note-scraper/deploy/setup-vm.sh | bash
#   （或先 clone 再 bash tools/line-note-scraper/deploy/setup-vm.sh）
#
# 跑完會停在「請填 .env」；填好再 `docker compose up -d --build`。
# 建議機器放台灣（GCP asia-east1 彰化 e2-micro 就夠），LINE 帳號從國外 IP 上線容易被鎖。
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/lt-foods/new_erp.git}"
APP_DIR="${APP_DIR:-$HOME/new_erp}"
SUB="tools/line-note-scraper"

echo "▶ 安裝 Docker"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" || true
fi
sudo systemctl enable --now docker

echo "▶ 取得程式碼 → $APP_DIR"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi
cd "$APP_DIR/$SUB"

if [ ! -f .env ]; then
  cp .env.example .env
  echo
  echo "⚠ 請先填 $APP_DIR/$SUB/.env 的 SUPABASE_URL 與 SUPABASE_SERVICE_ROLE_KEY，然後："
  echo "    cd $APP_DIR/$SUB && docker compose up -d --build && docker compose logs -f"
  exit 0
fi

echo "▶ 啟動 worker"
sudo docker compose up -d --build
sudo docker compose logs --tail=20
echo
echo "✔ 跑起來了。看 log：cd $APP_DIR/$SUB && docker compose logs -f"
echo "  更新程式：cd $APP_DIR && git pull && cd $SUB && docker compose up -d --build"
