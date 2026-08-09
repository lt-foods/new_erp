-- ============================================================================
-- 2026-08-09: 商品標籤（多標籤）— 地區偏好分析的分類基礎
--
-- 背景：線上 1,831 個商品，products.category_id **全部是 NULL**，既有的
--   categories 那 17 筆是初版示範樹（生鮮/乾貨/調味…），沒有任何商品掛上去，
--   而且是單一分類、裝不下「日本製的冷藏海鮮」這種同時要多個標籤的東西。
--   要回答「哪一區偏好什麼」就得先有分類 → 本檔建立多標籤模型。
--
-- 為什麼是多標籤不是單一分類（老闆指定）：
--   同一件商品常常同時是「海鮮 + 冷凍 + 日本商品」。單一分類只能挑一個，
--   分析時就永遠問不出「哪一區特別愛冷凍品」。
--
-- 三張表：
--   product_tags       標籤字彙（38 個，用 tag_group 分成 溫層/生鮮/食品/非食品/屬性）
--   product_tag_rules  規則（商品名 regex → 標籤）；新商品進來重跑就自動標
--   product_tag_map    商品 ↔ 標籤，source 記錄是規則標的還是人工標的
--
-- 規則怎麼來的：把 1,831 個商品名讀過一輪、寫成 regex，本機反覆跑到覆蓋率夠
--   （未分類商品 229 個 = 近 120 天購買人次的 4.1%），再原封不動搬進 rules 表。
--   規則覆蓋不到、但買家數 >= 6 的 113 個商品，在本檔尾端以 source='manual'
--   逐一指定 —— 人工列永遠優先，重跑規則不會被蓋掉。
--
-- ⚠ pattern 走 Postgres ARE（`name ~* pattern`）：
--   - 支援 negative lookahead `(?!...)`（已實測），所以「牛(?!奶|乳|舌餅|角)」
--     這種排除法可用 —— 牛舌餅是零食不是肉品。
--   - **不要用 `\b` 當字界**，ARE 裡 `\b` 是退格字元，要用 `\y`。
--
-- 互斥群組 exclusive_group：溫層（冷凍/冷藏）同一個商品只能有一個，
--   由 apply 函式依 priority 取第一個命中的；其餘標籤一律可累加。
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.rpc_apply_product_tag_rules(boolean);
--   DROP TABLE IF EXISTS product_tag_map, product_tag_rules, product_tags;
-- ============================================================================

CREATE TABLE IF NOT EXISTS product_tags (
  id         BIGSERIAL   PRIMARY KEY,
  tenant_id  UUID        NOT NULL,
  code       TEXT        NOT NULL,
  name       TEXT        NOT NULL,
  tag_group  TEXT        NOT NULL DEFAULT '其他',
  sort       INTEGER     NOT NULL DEFAULT 0,
  is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (tenant_id, code)
);
COMMENT ON TABLE product_tags IS '商品標籤字彙（多標籤）。tag_group 只影響 UI 分組，不影響分析';

CREATE TABLE IF NOT EXISTS product_tag_rules (
  id              BIGSERIAL   PRIMARY KEY,
  tenant_id       UUID        NOT NULL,
  -- 商品名比對用的 Postgres ARE regex（`products.name ~* pattern`，大小寫不敏感）
  pattern         TEXT        NOT NULL,
  tag_code        TEXT        NOT NULL,
  priority        INTEGER     NOT NULL DEFAULT 100,
  -- 同一群組內只取 priority 最小的那條命中規則（目前只有溫層 'temp' 在用）
  exclusive_group TEXT,
  is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
  note            TEXT,
  UNIQUE (tenant_id, pattern, tag_code)
);
COMMENT ON TABLE product_tag_rules IS
  '商品名 → 標籤的規則。新商品上架後跑 rpc_apply_product_tag_rules() 就會自動標；'
  'pattern 是 Postgres ARE，字界要用 \y 不是 \b';

CREATE TABLE IF NOT EXISTS product_tag_map (
  tenant_id  UUID        NOT NULL,
  product_id BIGINT      NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  tag_id     BIGINT      NOT NULL REFERENCES product_tags(id) ON DELETE CASCADE,
  source     TEXT        NOT NULL DEFAULT 'rule' CHECK (source IN ('rule','manual')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (product_id, tag_id)
);
CREATE INDEX IF NOT EXISTS idx_ptm_tag ON product_tag_map (tag_id);
COMMENT ON COLUMN product_tag_map.source IS
  'rule = 規則標的（重跑會被重算）；manual = 人工指定（重跑一律保留）';

ALTER TABLE product_tags      ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_tag_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_tag_map   ENABLE ROW LEVEL SECURITY;

-- 讀：同租戶的登入者都能讀（分店也要看得到自己店的偏好分析）。
-- 寫：一律走 SECURITY DEFINER 的 RPC，不開 INSERT/UPDATE/DELETE policy。
DROP POLICY IF EXISTS pt_read ON product_tags;
CREATE POLICY pt_read ON product_tags FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);
DROP POLICY IF EXISTS ptr_read ON product_tag_rules;
CREATE POLICY ptr_read ON product_tag_rules FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);
DROP POLICY IF EXISTS ptm_read ON product_tag_map;
CREATE POLICY ptm_read ON product_tag_map FOR SELECT
  USING (tenant_id = (auth.jwt() ->> 'tenant_id')::UUID);

