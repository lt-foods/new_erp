const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const repoRoot = path.resolve(__dirname, "../..");
const files = {
  inventory: "apps/admin/src/app/(protected)/inventory/page.tsx",
  shortage: "apps/admin/src/components/TransferShortageResolveModal.tsx",
  picking: "apps/admin/src/app/(protected)/wms/picking/page.tsx",
};

function validate(source) {
  assert.match(source.inventory, /const hqAvailable = Math\.max\(r\.on_hand - r\.reserved, 0\)/);
  assert.match(source.inventory, /帳上[\s\S]*凍結[\s\S]*可派/);
  assert.match(source.inventory, /commit\.free_with_pool/, "分店可分配仍須沿用客人承諾量口徑");

  assert.match(source.shortage, /其他已確認可派的好貨/);
  assert.match(source.shortage, /帳回不表示實物已到或已驗完/);
  assert.match(source.shortage, /其他可派貨不夠時，剩下的需求會保留/);
  assert.match(source.shortage, /role === "owner" \|\| role === "admin" \|\| role === "hq_manager"/);
  assert.match(source.shortage, /href="\/wms\/return-disposition"/);
  assert.match(source.shortage, /分店價和原本派車時不同[\s\S]*價差/);

  assert.match(source.picking, />HQ 可派<\/Th>/);
  assert.match(source.picking, /申請 \$\{ln\.demand_qty\}、可派 \$\{ln\.gr_qty\}、已撿/);
  assert.match(source.picking, /po\.gr_qty - po\.already_wave_for_sku/, "採購單到貨累計口徑不可被取代");
}

const current = Object.fromEntries(
  Object.entries(files).map(([key, file]) => [key, fs.readFileSync(path.join(repoRoot, file), "utf8")]),
);
validate(current);

const baseline = Object.fromEntries(
  Object.entries(files).map(([key, file]) => [
    key,
    execFileSync(
      "git",
      ["-c", `safe.directory=${repoRoot.replaceAll("\\", "/")}`, "-C", repoRoot, "show", `85c06f44:${file}`],
      { encoding: "utf8" },
    ),
  ]),
);
assert.throws(() => validate(baseline), "舊版必須被新口徑驗收擋下");

console.log("PASS F-UI：新版口徑通過，85c06f44 舊版如預期失敗");
