-- ============================================================
-- Swap device_details views
-- 1. device_details     → device_details_old
-- 2. device_details_v2  → device_details
-- ============================================================

-- Step 1: Rename current prod view to _old
EXEC sp_rename 'trk.device_details', 'device_details_old';

-- Step 2: Rename optimized view to prod name
EXEC sp_rename 'trk.device_details_v2', 'device_details';

-- Verify
SELECT name, create_date, modify_date
FROM sys.views
WHERE name IN ('device_details', 'device_details_old')
ORDER BY name;
