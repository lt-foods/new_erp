-- ============================================================================
-- 2026-08-09: 商品標籤細分 + 兩個誤標修正
--
-- 為什麼要改：拿 20260809000020 的標籤去做「開團前預測」的消融實驗，發現
--   ・標籤是最強的單一特徵（只用標籤 ρ=0.314；只用價格 0.173、只用品名 0.090）
--   ・**標籤數多的商品預測得比較準**：1–2 個標籤 ρ=0.363、3–4 個 ρ=0.409
--   ・但分品類看，準度差很多：海鮮 0.473 / 清潔用品 0.429 / 零食 0.409，
--     而 **熟食調理 −0.127、居家用品 0.056** —— 這兩個標籤等於沒有資訊。
--
--   翻商品名就知道為什麼：`prepared`（熟食調理）176 項裡同時有水餃、火鍋料、
--   月餅、披薩、滷鳳爪、涼麵；`home`（居家用品）141 項裡有收納盒、除臭劑、
--   夜燈、車用支架、療癒吊飾。這種桶子的「平均滲透率」不代表任何東西。
--
-- 做法：**加子標籤，不動父標籤**。多標籤模型本來就允許一個商品同時是
--   「熟食調理 + 冷凍麵點」，既有的地區偏好／趨勢分析不受影響，只是多了一層可選的細度。
--
-- 另外修兩個誤標（規則寫太寬）：
--   牛(?!…)  漏擋「牛仔」→「#B92155# 側邊綁蝴蝶結牛仔短褲」被標成肉品
--   雞(?!…)  漏擋「雞仔牌」→「ST雞仔牌 垃圾桶芳香除臭劑」被標成肉品
--   這是 meat 只有 ρ=0.240 的原因之一。
--
-- Rollback:
--   DELETE FROM product_tag_map WHERE tag_id IN (SELECT id FROM product_tags WHERE code LIKE 'prep\_%' OR code LIKE 'home\_%');
--   DELETE FROM product_tag_rules WHERE tag_code LIKE 'prep\_%' OR tag_code LIKE 'home\_%';
--   DELETE FROM product_tags WHERE code LIKE 'prep\_%' OR code LIKE 'home\_%';
--   （誤標修正的 rollback 見下方 UPDATE 的原值註解）
-- ============================================================================

-- ── 1. 誤標修正 ──────────────────────────────────────────────────────────
-- 原值：'豬|牛(?!奶|乳|舌餅|軋|角|蒡)|雞(?!蛋|精)|鴨(?!賞茶)|…'
UPDATE product_tag_rules
   SET pattern = replace(replace(pattern,
         '牛(?!奶|乳|舌餅|軋|角|蒡)', '牛(?!奶|乳|舌餅|軋|角|蒡|仔)'),
         '雞(?!蛋|精)',              '雞(?!蛋|精|仔牌)')
 WHERE tag_code = 'meat'
   AND pattern LIKE '%牛(?!奶|乳|舌餅|軋|角|蒡)%';

-- ── 2. 子標籤字彙 ────────────────────────────────────────────────────────
INSERT INTO product_tags (tenant_id, code, name, tag_group, sort)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, v.code, v.name, v.tag_group, v.sort
  FROM (VALUES
    -- 熟食調理的六個子類（依商品名實際看得出來的分法）
    ('prep_dumpling', '冷凍麵點',   '食品',   410),
    ('prep_soup',     '湯品鍋物',   '食品',   411),
    ('prep_fried',    '炸物排餐',   '食品',   412),
    ('prep_rice',     '飯麵主餐',   '食品',   413),
    ('prep_braised',  '滷味',       '食品',   414),
    ('prep_western',  '西式餐點',   '食品',   415),
    -- 居家用品的五個子類
    ('home_storage',  '收納整理',   '非食品', 420),
    ('home_scent',    '香氛除臭',   '非食品', 421),
    ('home_light',    '燈具家電',   '非食品', 422),
    ('home_car',      '車用',       '非食品', 423),
    ('home_decor',    '療癒裝飾',   '非食品', 424)
  ) AS v(code, name, tag_group, sort)
ON CONFLICT (tenant_id, code) DO UPDATE
   SET name = EXCLUDED.name, tag_group = EXCLUDED.tag_group, sort = EXCLUDED.sort;

