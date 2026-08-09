#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""熱銷比可行性回測 —— 開團前只用「商品屬性 + 過往同類表現」，預測得出這一團會多熱嗎？

用途：驗證 docs/PLAN-行銷策略系統-熱銷比.md 裡的數字，以及之後每次改模型時重跑比較。
加 --ablation 會多跑一組消融比較（拆開看標籤／價格／品名各貢獻多少、
以及分品類的準度），用來決定「該不該再細分標籤」。
資料直接打 Supabase Management API 撈（見 CLAUDE.md：不要走 pooler TCP，會被擋）。

    SUPABASE_PROJECT_REF=xxx SUPABASE_ACCESS_TOKEN=xxx python3 scripts/analysis-campaign-demand-backtest.py

輸出：Spearman ρ、冷啟動子集的 ρ、依預測分數切五組的實際表現。

⚠ 時間切分：訓練期是 CUTOFF 之前的團，所有層級平均值只用訓練期算，
  測試期的資料絕對不能進特徵，否則 ρ 會虛高。
"""
import bisect
import datetime
import json
import math
import os
import statistics as st
import sys
import subprocess
from collections import defaultdict

CUTOFF = os.environ.get("CUTOFF", "2026-07-20")
REF = os.environ["SUPABASE_PROJECT_REF"]
TOKEN = os.environ["SUPABASE_ACCESS_TOKEN"]
CA = "/root/.ccr/ca-bundle.crt"


def query(sql):
    payload = json.dumps({"query": sql})
    out = subprocess.run(
        ["curl", "-sS", "--cacert", CA, "-X", "POST",
         f"https://api.supabase.com/v1/projects/{REF}/database/query",
         "-H", f"Authorization: Bearer {TOKEN}",
         "-H", "Content-Type: application/json", "-d", payload],
        capture_output=True, text=True, check=True).stdout
    res = json.loads(out)
    if isinstance(res, dict) and "message" in res:
        raise SystemExit(res["message"])
    return res


# ── 撈資料 ────────────────────────────────────────────────────────────────
# 觀測單位＝「開團 × 商品」。同一團裡同商品的多個 SKU 併成一列。
CI_SQL = """
WITH ci AS (
  SELECT c.id AS campaign_id, c.created_at, sk.product_id, max(ci.unit_price)::numeric AS price
  FROM campaign_items ci
  JOIN group_buy_campaigns c ON c.id = ci.campaign_id
  JOIN skus sk ON sk.id = ci.sku_id
  GROUP BY 1,2,3
),
buy AS (
  SELECT o.campaign_id, sk.product_id, count(DISTINCT o.member_id) AS buyers
  FROM customer_orders o
  JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal' AND m.status <> 'deleted'
  JOIN customer_order_items i ON i.order_id = o.id AND i.status NOT IN ('cancelled','expired')
  JOIN skus sk ON sk.id = i.sku_id
  WHERE o.status NOT IN ('cancelled','expired','transferred_out')
  GROUP BY 1,2
)
SELECT jsonb_agg(jsonb_build_object(
  'cid', ci.campaign_id, 'pid', ci.product_id,
  'd', to_char(ci.created_at AT TIME ZONE 'Asia/Taipei','YYYY-MM-DD'),
  'price', ci.price, 'buyers', COALESCE(b.buyers,0),
  'name', COALESCE(p.name,''))) AS rows
FROM ci
LEFT JOIN buy b ON b.campaign_id = ci.campaign_id AND b.product_id = ci.product_id
LEFT JOIN products p ON p.id = ci.product_id;
"""

TAG_SQL = """
SELECT jsonb_agg(jsonb_build_object('pid', product_id, 'tags', codes)) AS rows
FROM (SELECT m.product_id, jsonb_agg(t.code ORDER BY t.code) AS codes
        FROM product_tag_map m JOIN product_tags t ON t.id = m.tag_id
       GROUP BY m.product_id) z;
"""

# 分母：當週全店下單會員數。理想上應該是「這一團實際觸及的人」，
# 但目前沒有記錄曝光（見規劃文件第六節），先用當週活躍會員近似。
WEEK_SQL = """
SELECT jsonb_agg(jsonb_build_object('d', d, 'buyers', b)) AS rows FROM (
  SELECT to_char(date_trunc('week', o.created_at AT TIME ZONE 'Asia/Taipei'),'YYYY-MM-DD') AS d,
         count(DISTINCT o.member_id) AS b
  FROM customer_orders o
  JOIN members m ON m.id = o.member_id AND m.member_type <> 'store_internal' AND m.status <> 'deleted'
  WHERE o.status NOT IN ('cancelled','expired','transferred_out')
  GROUP BY 1) z;