GRANT SELECT ON product_tags, product_tag_rules, product_tag_map TO authenticated;

-- ============================================================================
-- 標籤字彙 + 規則（由 tagger 產生，勿手改；要改規則請走 UI / 新 migration）
-- ============================================================================
INSERT INTO product_tags (tenant_id, code, name, tag_group, sort)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, v.code, v.name, v.tag_group, v.sort
  FROM (VALUES
  ('frozen', '冷凍', '溫層', 0),
  ('chilled', '冷藏', '溫層', 10),
  ('ambient', '常溫', '溫層', 20),
  ('seafood', '海鮮水產', '生鮮', 30),
  ('meat', '肉品', '生鮮', 40),
  ('egg', '蛋品', '生鮮', 50),
  ('vegetable', '蔬菜', '生鮮', 60),
  ('fruit', '水果', '生鮮', 70),
  ('soy', '豆製品', '生鮮', 80),
  ('dairy', '乳品', '生鮮', 90),
  ('prepared', '熟食調理', '食品', 100),
  ('staple', '米麵主食', '食品', 110),
  ('bakery', '麵包烘焙', '食品', 120),
  ('dessert', '甜點', '食品', 130),
  ('icecream', '冰品', '食品', 140),
  ('snack', '零食餅乾', '食品', 150),
  ('candy', '糖果巧克力', '食品', 160),
  ('specialty', '名產伴手禮', '食品', 170),
  ('drygoods', '乾貨南北貨', '食品', 180),
  ('seasoning', '調味醬料', '食品', 190),
  ('drink', '飲品', '食品', 200),
  ('health', '保健', '食品', 210),
  ('pickles', '醃漬小菜', '食品', 220),
  ('veg_diet', '素食', '食品', 230),
  ('cleaning', '清潔用品', '非食品', 240),
  ('daily', '日用品', '非食品', 250),
  ('personal', '個人清潔', '非食品', 260),
  ('beauty', '美妝保養', '非食品', 270),
  ('kitchen', '廚房用品', '非食品', 280),
  ('home', '居家用品', '非食品', 290),
  ('apparel', '服飾配件', '非食品', 300),
  ('bedding', '寢具', '非食品', 310),
  ('gadget', '3C小物', '非食品', 320),
  ('pet', '寵物', '非食品', 330),
  ('stationery', '文具', '非食品', 340),
  ('kids', '童趣玩具', '非食品', 350),
  ('jp', '日本商品', '屬性', 360),
  ('kr', '韓國商品', '屬性', 370),
  ('gift', '禮盒節慶', '屬性', 380)
  ) AS v(code, name, tag_group, sort)
ON CONFLICT (tenant_id, code) DO UPDATE
   SET name = EXCLUDED.name, tag_group = EXCLUDED.tag_group, sort = EXCLUDED.sort;

