// 圖片下載：商品圖是公開網址（不用登入），存到 out/<vendor>/<時間>/images/<psn>-<n>.jpg。
import fs from "node:fs";
import path from "node:path";

/**
 * @param {object[]} rows   標準欄位列（要有 psn / image / images）
 * @param {string} dir      存放目錄
 * @param {"main"|"all"} mode
 * @param {object} [opts]   { concurrency, log }
 * @returns {Promise<{ downloaded: number, skipped: number, failed: number }>}
 */
export async function downloadImages(rows, dir, mode = "main", { concurrency = 4, log = () => {} } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  const jobs = [];
  for (const r of rows) {
    const urls = mode === "all" ? (r.images?.length ? r.images : r.image ? [r.image] : []) : r.image ? [r.image] : [];
    urls.forEach((url, i) => {
      const ext = (url.match(/\.(jpe?g|png|gif|webp)(?:$|\?)/i)?.[1] || "jpg").toLowerCase();
      const file = path.join(dir, `${r.psn}-${i + 1}.${ext}`);
      jobs.push({ url, file, psn: r.psn });
    });
  }
  const stat = { downloaded: 0, skipped: 0, failed: 0 };
  let next = 0;
  async function worker() {
    while (next < jobs.length) {
      const j = jobs[next++];
      if (fs.existsSync(j.file) && fs.statSync(j.file).size > 0) { stat.skipped++; continue; }
      try {
        const res = await fetch(j.url);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        fs.writeFileSync(j.file, Buffer.from(await res.arrayBuffer()));
        stat.downloaded++;
      } catch (e) {
        stat.failed++;
        log(`圖片失敗 ${j.url}：${e.message}`);
      }
      const done = stat.downloaded + stat.skipped + stat.failed;
      if (done % 50 === 0 || done === jobs.length) log(`圖片 ${done}/${jobs.length}`);
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker));
  // 回填本機路徑，方便之後匯入
  for (const r of rows) {
    r.image_files = jobs.filter((j) => j.psn === r.psn && fs.existsSync(j.file)).map((j) => path.relative(path.dirname(dir), j.file));
  }
  return stat;
}
