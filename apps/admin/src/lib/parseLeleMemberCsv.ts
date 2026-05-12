"use client";

import Papa from "papaparse";

export type LeleMemberRow = {
  external_id: string;
  name_raw: string;
  label: string;
  joined_at: string;
  last_visit_at: string;
  wallet_balance: string;
};

export type ParseResult =
  | { ok: true; rows: LeleMemberRow[]; totalLines: number }
  | { ok: false; error: string };

const HEADERS = {
  external_id: "顧客代號",
  name_raw: "名字",
  label: "標籤",
  joined_at: "加入日期",
  last_visit_at: "最後登入",
  wallet_balance: "錢包餘額",
} as const;

export async function parseLeleMemberCsv(file: File): Promise<ParseResult> {
  return new Promise((resolve) => {
    Papa.parse<string[]>(file, {
      skipEmptyLines: true,
      complete(result) {
        if (result.errors.length) {
          const e = result.errors[0];
          resolve({ ok: false, error: `CSV 解析錯誤 (row ${e.row}): ${e.message}` });
          return;
        }
        const rows = result.data;
        if (!rows.length) {
          resolve({ ok: false, error: "CSV 是空的" });
          return;
        }

        const header = rows[0];
        const idx: Partial<Record<keyof typeof HEADERS, number>> = {};
        const missing: string[] = [];
        for (const [k, h] of Object.entries(HEADERS) as [keyof typeof HEADERS, string][]) {
          const i = header.findIndex((c) => (c ?? "").trim() === h);
          if (i < 0) missing.push(h);
          else idx[k] = i;
        }
        if (missing.length) {
          resolve({ ok: false, error: `CSV 缺欄位：${missing.join("、")}` });
          return;
        }

        const out: LeleMemberRow[] = [];
        for (let i = 1; i < rows.length; i++) {
          const r = rows[i];
          const externalId = (r[idx.external_id!] ?? "").trim();
          if (!externalId) continue;
          out.push({
            external_id: externalId,
            name_raw: r[idx.name_raw!] ?? "",
            label: r[idx.label!] ?? "",
            joined_at: r[idx.joined_at!] ?? "",
            last_visit_at: r[idx.last_visit_at!] ?? "",
            wallet_balance: r[idx.wallet_balance!] ?? "",
          });
        }
        resolve({ ok: true, rows: out, totalLines: rows.length - 1 });
      },
      error(err) {
        resolve({ ok: false, error: err.message });
      },
    });
  });
}

export function downloadLeleTemplate() {
  const header = '"全選","","","顧客代號","名字","標籤","未配單","已配未結單","未付款","未寄出","區間金額","錢包餘額","未結單$","最後登入","加入日期",""\n';
  const sample = '"","","","18267783","#18267783 : 【範例顧客】123456-永和","永和","0","0","0筆","0筆","－","0","0","2026-05-12 18:59:33","2026-05-12 18:59:33",""\n';
  const blob = new Blob(["﻿" + header + sample], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "lele-member-import-template.csv";
  a.click();
  URL.revokeObjectURL(url);
}