"""

rows = query(CI_SQL)[0]["rows"] or []
ptags = {r["pid"]: r["tags"] for r in (query(TAG_SQL)[0]["rows"] or [])}
weekbase = {r["d"]: r["buyers"] for r in (query(WEEK_SQL)[0]["rows"] or [])}


def week_of(d):
    y, m, dd = map(int, d.split("-"))
    dt = datetime.date(y, m, dd)
    return (dt - datetime.timedelta(days=dt.weekday())).isoformat()


for r in rows:
    wb = weekbase.get(week_of(r["d"]), 0)
    r["pen"] = (r["buyers"] / wb) if wb else None
    r["tags"] = ptags.get(r["pid"], [])
    r["price"] = float(r["price"] or 0)
rows = [r for r in rows if r["pen"] is not None]
rows.sort(key=lambda r: r["d"])

train = [r for r in rows if r["d"] < CUTOFF]
test = [r for r in rows if r["d"] >= CUTOFF]
print(f"train={len(train)}  test={len(test)}  cutoff={CUTOFF}")
if not train or not test:
    raise SystemExit("訓練或測試集是空的，檢查 CUTOFF")

# ── 只用訓練期建立各層基準 ────────────────────────────────────────────────
gmean = st.mean(r["pen"] for r in train)


def grams(name):
    s = "".join(ch for ch in name if ch.strip())
    return {s[i:i + 3] for i in range(max(0, len(s) - 2))}


gram_count = defaultdict(int)
for r in train:
    for t in grams(r["name"]):
        gram_count[t] += 1
# 只留出現在 >=5 個開團品項的字串：這些多半就是品牌 / 店名 / 品項關鍵字。
# 之所以要用字串硬湊，是因為 products.brand_id 目前 100% 是 NULL。
VOCAB = {t for t, c in gram_count.items() if c >= 5}

tag_pens, gram_pens, band_pens, prod_hist = (defaultdict(list) for _ in range(4))
prices = sorted(r["price"] for r in train if r["price"] > 0)


def price_band(p):
    if p <= 0 or not prices:
        return "na"
    return f"q{int(bisect.bisect_left(prices, p) / len(prices) * 5)}"


for r in train:
    for t in r["tags"]:
        tag_pens[t].append(r["pen"])
    for t in grams(r["name"]) & VOCAB:
        gram_pens[t].append(r["pen"])
    band_pens[price_band(r["price"])].append(r["pen"])
    prod_hist[r["pid"]].append(r["pen"])


def shrunk(vals, k):
    """樣本少的層級往全體平均收縮（empirical Bayes 的簡化版）：
       只有 3 筆資料的層級不該跟有 300 筆的一樣被信任。"""
    if not vals:
        return gmean
    n = len(vals)
    return (n * st.mean(vals) + k * gmean) / (n + k)


def predict(r):
    tag_est = st.mean([shrunk(tag_pens.get(t, []), 8) for t in r["tags"]]) if r["tags"] else gmean
    band_est = shrunk(band_pens.get(price_band(r["price"]), []), 20)
    gs = [shrunk(gram_pens[t], 10) for t in (grams(r["name"]) & VOCAB)]
    prior = (0.40 * tag_est + 0.20 * band_est + 0.40 * st.mean(gs)) if gs \
        else (0.65 * tag_est + 0.35 * band_est)
    hist = prod_hist.get(r["pid"], [])
    if hist:
        n = len(hist)
        return (n * st.mean(hist) + 2 * prior) / (n + 2)
    return prior


def spearman(xs, ys):
    def rank(v):
        order = sorted(range(len(v)), key=lambda i: v[i])
        rk = [0.0] * len(v)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
                j += 1
            avg = (i + j) / 2 + 1
            for m in range(i, j + 1):
                rk[order[m]] = avg
            i = j + 1
        return rk
    rx, ry = rank(xs), rank(ys)
    mx, my = st.mean(rx), st.mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = math.sqrt(sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry))
    return num / den if den else 0.0


pred = [predict(r) for r in test]
act = [r["pen"] for r in test]
print(f"\nSpearman ρ（預測 vs 實際排序）= {spearman(pred, act):.3f}")


def _only(tag=False, band_=False, gram=False):
    """消融用：只開指定特徵，其餘不算"""
    def f(r):
        parts = []
        if tag:
            parts.append((0.40 if (band_ or gram) else 1.0,
                          st.mean([shrunk(tag_pens.get(t, []), 8) for t in r["tags"]]) if r["tags"] else gmean))
        if band_:
            parts.append((0.20 if (tag or gram) else 1.0, shrunk(band_pens.get(price_band(r["price"]), []), 20)))
        if gram:
            gs = [shrunk(gram_pens[t], 10) for t in (grams(r["name"]) & VOCAB)]
            parts.append((0.40 if (tag or band_) else 1.0, st.mean(gs) if gs else None))
        ok = [(w, v) for w, v in parts if v is not None]
        if not ok:
            return gmean
        prior = sum(w * v for w, v in ok) / sum(w for w, _ in ok)
        hist = prod_hist.get(r["pid"], [])
        return (len(hist) * st.mean(hist) + 2 * prior) / (len(hist) + 2) if hist else prior
    return f


if "--ablation" in sys.argv:
    print("\n【消融】每個特徵各貢獻多少（同一組切分，只換特徵）")
    for label, fn in [
        ("只用價格帶", _only(band_=True)),
        ("只用品名文字", _only(gram=True)),
        ("只用標籤", _only(tag=True)),
        ("標籤+價格", _only(tag=True, band_=True)),
        ("標籤+價格+品名", _only(tag=True, band_=True, gram=True)),
    ]:
        pv = [fn(r) for r in test]
        print(f"  {label:<16} ρ = {spearman(pv, act):.3f}")

    print("\n【消融】依商品的標籤數分組（標籤標得越細，是不是預測越準？）")
    groups = {"1-2 個": [], "3-4 個": [], "5 個以上": []}
    for p_, a_, r_ in zip(pred, act, test):
        n = len(r_["tags"])
        if n == 0:
            continue
        groups["1-2 個" if n <= 2 else "3-4 個" if n <= 4 else "5 個以上"].append((p_, a_))
    for k, v in groups.items():
        if len(v) >= 25:
            print(f"  {k:<10} n={len(v):>4}  ρ = {spearman([x[0] for x in v], [x[1] for x in v]):.3f}")

    print("\n【消融】分品類的準度（樣本 >= 25 才列；ρ 接近 0 = 這個類別的分數不可信）")
    tag_names = {}
    for r_ in query("SELECT jsonb_agg(jsonb_build_object('c', code, 'n', name)) AS rows FROM product_tags")[0]["rows"] or []:
        tag_names[r_["c"]] = r_["n"]
    for code, label in sorted(tag_names.items(), key=lambda kv: kv[1]):
        sub = [(p_, a_) for p_, a_, r_ in zip(pred, act, test) if code in r_["tags"]]
        if len(sub) >= 25:
            print(f"  {label:<10} n={len(sub):>4}  ρ = {spearman([x[0] for x in sub], [x[1] for x in sub]):+.3f}")

cold = [(p, a) for p, a, r in zip(pred, act, test) if not prod_hist.get(r["pid"])]
print(f"冷啟動子集（該商品沒開過團）n={len(cold)}  ρ = "
      f"{spearman([c[0] for c in cold], [c[1] for c in cold]):.3f}")

pairs = sorted(zip(pred, act), key=lambda x: -x[0])
n, overall = len(pairs), st.mean(act)
print("\n依預測分數由高到低切 5 組：")
print(f"{'組':<8}{'實際平均滲透':>14}{'相對全體':>10}{'0 買家占比':>12}")
for i in range(5):
    seg = pairs[i * n // 5:(i + 1) * n // 5]
    aa = st.mean(a for _, a in seg)
    zero = sum(1 for _, a in seg if a == 0) / len(seg)
    print(f"第 {i+1} 組{'':<3}{aa*100:>13.2f}%{aa/overall:>9.2f}x{zero*100:>11.0f}%")

print(f"\n整體 0 買家比率 {sum(1 for a in act if a == 0)/len(act)*100:.0f}%")