INSERT INTO product_tag_rules (tenant_id, pattern, tag_code, priority, exclusive_group)
SELECT '00000000-0000-0000-0000-000000000001'::uuid, v.pattern, v.tag_code, v.priority, v.exclusive_group
  FROM (VALUES
  ('蝦|蟹|花枝|小卷|軟絲|透抽|魷魚|章魚|干貝|扇貝|蛤|蜆|生蠔|牡蠣|蚵|鮑魚(?!菇)', 'seafood', 10, NULL),
  ('鮭魚|鯖魚|鱸魚|virgin|鯛魚|土魠|旗魚|秋刀魚|香魚|虱目|多利魚|巴沙|鱈魚|鮪魚|吳郭魚|石斑|白帶魚|烏魚|魚肚|魚片|魚排|一夜干|魚丸|魚鬆|鰻', 'seafood', 20, NULL),
  ('海鮮|水產|海產|漁夫|漁港|生食級|刺身|海苔|紫菜|海帶|昆布|櫻花蝦|小魚乾|丁香魚', 'seafood', 30, NULL),
  ('魚卵|烏魚子|明太子|蝦仁|蝦球|蝦捲|蝦餅|花枝漿|花枝丸|龍蝦|帝王蟹', 'seafood', 40, NULL),
  ('豬|牛(?!奶|乳|舌餅|軋|角|蒡)|雞(?!蛋|精)|鴨(?!賞茶)|鵝肉|羊肉|培根|火腿|香腸|臘肉|肉片|肉絲|肉條|肉排|絞肉|排骨|里肌|松阪|梅花|五花|牛腩|牛小排|雞腿|雞胸|雞翅|雞塊|雞爪|鳳爪|鴨胸|鴨翅|米腸|貢丸|獅子頭|漢堡排|肉鬆|肉乾|肉紙', 'meat', 50, NULL),
  ('滷味|滷肉|烤肉|叉燒|東坡|蹄膀|豬腳|大腸|嘴邊肉|粉肝|豬肝|豬心|雞心|鴨舌|豬舌', 'meat', 60, NULL),
  ('雞蛋|土雞蛋|鴨蛋|皮蛋|鹹蛋|鵪鶉蛋|好蛋|蛋$|蛋（|蛋\(', 'egg', 70, NULL),
  ('豆漿|豆干|豆乾|豆腐|豆皮|豆包|腐皮|臭豆腐|百頁|豆花|素雞|烤麩|麵腸', 'soy', 80, NULL),
  ('鮮乳|鮮奶|牛奶|優格|優酪|起司|乳酪|奶油|鮮奶油|養樂多|拿鐵|煉乳|生乳', 'dairy', 90, NULL),
  ('高麗菜|青菜|生菜|菠菜|地瓜葉|蔥|蒜|薑|洋蔥|蘿蔔|筍|菇|木耳|玉米|南瓜|芋頭|馬鈴薯|地瓜|番薯|山藥|絲瓜|小黃瓜|茄子|辣椒|青椒|甜椒|花椰|芹菜|韭菜|豆芽|毛豆|四季豆|秋葵|山蘇|野菜|有機蔬菜|蔬菜|沙拉', 'vegetable', 100, NULL),
  ('蘋果|香蕉|葡萄|櫻桃|水蜜桃|芒果|鳳梨|西瓜|哈密瓜|香瓜|草莓|藍莓|莓果|柳丁|柳橙|橘|檸檬|芭樂|棗|梨|荔枝|龍眼|榴槤|酪梨|百香果|柿|奇異果|火龍果|釋迦|蓮霧|玉荷包|水果', 'fruit', 110, NULL),
  ('水餃|餛飩|抄手|湯圓|包子|饅頭|燒賣|鍋貼|春捲|蔥抓餅|蛋餅|涼麵|炒麵|拌麵|米粉|冬粉|粉絲|米糕|油飯|炒飯|飯糰|便當|燴飯|咖哩|燉|滷|羹|湯$|湯（|火鍋|鍋物|調理包|即食|微波|舒肥|炸雞|雞排|鹽酥|天婦羅|甜不辣|黑輪|關東煮|披薩|pizza|義大利麵|烏龍麵|拉麵|泡麵|粥|粽|carbonara', 'prepared', 120, NULL),
  ('月亮蝦餅|煎餃|生煎|腸粉|蘿蔔糕|芋頭糕|碗粿|肉圓|草仔粿|鹹粥|米苔目|意麵|板條|河粉', 'prepared', 130, NULL),
  ('白米|糙米|池上米|台梗|米\s*\d|kg米|香米|糯米|麵條|麵線|義麵|乾麵|麵$', 'staple', 140, NULL),
  ('堅果|腰果|杏仁|核桃|夏威夷豆|開心果|花生(?!醬)|瓜子|果乾|蜜餞|香菇乾|干貨|南北貨|米粉$|冬粉$|藜麥|燕麥|穀物|薏仁|紅豆|綠豆|蓮子|銀耳|白木耳', 'drygoods', 150, NULL),
  ('麵包|吐司|貝果|可頌|餐包|棍|甜甜圈|蛋糕|泡芙|塔$|派$|司康|布朗尼|瑪德蓮|銅鑼燒|鬆餅|捲$|蛋捲|烘焙|烘培|窯烤', 'bakery', 160, NULL),
  ('蛋撻|布丁|果凍|奶酪|提拉米蘇|千層|慕斯|甜點|杏仁豆腐|愛玉|仙草(?!茶)|豆花|芋圓|粉粿|麻糬|羊羹|糕$|甜品', 'dessert', 170, NULL),
  ('冰淇淋|冰棒|雪糕|枝仔冰|冰沙|雪酪|冰磚|冰餅|剉冰|情人果冰|gelato|芋仔冰|冰角|冰心', 'icecream', 180, NULL),
  ('洋芋片|餅乾|蘇打餅|米餅|仙貝|爆米花|薯條|蝦條|脆片|海苔脆|沙琪瑪|米香|牛軋|蛋黃酥|鳳梨酥|牛舌餅|太陽餅|大餅|酥餅|燒餅|麻花|小圓餅|零嘴|零食', 'snack', 190, NULL),
  ('巧克力|軟糖|糖果|棒棒糖|喉糖|咖啡糖|布丁糖|麥芽糖|牛奶糖', 'candy', 200, NULL),
  ('名產|伴手禮|老街|排隊名店|百年老店|老字號|人氣名店|隱藏版|老店|眷村|古早味|懷舊', 'specialty', 210, NULL),
  ('醬(?!菜)|醬油|沙茶|辣椒醬|胡椒|椒鹽|海鹽|鹽$|糖$|味精|高湯|香料|咖哩塊|醋|米酒|麻油|苦茶油|橄欖油|沙拉油|調味', 'seasoning', 220, NULL),
  ('咖啡|茶(?!樹|几|色)|奶茶|果汁|汁$|飲料|飲品|氣泡水|礦泉水|豆漿$|米漿|烏梅汁|仙草茶|青草茶|杏仁茶|冬瓜|養生飲|沖泡', 'drink', 230, NULL),
  ('膠原蛋白|益生菌|葉黃素|魚油|維他命|維生素|保健|營養補充|軟骨素|氨醣|B群|鈣片|酵素(?!地板|洗)|代謝茶|山楂|窈窕', 'health', 240, NULL),
  ('素食|全素|蔬食|純素|素☘|猴頭菇', 'veg_diet', 250, NULL),
  ('洗衣|柔軟精|漂白|除霉|清潔劑|清潔膠|清潔錠|清潔劑|洗碗精|洗潔精|去污|除垢|管道|排水|馬桶|地板清潔|抹布|菜瓜布|除臭|芳香劑|除蟲|蟑螂|蚊|殺菌|消毒|清潔刷|清潔濕巾|去油', 'cleaning', 260, NULL),
  ('洗衣|柔軟精|漂白|除霉|清潔劑|清潔膠|清潔錠|清潔劑|洗碗精|洗潔精|去污|除垢|管道|排水|馬桶|地板清潔|抹布|菜瓜布|除臭|芳香劑|除蟲|蟑螂|蚊|殺菌|消毒|清潔刷|清潔濕巾|去油', 'daily', 260, NULL),
  ('濕紙巾|紙巾|衛生紙|垃圾袋|夾鏈袋|保鮮膜|鋁箔紙|棉花棒|電池|一次性|拋棄式|免洗|口罩|牙籤|棉條', 'daily', 270, NULL),
  ('洗髮|潤髮|沐浴|香皂|肥皂|洗手|牙膏|牙刷|牙線|漱口|衛生棉|護墊|刮鬍|除毛|足膜|指甲|梳$|髮梳', 'personal', 280, NULL),
  ('洗髮|潤髮|沐浴|香皂|肥皂|洗手|牙膏|牙刷|牙線|漱口|衛生棉|護墊|刮鬍|除毛|足膜|指甲|梳$|髮梳', 'daily', 280, NULL),
  ('保養|精華|乳液|面膜|化妝|彩妝|口紅|唇膏|防曬|美白|保濕|身體乳|護手霜|香水|花露水|去角質|安瓶|眼霜|精油|按摩霜|推拿霜|痠痛貼', 'beauty', 290, NULL),
  ('保鮮袋|保鮮盒|密封袋|鋁箔|烘焙紙|廚房紙|量杯|鍋$|平底鍋|刀具|砧板|餐具|筷|湯匙|叉|碗盤|杯$|保溫瓶|水壺|濾網|瀝水|開瓶|削皮|磨泥|烤盤|便當盒|防溢', 'kitchen', 300, NULL),
  ('收納|置物|掛勾|衣架|掃把|拖把|垃圾桶|坐墊|沙發|窗簾|地墊|腳踏墊|傘$|雨傘|行李箱|磁條|磁吸|架$|貼紙|標籤|燈$|檯燈|蠟燭|擴香|驅蚊|風扇|除濕|防塵|鑰匙圈|夜燈|支架', 'home', 310, NULL),
  ('床包|枕|棉被|涼被|被套|床單|寢具|涼蓆', 'bedding', 320, NULL),
  ('充電|電子|智能|藍牙|usb|type-c|行動電源|耳機|手機|平板|電池|體脂|吹風機|按摩槍|3c', 'gadget', 330, NULL),
  ('襪|拖鞋|鞋$|帽$|漁夫帽|空頂帽|內衣|內褲|衣$|褲$|裙$|外套|圍巾|髮夾|抓夾|髮圈|包包|背包|眼鏡|飾品|項鍊|耳環|防曬手套|保暖手套|皮帶', 'apparel', 340, NULL),
  ('寵物|飼料|貓砂|狗糧|牽繩|逗貓|除毛手套|寵物涼蓆', 'pet', 350, NULL),
  ('壽司|小籠包|水晶餃|捲餅|手抓餅|燒餃子|卜肉|大排|米血|玉子燒|陽春麵|薯餅|比薩|煎包|刈包|水煎|燒臘|焗烤|嫩煎|香煎|預炸|熟凍', 'prepared', 360, NULL),
  ('泡菜|涼拌|開胃小菜|小菜|貢菜|酸豆角|醬菜|酸菜|梅干菜|蔭瓜|豆腐乳|味噌|漬物|筍乾', 'pickles', 370, NULL),
  ('番茄|蕃茄|水蓮|桑椹|青花菜|甘蔗|地瓜葉|過貓|皇宮菜|川七|龍鬚菜|A菜|莧菜', 'vegetable', 380, NULL),
  ('奶凍|拿破崙|桃酥|黑糖糕|發糕|綠豆糕|鳳片糕|雪花酥|蛋黃派', 'dessert', 390, NULL),
  ('禮餅|餅舖|餅鋪|喜餅', 'snack', 400, NULL),
  ('禮餅|餅舖|餅鋪|喜餅', 'gift', 400, NULL),
  ('哈根達斯|冰果室|冰桃|霜淇淋|聖代', 'icecream', 410, NULL),
  ('毛巾|浴巾|方巾|抹手巾|擦手巾', 'daily', 420, NULL),
  ('蒟蒻|梅子乾|脆梅|青梅|話梅|果乾|米果|苦瓜片|海苔酥|豆乾條', 'snack', 430, NULL),
  ('椰子水|花釀|果釀|原汁|金萱|烏龍|包種|紅茶|綠茶|奶蓋|泰奶|豆奶|燕麥奶', 'drink', 440, NULL),
  ('鷹嘴豆|亞麻籽|芥花油|橄欖油|苦茶油|冷壓|食用油|沙拉油|香油', 'seasoning', 450, NULL),
  ('西谷米|小米|甜菜根粉|奇亞籽|洋車前子|四神|甘草|陳皮|杏仁粉|擂茶|穀粉|麥片', 'drygoods', 460, NULL),
  ('護腕|護膝|刮痧|拔罐|艾草|舒緩貼|磁力貼|矯正|筋膜|痠痛|助眠|醫藥包|百靈油|活絡油|噴鼻|護眼|蔓越莓|人蔘|足貼|按摩', 'health', 470, NULL),
  ('洗面|潔顏|護髮|修眉|眉刀|爽身|體香|卸妝|化妝棉|面膜|頭皮', 'beauty', 480, NULL),
  ('洗面|潔顏|護髮|修眉|眉刀|爽身|體香|卸妝|化妝棉|面膜|頭皮', 'personal', 480, NULL),
  ('便利貼|書簽|書籤|線圈本|便條|修正帶|訂書機|螢光筆|原子筆|鉛筆|文具|筆記本|貼紙書', 'stationery', 490, NULL),
  ('玩具|跳跳球|刮畫|水槍|撲克牌|拼圖|扭蛋|娃娃|公仔|早教|兒童.*(球|車|樂)', 'kids', 500, NULL),
  ('保冷包|購物袋|環保袋|提袋|收納包|洗漱包', 'home', 510, NULL),
  ('瑜伽|拉力帶|健身|運動毛巾|護具', 'apparel', 520, NULL),
  ('鏟|勺|刮刀|隔熱墊|保鮮桶|吸油紙|量匙|壓泥|冰格|過濾器|油煙機|料理夾|保鮮|瀝油|廚房|食品級|烘焙用|擠花|磨刀|刨', 'kitchen', 530, NULL),
  ('掛鉤|掛勾|防撞角|晾衣|垃圾筒|除塵|魔力扣|繞線|易拉扣|壁燈|盆栽|涼墊|保潔墊|卷尺|耳塞|修枝剪|掛飾|吊牌|免打孔|自粘|背膠|置物|防滑墊|門擋', 'home', 540, NULL),
  ('去漬|清潔神器|消臭|小蘇打|海綿|除霉|洗滌|柔軟|去垢|潔淨噴霧', 'cleaning', 550, NULL),
  ('去漬|清潔神器|消臭|小蘇打|海綿|除霉|洗滌|柔軟|去垢|潔淨噴霧', 'daily', 550, NULL),
  ('貼布|繃帶|脫毛|雙眼皮|瀏海貼|粉撲|美容工具|修護膏|舒涼霜|萬用膏|袪斑', 'beauty', 560, NULL),
  ('月餅', 'snack', 570, NULL),
  ('月餅', 'gift', 570, NULL),
  ('手撕包|餐包|軟法|恰巴達|巧巴達', 'bakery', 580, NULL),
  ('火山豆|夏威夷豆|榛果|松子|南瓜子', 'drygoods', 590, NULL),
  ('粉圓|珍珠(?!芭樂|洋蔥)|仙草凍|布丁豆花', 'dessert', 600, NULL),
  ('小捲|午仔|肉魚|鯊魚煙|柳葉魚|丸仔|魚翅|海味', 'seafood', 610, NULL),
  ('豚肉|翅小腿|翅包飯|腿酥|二節翅|胖胖翅|棒棒腿|肉粽|貢丸', 'meat', 620, NULL),
  ('孢子甘藍|金瓜|山蘇|過貓', 'vegetable', 630, NULL),
  ('雪霜橄欖|情人果|芒果乾|芭樂乾', 'snack', 640, NULL),
  ('雨衣|泳|家居裙|皮夾|手鍊|手環|編織包|髮飾|口金包', 'apparel', 650, NULL),
  ('鋅錠|睡鎂|光片|滴劑|錠$|膠囊|粉包|沖劑', 'health', 660, NULL),
  ('製麵|種米|米達人|白飯|糙米飯', 'staple', 670, NULL),
  ('日本|🇯🇵|日製|日本製|代購.*日|jp\b', 'jp', 680, NULL),
  ('韓國|🇰🇷|韓式|韓製|한', 'kr', 690, NULL),
  ('禮盒|中秋|月餅|端午|粽|年節|過年|春節|賀禮|彌月|福袋|禮品', 'gift', 700, NULL),
  ('冷凍|急凍|活凍|凍$|冰棒|冰淇淋|雪糕|枝仔冰|冰沙|雪酪|冰磚|冷凍莓果|生鮮.*凍|iqf|鮮凍|凍力', 'frozen', 10, 'temp'),
  ('燒餃子|薯餅|米血|小籠包|水晶餃|柳葉魚|孢子甘藍|水餃|餛飩|抄手|鍋貼|生煎|包子|饅頭|燒賣|春捲|蔥抓餅|蛋餅|雞排|炸雞|鹽酥|甜不辣|黑輪|花枝漿|蝦餅|魚片|魚排|肉片|肉排|雞腿|雞胸|排骨|松阪|里肌|牛腩|火鍋肉|蝦仁|小卷|花枝|干貝|鮭魚|鯖魚|鱸魚|土魠|秋刀魚|虱目|調理包|舒肥', 'frozen', 20, 'temp'),
  ('泡菜|涼拌|現撈|現殺|生鮮|鮮乳|鮮奶|生乳|優格|優酪|生菜|有機蔬菜|蔬菜|水果|青菜|豆花|冷藏|新鮮|生食級|刺身|雞蛋|好蛋|土雞蛋', 'chilled', 30, 'temp')
  ) AS v(pattern, tag_code, priority, exclusive_group)
