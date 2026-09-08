-- Self-contained check for 20260908000000_release_short_picked_wave_qty.sql
-- Old rule: shipped waves still consume planned qty.
-- New rule: shipped waves consume actual picked_qty, with qty fallback only for legacy NULL picked_qty.
WITH fixture(gr_qty, demand_qty, planned_qty, picked_qty, wave_status) AS (
  VALUES
    (12::numeric, 2::numeric, 2::numeric, 2::numeric, 'shipped'::text),
    (12::numeric, 2::numeric, 2::numeric, 2::numeric, 'shipped'::text),
    (12::numeric, 6::numeric, 6::numeric, 0::numeric, 'shipped'::text)
), calculated AS (
  SELECT
    MAX(gr_qty) - SUM(planned_qty) AS old_available,
    MAX(gr_qty) - SUM(CASE WHEN wave_status = 'shipped' THEN COALESCE(picked_qty, planned_qty) ELSE planned_qty END) AS new_available,
    SUM(GREATEST(0::numeric, demand_qty - planned_qty)) AS old_demand_left,
    SUM(GREATEST(0::numeric, demand_qty - CASE WHEN wave_status = 'shipped' THEN COALESCE(picked_qty, planned_qty) ELSE planned_qty END)) AS new_demand_left
  FROM fixture
)
SELECT
  CASE
    WHEN old_available = 2
     AND old_demand_left = 0
     AND new_available = 8
     AND new_demand_left = 6
    THEN 'PASS: shipped short-pick releases unpicked units'
    ELSE 'FAIL: expected old available/demand_left = 2/0 and new = 8/6'
  END AS result,
  old_available,
  old_demand_left,
  new_available,
  new_demand_left
FROM calculated;
