-- ============================================================================
-- market-ai 排程從每 5 分鐘改成每分鐘（老闆 2026-11-07 指示）
--
-- 原因：廠商網站一次進來 1,400 多篇貼文（vendor_site，20261107000000），每 5 分鐘一輪、
-- 一輪拆約 5 篇（每輪貼文只給 45 秒）→ 每小時約 80 篇，要排 15～18 小時。
-- 改每分鐘後同時會有 2～3 輪在跑（一輪最長約 128 秒）：
--   - 拆貼文 rpc_market_post_claim、品類 rpc_ai_kind_claim、商品標籤 rpc_product_tag_llm_claim
--     都是 FOR UPDATE SKIP LOCKED + 蓋時間戳，疊著跑不會重複呼叫模型。
--   - 向量三段（rpc_ai_item_embed_claim / rpc_ai_product_embed_claim / rpc_ai_hot_embed_claim）
--     沒鎖：疊著跑會把同一批重算一次向量。寫回是覆蓋、結果一樣，bge-m3 很便宜，接受。
--   - 沒工作時 _market_ai_tick 自己 RETURN、不打 Edge Function（20261102000010 的 EXISTS 檢查）。
-- 模型費用依實際拆的篇數算，跟頻率無關；頻率只決定多快拆完。
--
-- rollback：SELECT cron.schedule('market-ai-tick', '*/5 * * * *', $cron$ SELECT public._market_ai_tick(); $cron$);
-- 無基底函式（只改排程；原排程 20261101000090）。
-- ============================================================================

SELECT cron.schedule('market-ai-tick', '* * * * *', $cron$ SELECT public._market_ai_tick(); $cron$);
