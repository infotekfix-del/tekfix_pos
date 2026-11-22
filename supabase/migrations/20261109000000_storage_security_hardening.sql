-- ============================================================================
-- TEKFIX ERP - PHASE 13.3.0: SUPABASE STORAGE SECURITY HARDENING
-- TARGET: Staging Supabase Database
-- AUTHORIZATION: Private Financial Records Bucket with Engine-Level Enforcement
-- ============================================================================

-- 1. Create financial-records bucket with mandatory database-level constraints
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'financial-records',
  'financial-records',
  false,               -- STRICTLY PRIVATE BUCKET: No public GET / read URLs
  10485760,            -- 10 MB strict limit in bytes (10 * 1024 * 1024)
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

-- 2. Revoke all public access via Row-Level Security (RLS) on storage.objects
DROP POLICY IF EXISTS "Public Access Denied" ON storage.objects;
CREATE POLICY "Public Access Denied" ON storage.objects
  FOR ALL TO public USING (false);

-- 3. Service-role only policy for objects in financial-records
-- (Edge Functions interact using service_role key; clients interact via signed URLs)
DROP POLICY IF EXISTS "Service Role Full Access" ON storage.objects;
CREATE POLICY "Service Role Full Access" ON storage.objects
  FOR ALL TO service_role
  USING (bucket_id = 'financial-records')
  WITH CHECK (bucket_id = 'financial-records');

