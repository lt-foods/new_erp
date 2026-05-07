-- ============================================================================
-- forbid_ledger_mutation 允許「合併會員時 member_id 變更」
--
-- 原 trigger 把 ledger 視為完全 immutable → rpc_merge_member 想 UPDATE member_id
-- 把 source 的流水搬到 target 時被擋。
--
-- 放寬：UPDATE 時若**只有 member_id 變動**（其他欄位皆不變），允許通過。
-- 這保持「ledger 內容（amount / balance_after / created_at / type / reason）immutable」
-- 但讓會員合併能歸戶。
-- ============================================================================

CREATE OR REPLACE FUNCTION forbid_ledger_mutation()
RETURNS TRIGGER AS $$
DECLARE
  v_old_strip JSONB;
  v_new_strip JSONB;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- 把 OLD / NEW 轉 jsonb，扣掉 member_id 後比對；其他欄位完全相同才放行
    v_old_strip := to_jsonb(OLD) - 'member_id';
    v_new_strip := to_jsonb(NEW) - 'member_id';
    IF v_old_strip = v_new_strip THEN
      RETURN NEW;
    END IF;
  END IF;
  RAISE EXCEPTION '% is append-only. Use a reversing entry.', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;
