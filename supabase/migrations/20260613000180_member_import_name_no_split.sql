-- ============================================================
-- 樂樂 CSV 名字「不切割」：整段塞 members.name + parsed_name
--
-- 原本 _parse_lele_name 用 regex 抽出 `【...】` 中間段當 name、後綴存 suffix；
-- 但樂樂顧客代號 + 取貨店 hint 都在原始字串裡，切掉後使用者搜尋
--   「15627428」/「松山」/「209785」 全部都搜不到。
--
-- 改成：name = TRIM(p_raw)、suffix = NULL，整段都留在 name 欄位。
-- 既有 lele 會員 + member_imports 一併用 raw_data 回補（只動沒被手動編輯過的）。
-- ============================================================

-- 1. _parse_lele_name 不再切割
CREATE OR REPLACE FUNCTION public._parse_lele_name(p_raw TEXT)
RETURNS JSONB LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_trim TEXT;
BEGIN
  v_trim := NULLIF(TRIM(p_raw), '');
  RETURN jsonb_build_object('name', v_trim, 'suffix', NULL);
END;
$$;

COMMENT ON FUNCTION public._parse_lele_name(TEXT) IS
  '樂樂名字整段 trim 後當 name；不切「#代號 : 【姓名】後綴」，方便整段搜尋。';

-- ------------------------------------------------------------
-- 2. 回補既有 members.name
--    順序很重要：先 members（用舊 mi.parsed_name 判斷未編輯）、再 member_imports。
--    條件：member.name = 當初 stage 切出來的 parsed_name 才覆寫，
--    意即沒被手動編輯過的；手動改過的（如 admin 在 UI 改成「Vicky」）保留。
-- ------------------------------------------------------------
WITH src AS (
  SELECT DISTINCT ON (mi.resolved_member_id)
    mi.resolved_member_id AS member_id,
    mi.tenant_id,
    mi.parsed_name        AS old_parsed_name,
    TRIM(mi.raw_data->>'name_raw') AS full_name
  FROM member_imports mi
  WHERE mi.source = 'lele'
    AND mi.resolved_member_id IS NOT NULL
    AND mi.raw_data ? 'name_raw'
    AND TRIM(COALESCE(mi.raw_data->>'name_raw','')) <> ''
  ORDER BY mi.resolved_member_id, mi.updated_at DESC
)
UPDATE members m SET
  name       = src.full_name,
  updated_at = NOW()
FROM src
WHERE m.id = src.member_id
  AND m.tenant_id = src.tenant_id
  AND m.external_source = 'lele'
  AND m.name = src.old_parsed_name   -- 未被手動編輯
  AND m.name IS DISTINCT FROM src.full_name;

-- ------------------------------------------------------------
-- 3. 回補既有 member_imports.parsed_name（lele 來源 + 切過的）
--    要在 §2 之後跑，因為 §2 用到舊 parsed_name。
-- ------------------------------------------------------------
UPDATE member_imports SET
  parsed_name        = TRIM(raw_data->>'name_raw'),
  parsed_name_suffix = NULL,
  parsed_notes       = NULL,
  updated_at         = NOW()
WHERE source = 'lele'
  AND raw_data ? 'name_raw'
  AND TRIM(COALESCE(raw_data->>'name_raw','')) <> ''
  AND (
    parsed_name IS DISTINCT FROM TRIM(raw_data->>'name_raw')
    OR parsed_name_suffix IS NOT NULL
    OR parsed_notes IS NOT NULL
  );
