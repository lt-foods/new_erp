-- Fix: missing RLS on internal_barcode_sequence (counter table, service_role only)
ALTER TABLE public.internal_barcode_sequence ENABLE ROW LEVEL SECURITY;
