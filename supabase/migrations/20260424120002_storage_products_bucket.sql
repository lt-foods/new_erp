-- ============================================================
-- Supabase Storage: `products` bucket（商品圖片）
--
-- Path 設計: {tenant_id}/{uuid}.{ext}
-- 公開讀取、authenticated 可寫入/更新/刪除自家 tenant 路徑
-- ============================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'products', 'products', TRUE, 5242880,  -- 5 MB
  ARRAY['image/png','image/jpeg','image/webp','image/gif']
)
ON CONFLICT (id) DO UPDATE SET
  public             = EXCLUDED.public,
  file_size_limit    = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ============================================================
-- Policies（storage.objects）
-- tenant 判定：path 第一段資料夾 == JWT tenant_id claim
-- ============================================================

CREATE POLICY products_storage_insert_tenant
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'products'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  );

CREATE POLICY products_storage_update_tenant
  ON storage.objects FOR UPDATE TO authenticated
  USING (
    bucket_id = 'products'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  )
  WITH CHECK (
    bucket_id = 'products'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  );

CREATE POLICY products_storage_delete_tenant
  ON storage.objects FOR DELETE TO authenticated
  USING (
    bucket_id = 'products'
    AND (storage.foldername(name))[1] = (auth.jwt() ->> 'tenant_id')
  );

-- 公開讀取（bucket public=true 實際會自動支援，但保留 policy 清楚語意）
CREATE POLICY products_storage_select_public
  ON storage.objects FOR SELECT TO public
  USING (bucket_id = 'products');