ON CONFLICT (tenant_id, pattern, tag_code) DO UPDATE
   SET priority = EXCLUDED.priority, exclusive_group = EXCLUDED.exclusive_group;


-- ============================================================================
-- rpc_apply_product_tag_rules — 依規則重算 source='rule' 的標籤
--   p_only_missing = TRUE ：只處理「目前完全沒有任何標籤」的商品（新商品用）
--   p_only_missing = FALSE：整批重算（改過規則之後用）
-- 人工列（source='manual'）在兩種模式下都原封不動。
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_apply_product_tag_rules(
  p_only_missing BOOLEAN DEFAULT TRUE
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tenant  UUID := public._current_tenant_id();
  v_role    TEXT := COALESCE(auth.jwt() -> 'app_metadata' ->> 'role', '');
  v_before  BIGINT;
  v_after   BIGINT;
  v_untagged BIGINT;
BEGIN
  IF v_role NOT IN ('owner', 'admin', '') THEN
    RAISE EXCEPTION 'insufficient_role: 只有負責人 / 管理員可以重跑商品標籤';
  END IF;

  SELECT count(*) INTO v_before FROM product_tag_map WHERE tenant_id = v_tenant;

  CREATE TEMP TABLE _targets ON COMMIT DROP AS
    SELECT p.id, p.name
      FROM products p
     WHERE p.tenant_id = v_tenant
       AND (NOT p_only_missing OR NOT EXISTS (
             SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id));

  -- 重算範圍內的規則列先清掉（人工列不動）
  DELETE FROM product_tag_map m
   USING _targets t
   WHERE m.product_id = t.id AND m.source = 'rule' AND m.tenant_id = v_tenant;

  -- 1) 一般規則：命中就加，可累加
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT DISTINCT v_tenant, t.id, tg.id, 'rule'
    FROM _targets t
    JOIN product_tag_rules r ON r.tenant_id = v_tenant AND r.is_active
                            AND r.exclusive_group IS NULL
                            AND t.name ~* r.pattern
    JOIN product_tags tg ON tg.tenant_id = v_tenant AND tg.code = r.tag_code
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  -- 2) 互斥群組（溫層）：同群組只取 priority 最小的那條命中規則
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT v_tenant, x.product_id, tg.id, 'rule'
    FROM (
      SELECT DISTINCT ON (t.id, r.exclusive_group)
             t.id AS product_id, r.tag_code
        FROM _targets t
        JOIN product_tag_rules r ON r.tenant_id = v_tenant AND r.is_active
                                AND r.exclusive_group IS NOT NULL
                                AND t.name ~* r.pattern
       ORDER BY t.id, r.exclusive_group, r.priority, r.id
    ) x
    JOIN product_tags tg ON tg.tenant_id = v_tenant AND tg.code = x.tag_code
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  -- 3) 常溫＝「是食品，但沒被判成冷凍/冷藏」。這個沒辦法用 regex 表達（它是
  --    「其他規則都沒中」），所以放在規則之後補。非食品不給溫層 —— 洗衣精標常溫
  --    只會讓「常溫」這個標籤失去意義。
  INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
  SELECT v_tenant, t.id, (SELECT id FROM product_tags WHERE tenant_id = v_tenant AND code = 'ambient'), 'rule'
    FROM _targets t
   WHERE EXISTS (
           SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
            WHERE m.product_id = t.id AND g.tag_group IN ('生鮮','食品'))
     AND NOT EXISTS (
           SELECT 1 FROM product_tag_map m JOIN product_tags g ON g.id = m.tag_id
            WHERE m.product_id = t.id AND g.code IN ('frozen','chilled'))
  ON CONFLICT (product_id, tag_id) DO NOTHING;

  SELECT count(*) INTO v_after FROM product_tag_map WHERE tenant_id = v_tenant;
  SELECT count(*) INTO v_untagged
    FROM products p
   WHERE p.tenant_id = v_tenant
     AND NOT EXISTS (SELECT 1 FROM product_tag_map m WHERE m.product_id = p.id);

  RETURN jsonb_build_object(
    'scope',    CASE WHEN p_only_missing THEN 'only_missing' ELSE 'all' END,
    'targets',  (SELECT count(*) FROM _targets),
    'rows_before', v_before,
    'rows_after',  v_after,
    'untagged_products', v_untagged
  );
