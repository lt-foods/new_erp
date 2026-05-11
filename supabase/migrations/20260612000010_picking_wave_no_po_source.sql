-- ============================================================
-- picking_waves 支援「無 PO 來源」(從補貨申請建 wave)
--
-- 1. picking_waves.source_po_id 已是 nullable(無需動)
-- 2. 加 source_restock_request_id BIGINT NULL,FK → restock_requests
-- 3. CHECK: 兩個來源至多一個非 NULL(不允許同時 PO + restock 來源)
-- 4. Index for lookups
-- ============================================================

ALTER TABLE public.picking_waves
  ADD COLUMN IF NOT EXISTS source_restock_request_id BIGINT
    REFERENCES public.restock_requests(id);

CREATE INDEX IF NOT EXISTS idx_picking_waves_restock
  ON public.picking_waves (source_restock_request_id)
  WHERE source_restock_request_id IS NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'picking_waves_one_source_chk'
       AND conrelid = 'public.picking_waves'::regclass
  ) THEN
    ALTER TABLE public.picking_waves
      ADD CONSTRAINT picking_waves_one_source_chk
        CHECK (NOT (source_po_id IS NOT NULL AND source_restock_request_id IS NOT NULL));
  END IF;
END $$;

COMMENT ON COLUMN public.picking_waves.source_restock_request_id IS
  '若 wave 從補貨申請建立,指向 restock_requests.id;與 source_po_id 互斥。';
