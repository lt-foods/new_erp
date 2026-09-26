import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const read = (path) => readFileSync(resolve(root, path), "utf8");
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

function stageErrors(source) {
  const errors = [];
  const stageFunction = source.match(/export function aidStageLabel[\s\S]*?\n}/)?.[0] ?? "";
  const grouped = /case "ready":\s*case "partially_completed":\s*case "completed":\s*return "收貨完成・這筆轉貨已結束";/;
  if (!grouped.test(stageFunction)) errors.push("ready / partially_completed / completed 必須合併為同一中性文字");
  if (stageFunction.includes("對方店")) errors.push("共用階段文字不得假設目前使用者是轉出店");
  return errors;
}

function inboundErrors(source) {
  const errors = [];
  if (source.includes("補回先墊")) errors.push("不得殘留「補回先墊」");
  if (!/<Pill tone="violet">🔄 \{g\.prefilledQty\} 件補回店內庫存・不用留給客人<\/Pill>/.test(source)) {
    errors.push("群組膠囊必須直接說不用留給客人");
  }
  if (!/>\s*客人已先拿到，收貨後直接放回店裡，不用再留貨\s*</.test(source)) {
    errors.push("明細必須有手機直接看得到的放回庫存說明");
  }
  const receivedOnly = /const receivedTransferIds = new Set\(\s*rows\.filter\(\(t\) => t\.status === "received"\)\.map\(\(t\) => t\.id\),?\s*\);[\s\S]*?if \(receivedTransferIds\.has\(it\.transfer_id\)\) \{\s*cur\.receiveOverQty \+= Math\.max\(0, receivedQty - qty\);\s*cur\.receiveShortQty \+= Math\.max\(0, qty - receivedQty\);\s*\}/;
  if (!receivedOnly.test(source)) errors.push("實收多少只能對 status=received 的調撥單計算");
  return errors;
}

function mutate(source, from, to, name) {
  const mutated = source.replace(from, to);
  assert(mutated !== source, `無法建立錯誤突變：${name}`);
  return mutated;
}

const stages = read("apps/admin/src/lib/aidTransfer.ts");
const inbound = read("apps/admin/src/app/(protected)/wms/inbound/page.tsx");
assert(stageErrors(stages).length === 0, stageErrors(stages).join("\n"));
assert(inboundErrors(inbound).length === 0, inboundErrors(inbound).join("\n"));

const splitStages = mutate(stages, 'case "partially_completed":\n    case "completed":', 'case "partially_completed":\n      return "收貨店已部分取貨";\n    case "completed":', "三種狀態拆開");
assert(stageErrors(splitStages).length > 0, "檢查未擋下三種下游狀態被拆開的錯版");

const outboundOnlyCopy = mutate(stages, "收貨完成・這筆轉貨已結束", "對方店已收貨・轉貨完成", "轉出店視角文字");
assert(stageErrors(outboundOnlyCopy).length > 0, "檢查未擋下共用畫面顯示「對方店」的錯版");

const oldCopy = mutate(inbound, "件補回店內庫存", "補回先墊", "舊補回文字");
assert(inboundErrors(oldCopy).length > 0, "檢查未擋下舊「補回先墊」文字");

const pendingAsShort = mutate(inbound, "if (receivedTransferIds.has(it.transfer_id)) {", "if (true) {", "待收也計算實收短少");
assert(inboundErrors(pendingAsShort).length > 0, "檢查未擋下待收單被誤算實收短少");

console.log("Store-friendly transfer copy check passed, including 4 mutation counterexamples.");
