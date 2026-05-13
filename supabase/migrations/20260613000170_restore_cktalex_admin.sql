-- ============================================================
-- One-time fix: dev session 中誤把 cktalex demote 成 store_staff
-- 改回 'admin' (原本身份)
-- 因為已加 self-demote 防線，未來不會再發生
-- ============================================================
UPDATE auth.users
   SET raw_app_meta_data = COALESCE(raw_app_meta_data, '{}'::jsonb)
       || jsonb_build_object('role', 'admin')
 WHERE email = 'cktalex@gmail.com'
   AND COALESCE(raw_app_meta_data ->> 'role', '') = 'store_staff';
