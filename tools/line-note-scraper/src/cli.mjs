#!/usr/bin/env node
// line-notes：LINE 群組／社群記事本留言爬蟲 CLI。
//
//   node src/cli.mjs login                      掃 QR 登入（存 storage.json）
//   node src/cli.mjs groups                     列出群組 / 社群 / 社群聊天室的 homeId
//   node src/cli.mjs posts <homeId> [--limit 20] [--since 2026-09-01]
//   node src/cli.mjs comments <homeId> <postId>
//   node src/cli.mjs scrape <homeId> [--since …] [--limit …] [--out out] [--raw]
//
// 共用選項：--verbose（把每次 API 嘗試印到 stderr）、--json（posts/groups 以 JSON 輸出）

import fs from "node:fs";
import path from "node:path";
import {
  ensureDir, getClient, listComments, listHomes, listPosts, whoami,
} from "./line.mjs";
import { parseOrderLines, postTitle } from "./parse.mjs";

function parseArgs(argv) {
  const args = { _: [], flags: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--")) { args.flags[key] = next; i++; }
      else args.flags[key] = true;
    } else args._.push(a);
  }
  return args;
}

function csvEscape(v) {
  const s = v == null ? "" : String(v);
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function writeCsv(file, rows, columns) {
  const lines = [columns.join(",")];
  for (const r of rows) lines.push(columns.map((c) => csvEscape(r[c])).join(","));
  fs.writeFileSync(file, "﻿" + lines.join("\n") + "\n", "utf8"); // BOM 給 Excel
}

function printTable(rows, columns) {
  if (rows.length === 0) { console.log("(空)"); return; }
  const widths = columns.map((c) => Math.max(c.length, ...rows.map((r) => String(r[c] ?? "").length)));
  const line = (r) => columns.map((c, i) => String(r[c] ?? "").padEnd(widths[i])).join("  ");
  console.log(line(Object.fromEntries(columns.map((c) => [c, c]))));
  console.log(widths.map((w) => "-".repeat(w)).join("  "));
  for (const r of rows) console.log(line(r));
}

async function main() {
  const { _: [cmd, ...rest], flags } = parseArgs(process.argv.slice(2));
  const verbose = !!flags.verbose;

  if (!cmd || cmd === "help" || flags.help) {
    console.log(fs.readFileSync(new URL(import.meta.url)).toString().split("\n").slice(1, 11).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    return;
  }

  if (cmd === "login") {
    const client = await getClient({ interactive: true, verbose });
    const me = whoami(client);
    console.log(`登入成功：${me.displayName} (${me.mid})，token 已存到 storage.json`);
    process.exit(0);
  }

  const client = await getClient({ interactive: false, verbose });
  const me = whoami(client);
  console.error(`[line-notes] 登入身分：${me.displayName} (${me.mid})`);

  if (cmd === "groups") {
    const homes = await listHomes(client, verbose);
    if (flags.json) console.log(JSON.stringify(homes, null, 2));
    else {
      printTable(homes, ["kind", "homeId", "name"]);
      console.log("\n群組用 c… 的 id；社群記事本先試 m…（聊天室），不行再試 s…（社群本體）。");
    }
    process.exit(0);
  }

  const homeId = rest[0];
  if (!homeId) throw new Error(`用法：${cmd} <homeId> …（homeId 用 groups 指令查）`);
  const limit = flags.limit ? Number(flags.limit) : (cmd === "posts" ? 20 : 500);
  const since = flags.since || null;

  if (cmd === "posts") {
    const posts = await listPosts(client, homeId, { limit, since, verbose });
    if (flags.json) console.log(JSON.stringify(posts.map(({ raw, ...p }) => p), null, 2));
    else printTable(posts.map((p) => ({ postId: p.postId, createdAt: p.createdAt ?? "", author: p.authorName ?? p.authorMid ?? "", comments: p.commentCount, title: postTitle(p.text) })), ["postId", "createdAt", "author", "comments", "title"]);
    process.exit(0);
  }

  if (cmd === "comments") {
    const postId = rest[1];
    if (!postId) throw new Error("用法：comments <homeId> <postId>");
    const comments = await listComments(client, homeId, postId, { verbose });
    console.log(JSON.stringify(comments.map(({ raw, ...c }) => ({ ...c, orders: parseOrderLines(c.text) })), null, 2));
    process.exit(0);
  }

  if (cmd === "scrape") {
    const outDir = ensureDir(path.join(flags.out || "out", homeId, new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)));
    const rawDump = flags.raw ? [] : null;
    const onRaw = rawDump ? (b) => rawDump.push(b) : undefined;

    const posts = await listPosts(client, homeId, { limit, since, verbose, onRaw });
    console.error(`[line-notes] 貼文 ${posts.length} 篇`);
    const comments = [];
    const orders = [];
    for (const p of posts) {
      const cs = await listComments(client, homeId, p.postId, { verbose, onRaw });
      console.error(`[line-notes]   ${p.postId} ${postTitle(p.text)} → 留言 ${cs.length}`);
      for (const c of cs) {
        comments.push(c);
        for (const o of parseOrderLines(c.text)) {
          orders.push({
            homeId, postId: p.postId, postTitle: postTitle(p.text), postCreatedAt: p.createdAt,
            commentId: c.commentId, commenter: c.authorName ?? "", commenterMid: c.authorMid ?? "",
            commentedAt: c.createdAt ?? "", code: o.code ?? "", qty: o.cancel ? -o.qty : o.qty,
            cancel: o.cancel ? "Y" : "", line: o.line, text: c.text,
          });
        }
      }
    }

    fs.writeFileSync(path.join(outDir, "posts.json"), JSON.stringify(posts, null, 2));
    fs.writeFileSync(path.join(outDir, "comments.json"), JSON.stringify(comments, null, 2));
    writeCsv(path.join(outDir, "comments.csv"), comments.map((c) => ({ ...c, text: c.text })),
      ["homeId", "postId", "commentId", "authorName", "authorMid", "createdAt", "text"]);
    writeCsv(path.join(outDir, "orders.csv"), orders,
      ["homeId", "postId", "postTitle", "postCreatedAt", "commentId", "commenter", "commenterMid", "commentedAt", "code", "qty", "cancel", "line", "text"]);
    if (rawDump) fs.writeFileSync(path.join(outDir, "raw.json"), JSON.stringify(rawDump, null, 2));

    // 每篇貼文的小計，方便對帳
    const summary = new Map();
    for (const o of orders) {
      const k = `${o.postId}\t${o.code}`;
      const s = summary.get(k) ?? { postId: o.postId, postTitle: o.postTitle, code: o.code, qty: 0, people: new Set() };
      s.qty += o.qty;
      s.people.add(o.commenterMid || o.commenter);
      summary.set(k, s);
    }
    writeCsv(path.join(outDir, "summary.csv"), [...summary.values()].map((s) => ({ ...s, people: s.people.size })),
      ["postId", "postTitle", "code", "qty", "people"]);

    console.log(`完成：${posts.length} 篇貼文、${comments.length} 則留言、${orders.length} 筆 +1\n輸出：${outDir}`);
    process.exit(0);
  }

  throw new Error(`不認識的指令：${cmd}`);
}

main().catch((e) => {
  console.error("錯誤：" + (e?.message ?? e));
  if (process.argv.includes("--verbose") && e?.stack) console.error(e.stack);
  process.exit(1);
});
