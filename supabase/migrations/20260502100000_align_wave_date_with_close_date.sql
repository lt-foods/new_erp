-- 一次性對齊：把 wave 12 (WV260425184716) 的 wave_date 從 2026-04-30
-- 改成 2026-04-28，跟對應的 PR2604250007.source_close_date 一致，
-- 讓 v_pr_progress 的 join (pw.wave_date = pr.source_close_date) 對應到，
-- timeline step 8「派貨」才會反映打勾。
--
-- TODO（後續）：picking_waves 應加獨立 close_date 欄位，與 wave_date
-- (配送/作業日) 解耦，避免將來再出現 wave_date 跟結單日不同步的問題。

UPDATE picking_waves
   SET wave_date = '2026-04-28'
 WHERE wave_code = 'WV260425184716'
   AND wave_date = '2026-04-30';