END;
$$;

COMMENT ON FUNCTION public.rpc_apply_product_tag_rules(boolean) IS
  '依 product_tag_rules 重算商品標籤（owner/admin）。人工標的（source=manual）一律保留。'
  '預設只補「完全沒標籤」的商品；改過規則後傳 FALSE 整批重算。';

GRANT EXECUTE ON FUNCTION public.rpc_apply_product_tag_rules(boolean) TO authenticated;

-- 首次全量套用。
-- ⚠ 這裡不能呼叫 rpc_apply_product_tag_rules() —— 它靠 _current_tenant_id() 讀 JWT，
--   而 migration 沒有 JWT（會 RAISE 'JWT missing tenant_id claim'）。
--   所以首次套用用同一套邏輯的純 SQL，租戶取自規則表自己。
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

-- 常溫＝是食品但沒判成冷凍/冷藏（同函式第 3 步，見上面註解）
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

-- ============================================================================
-- 人工指定（規則覆蓋不到、且買家數 >= 6 的商品；一件一件看名字標的）
-- ============================================================================
INSERT INTO product_tag_map (tenant_id, product_id, tag_id, source)
SELECT p.tenant_id, p.id, t.id, 'manual'
  FROM (VALUES
  (752, 'snack'),
  (752, 'jp'),
  (780, 'health'),
  (780, 'beauty'),
  (784, 'apparel'),
  (784, 'personal'),
  (808, 'home'),
  (808, 'jp'),
  (826, 'apparel'),
  (872, 'seafood'),
  (966, 'beauty'),
  (966, 'kr'),
  (970, 'cleaning'),
  (970, 'daily'),
  (981, 'home'),
  (997, 'gadget'),
  (997, 'kitchen'),
  (1013, 'beauty'),
  (1016, 'beauty'),
  (1016, 'jp'),
  (1030, 'prepared'),
  (1039, 'personal'),
  (1042, 'kitchen'),
  (1081, 'home'),
  (1081, 'kids'),
  (1089, 'kitchen'),
  (1106, 'prepared'),
  (1108, 'candy'),
  (1108, 'kr'),
  (1115, 'home'),
  (1115, 'daily'),
  (1115, 'jp'),
  (1139, 'home'),
  (1150, 'beauty'),
  (1150, 'jp'),
  (1174, 'cleaning'),
  (1174, 'daily'),
  (1174, 'jp'),
  (1178, 'home'),
  (1188, 'kitchen'),
  (1210, 'home'),
  (1210, 'apparel'),
  (1212, 'daily'),
  (1212, 'apparel'),
  (1249, 'health'),
  (1269, 'prepared'),
  (1288, 'health'),
  (1303, 'seasoning'),
  (1328, 'snack'),
  (1328, 'drygoods'),
  (1364, 'health'),
  (1370, 'beauty'),
  (1372, 'pickles'),
  (1390, 'health'),
  (1400, 'home'),
  (1417, 'stationery'),
  (1417, 'home'),
  (1468, 'health'),
  (1468, 'drygoods'),
  (1492, 'home'),
  (1492, 'health'),
  (1551, 'stationery'),
  (1559, 'snack'),
  (1559, 'gift'),
  (1564, 'kids'),
  (1598, 'snack'),
  (1606, 'personal'),
  (1606, 'daily'),
  (1618, 'beauty'),
  (1618, 'kr'),
  (1645, 'kitchen'),
  (1651, 'home'),
  (1697, 'gadget'),
  (1697, 'home'),
  (1700, 'cleaning'),
  (1700, 'kr'),
  (1709, 'apparel'),
  (1733, 'stationery'),
  (1739, 'home'),
  (1742, 'snack'),
  (1742, 'drygoods'),
  (1750, 'prepared'),
  (1750, 'seasoning'),
  (1751, 'meat'),
  (1751, 'prepared'),
  (1754, 'health'),
  (1775, 'prepared'),
  (1821, 'cleaning'),
  (1821, 'daily'),
  (1822, 'kids'),
  (1831, 'prepared'),
  (1831, 'staple'),
  (1835, 'snack'),
  (1835, 'gift'),
  (1839, 'prepared'),
  (1839, 'staple'),
  (1839, 'gift'),
  (1845, 'fruit'),
  (1873, 'kitchen'),
  (1881, 'home'),
  (1883, 'kitchen'),
  (1895, 'health'),
  (1895, 'kr'),
  (1899, 'beauty'),
  (1900, 'beauty'),
  (1925, 'egg'),
  (1925, 'prepared'),
  (1985, 'prepared'),
  (1985, 'specialty'),
  (1985, 'seafood'),
  (2001, 'kitchen'),
  (2017, 'prepared'),
  (2028, 'candy'),
  (2030, 'cleaning'),
  (2030, 'daily'),
  (2034, 'home'),
  (2079, 'daily'),
  (2079, 'cleaning'),
  (2094, 'pickles'),
  (2100, 'beauty'),
  (2100, 'personal'),
  (2105, 'cleaning'),
  (2105, 'daily'),
  (2170, 'apparel'),
  (2171, 'prepared'),
  (2171, 'meat'),
  (2178, 'beauty'),
  (2178, 'kr'),
  (2211, 'apparel'),
  (2213, 'health'),
  (2221, 'stationery'),
  (2259, 'drygoods'),
  (2259, 'health'),
  (2262, 'drink'),
  (2264, 'health'),
  (2265, 'beauty'),
  (2265, 'kr'),
  (2267, 'cleaning'),
  (2267, 'gadget'),
  (2292, 'apparel'),
  (2316, 'stationery'),
  (2318, 'seafood'),
  (2336, 'kitchen'),
  (2342, 'beauty'),
  (2358, 'kids'),
  (2358, 'kitchen'),
  (2361, 'fruit'),
  (2371, 'apparel'),
  (2371, 'personal'),
  (2374, 'seafood'),
  (2374, 'prepared'),
  (2374, 'kr'),
  (2385, 'beauty'),
  (2385, 'personal'),
  (2390, 'kitchen'),
  (2391, 'stationery'),
  (2397, 'bakery'),
  (2402, 'vegetable'),
  (2411, 'stationery'),
  (2415, 'home'),
  (2416, 'daily'),
  (2416, 'apparel'),
  (2418, 'drygoods'),
  (2418, 'vegetable'),
  (2437, 'home'),
  (2437, 'jp')
  ) AS v(product_id, tag_code)
  JOIN products    p ON p.id = v.product_id
  JOIN product_tags t ON t.code = v.tag_code AND t.tenant_id = p.tenant_id
ON CONFLICT (product_id, tag_id) DO UPDATE SET source = 'manual';
