-- ============================================================================
-- 2026-08-12: Restrict rpc_create_partial_pr_from_items execute grants
-- ----------------------------------------------------------------------------
-- The first partial-PR migration revoked PUBLIC and granted authenticated, but
-- production still showed an explicit anon EXECUTE grant. Keep this as a small
-- append-only hardening migration instead of editing an already-applied file.
-- ============================================================================

REVOKE ALL ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_partial_pr_from_items(BIGINT, BIGINT[], UUID) TO authenticated;