-- ── 3. 子標籤規則 ────────────────────────────────────────────────────────
-- 同樣是 Postgres ARE（字界用 \y 不是 \b）。priority 排在既有規則之後，
-- 都不是互斥群組，命中就累加。
INSERT INTO product_tag_rules (tenant_id, pattern, tag_code, priority, exclusive_group)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, v.pattern, v.tag_code, v.priority, NULL
  FROM (VALUES
    ('水餃|餛飩|抄手|扁食|鍋貼|生煎|包子|饅頭|燒賣|湯圓|春捲|抓餅|蛋餅|腸粉|燒餃|餃子|水晶餃|小籠|燒餅|蔥油餅', 'prep_dumpling', 500),
    ('湯$|湯（|湯\(|湯品|羹|鍋物|火鍋|煲|燉|粥|雞湯|牛肉湯',                                    'prep_soup',     501),
    ('雞排|炸雞|鹽酥|天婦羅|甜不辣|黑輪|豬排|排骨酥|酥炸|唐揚|卡啦|脆皮|預炸|炸物',                  'prep_fried',    502),
    ('油飯|炒飯|飯糰|便當|燴飯|米糕|涼麵|炒麵|拌麵|米粉|冬粉|粉絲煲|意麵|陽春麵|烏龍麵|拉麵|滷肉飯', 'prep_rice',     503),
    ('滷味|滷肉(?!飯)|滷豬|香滷|鳳爪|滷包|滷蛋|東坡|滷大腸|滷雞|私房滷',                          'prep_braised',  504),
    ('披薩|比薩|pizza|焗烤|義式|義大利麵|漢堡|三明治|帕尼尼',                                    'prep_western',  505),
    ('收納|置物|整理箱|掛勾|掛鉤|衣架|晾曬|晾衣|壓縮袋|收納袋|收納盒|收納籃',                       'home_storage',  510),
    ('芳香|香氛|除臭|消臭|擴香|香薰|花露水',                                                    'home_scent',    511),
    ('燈$|夜燈|壁燈|檯燈|閱讀燈|電蚊拍|風扇|除濕|加濕|吸塵器|氣炸鍋',                              'home_light',    512),
    ('車用|車載|後備箱|騎行|安全帽|行車|後照鏡',                                                'home_car',      513),
    ('掛飾|吊飾|擺件|盆栽|玩偶|療癒|裝飾|冰箱貼|鑰匙圈|公仔',                                    'home_decor',    514)
  ) AS v(pattern, tag_code, priority)
ON CONFLICT (tenant_id, pattern, tag_code) DO UPDATE
   SET priority = EXCLUDED.priority;

-- ── 4. 重跑規則 ──────────────────────────────────────────────────────────
-- migration 沒有 JWT，不能呼叫 rpc_apply_product_tag_rules()（見 20260809000020），
-- 所以用同一套邏輯的純 SQL。人工列（source='manual'）不動。
DELETE FROM product_tag_map WHERE source = 'rule';

INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
SELECT DISTINCT p.tenant_id, p.id, tg.id, 'rule'
  FROM products p
  JOIN product_tag_rules r ON r.tenant_id = p.tenant_id AND r.is_active
                          AND r.exclusive_group IS NULL
                          AND p.name ~* r.pattern
  JOIN product_tags tg ON tg.tenant_id = p.tenant_id AND tg.code = r.tag_code
ON CONFLICT (product_id, tag_id) DO NOTHING;

INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
SELECT x.tenant_id, x.product_id, tg.id, 'rule'
  FROM (
    SELECT DISTINCT ON (p.id, r.exclusive_group)
           p.tenant_id, p.id AS product_id, r.tag_code
      FROM products p
      JOIN product_tag_rules r ON r.tenant_id = p.tenant_id AND r.is_active
                              AND r.exclusive_group IS NOT NULL
                              AND p.name ~* r.pattern
     ORDER BY p.id, r.exclusive_group, r.priority, r.id
  ) x
  JOIN product_tags tg ON tg.tenant_id = x.tenant_id AND tg.code = x.tag_code
ON CONFLICT (product_id, tag_id) DO NOTHING;

-- 常溫＝是食品但沒判成冷凍/冷藏
INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
SELECT p.tenant_id, p.id, amb.id, 'rule'
  FROM products p
  JOIN product_tags amb ON amb.tenant_id = p.tenant_id AND amb.code = 'ambient'
 WHERE EXISTS (
         SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
          WHERE m.product_id = p.id AND g.tag_group IN ('生鮮','食品'))
   AND NOT EXISTS (
         SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
          WHERE m.product_id = p.id AND g.code IN ('frozen','chilled'))
ON CONFLICT (product_id, tag_id) DO NOTHING;
