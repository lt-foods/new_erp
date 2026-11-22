// 介紹影片連結解析：node --test apps/admin/src/lib/videoEmbed.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { isTikTokShortLink, parseVideoEmbed, safeHttpsUrl, tiktokPlayerUrl } from "./videoEmbed.ts";

test("後台與會員端的 videoEmbed.ts 必須逐字相同", () => {
  const admin = readFileSync(fileURLToPath(new URL("./videoEmbed.ts", import.meta.url)), "utf8");
  const member = readFileSync(fileURLToPath(new URL("../../../member/src/lib/videoEmbed.ts", import.meta.url)), "utf8");
  assert.equal(admin, member);
});

test("YouTube：watch / youtu.be / shorts", () => {
  assert.equal(parseVideoEmbed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3")?.embedUrl,
    "https://www.youtube.com/embed/dQw4w9WgXcQ?playsinline=1&rel=0&autoplay=1");
  assert.equal(parseVideoEmbed("https://youtu.be/dQw4w9WgXcQ?si=abc")?.provider, "youtube");
  const shorts = parseVideoEmbed("https://m.youtube.com/shorts/abcDEF12345");
  assert.equal(shorts?.portrait, true);
  assert.equal(parseVideoEmbed("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.portrait, false);
  assert.equal(parseVideoEmbed("https://www.youtube.com/@channel"), null);
});

test("Instagram：reel / p，帶帳號與追蹤參數也認得", () => {
  assert.equal(parseVideoEmbed("https://www.instagram.com/reel/C8abcdEFGhi/?igsh=xyz")?.embedUrl,
    "https://www.instagram.com/reel/C8abcdEFGhi/embed/");
  assert.equal(parseVideoEmbed("https://www.instagram.com/baozima/reel/C8abcdEFGhi/")?.embedUrl,
    "https://www.instagram.com/reel/C8abcdEFGhi/embed/");
  assert.equal(parseVideoEmbed("https://instagram.com/p/C8abcdEFGhi")?.embedUrl,
    "https://www.instagram.com/p/C8abcdEFGhi/embed/");
  assert.equal(parseVideoEmbed("https://www.instagram.com/baozima/"), null);
});

test("TikTok：完整網址與播放器網址可嵌；短連結不行（要先換）", () => {
  const want = "https://www.tiktok.com/player/v1/6718335390845095173?autoplay=1&rel=0";
  assert.equal(parseVideoEmbed("https://www.tiktok.com/@scout2015/video/6718335390845095173?is_from_webapp=1")?.embedUrl, want);
  assert.equal(parseVideoEmbed("https://www.tiktok.com/player/v1/6718335390845095173")?.embedUrl, want);
  assert.equal(parseVideoEmbed("https://vt.tiktok.com/ZSabc123/"), null);
  assert.equal(isTikTokShortLink("https://vt.tiktok.com/ZSabc123/"), true);
  assert.equal(isTikTokShortLink("https://vm.tiktok.com/ZSabc123/"), true);
  assert.equal(isTikTokShortLink("https://www.tiktok.com/t/ZSabc123/"), true);
  assert.equal(isTikTokShortLink("https://www.tiktok.com/@a/video/6718335390845095173"), false);
  assert.equal(tiktokPlayerUrl("6718335390845095173"), "https://www.tiktok.com/player/v1/6718335390845095173");
  assert.equal(tiktokPlayerUrl("abc"), null);
});

test("Facebook：reel / videos / fb.watch 走官方外掛", () => {
  const e = parseVideoEmbed("https://www.facebook.com/reel/1234567890");
  assert.equal(e?.provider, "facebook");
  assert.ok(e?.embedUrl.startsWith("https://www.facebook.com/plugins/video.php?href=https%3A%2F%2Fwww.facebook.com%2Freel%2F1234567890"));
  assert.equal(parseVideoEmbed("https://fb.watch/abcDEF/")?.provider, "facebook");
  assert.equal(parseVideoEmbed("https://www.facebook.com/baozima"), null);
});

test("小視窗預覽網址：靜音自動播放；IG 不支援 → 跟大視窗同一個網址", () => {
  const yt = parseVideoEmbed("https://www.youtube.com/shorts/abcDEF12345");
  assert.equal(yt?.kind, "iframe");
  assert.equal(yt?.previewUrl,
    "https://www.youtube.com/embed/abcDEF12345?playsinline=1&rel=0&autoplay=1&mute=1&controls=0&loop=1&playlist=abcDEF12345");
  const tk = parseVideoEmbed("https://www.tiktok.com/player/v1/6718335390845095173");
  assert.ok(tk?.previewUrl.startsWith("https://www.tiktok.com/player/v1/6718335390845095173?autoplay=1&loop=1"));
  assert.ok(tk?.previewUrl.includes("controls=0"));
  const ig = parseVideoEmbed("https://www.instagram.com/reel/C8abcdEFGhi/");
  assert.equal(ig?.previewUrl, ig?.embedUrl);
  assert.ok(parseVideoEmbed("https://www.facebook.com/reel/1234567890")?.previewUrl.endsWith("&mute=1"));
});

test("影片檔連結（.mp4 / .mov / .webm）→ 用 <video> 播，不進 iframe", () => {
  const f = parseVideoEmbed("https://cdn.example.com/videos/bagel.MP4?token=abc");
  assert.equal(f?.provider, "file");
  assert.equal(f?.kind, "file");
  assert.equal(f?.embedUrl, "https://cdn.example.com/videos/bagel.MP4?token=abc");
  assert.equal(f?.previewUrl, f?.embedUrl);
  assert.equal(parseVideoEmbed("https://cdn.example.com/videos/bagel.mov")?.kind, "file");
  assert.equal(parseVideoEmbed("http://cdn.example.com/videos/bagel.mp4"), null);
  assert.equal(parseVideoEmbed("https://cdn.example.com/page.html?file=x.mp4"), null);
});

test("不是 https、不認得的網站、亂填 → null，不會變成 iframe", () => {
  assert.equal(parseVideoEmbed("http://www.youtube.com/watch?v=dQw4w9WgXcQ"), null);
  assert.equal(parseVideoEmbed("javascript:alert(1)"), null);
  assert.equal(parseVideoEmbed("https://evil.example.com/reel/C8abcdEFGhi"), null);
  assert.equal(parseVideoEmbed("https://www.youtube.com.evil.example/watch?v=dQw4w9WgXcQ"), null);
  assert.equal(parseVideoEmbed("https://youtu.be/<script>"), null);
  assert.equal(parseVideoEmbed(""), null);
  assert.equal(parseVideoEmbed(null), null);
  assert.equal(safeHttpsUrl("https://v.douyin.com/abc/"), "https://v.douyin.com/abc/");
  assert.equal(safeHttpsUrl("ftp://x"), null);
});
