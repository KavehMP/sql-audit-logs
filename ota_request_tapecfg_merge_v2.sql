-- ============================================================
-- Step 1: Check existing indexes on ota_req
-- ============================================================
SELECT
    i.name          AS index_name,
    i.type_desc,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('trk.ota_req')
GROUP BY i.name, i.type_desc
ORDER BY i.name;

-- ============================================================
-- Step 2: Create index on otaid if it doesn't exist
-- (requires admin login)
-- ============================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('trk.ota_req')
    AND name = 'IX_ota_req_otaid'
)
BEGIN
    PRINT 'Creating IX_ota_req_otaid...';
    CREATE INDEX IX_ota_req_otaid
        ON trk.ota_req (otaid)
        INCLUDE (device_id, requested_version, time_intiated, time_completed, status,
                 [user], status_reason, status_update_time, otaMode, otaForce, otaType,
                 repo_env, size, hash, fileLocation, maintainenceStart, maintainenceEnd,
                 global_ota_req_status, mdm_backend_status, device_status, test_device);
    PRINT 'IX_ota_req_otaid created.';
END
ELSE
    PRINT 'IX_ota_req_otaid already exists, skipping.';

-- ============================================================
-- Step 3: Check COUNT(*) difference between FULL JOIN vs LEFT JOIN
-- Run this before creating v2 to decide if the join change is safe
-- ============================================================

-- Rows only in FULL JOIN (tapecfg_db devices with no OTA requests)
-- If this is 0 or negligible, LEFT JOIN is safe
SELECT
    'tapecfg_db rows with no ota_req match' AS description,
    COUNT(*) AS row_count
FROM trk.tapecfg_db td
WHERE NOT EXISTS (SELECT 1 FROM trk.ota_req or2 WHERE or2.device_id = td.tape_id);

SELECT
    'ota_req rows with no tapecfg_db match' AS description,
    COUNT(*) AS row_count
FROM trk.ota_req or2
WHERE NOT EXISTS (SELECT 1 FROM trk.tapecfg_db td WHERE td.tape_id = or2.device_id);

-- ============================================================
-- Step 4: Create ota_request_tapecfg_merge_v2
-- ============================================================
IF OBJECT_ID('trk.ota_request_tapecfg_merge_v2', 'V') IS NOT NULL
BEGIN
    PRINT 'View trk.ota_request_tapecfg_merge_v2 already exists, dropping first...';
    DROP VIEW trk.ota_request_tapecfg_merge_v2;
END

PRINT 'Creating trk.ota_request_tapecfg_merge_v2...';
GO

CREATE VIEW [trk].[ota_request_tapecfg_merge_v2] AS
SELECT
    td.tape_personality,
    td.fw_version,
    td.ext_fw_version,
    td.ext_hw_version,
    td.hw_version,
    td.os_version,
    td.mcu_version,
    td.lastupdate,
    hb.system_info_system_uptime,
    or2.*
FROM trk.ota_req or2
LEFT JOIN trk.tapecfg_db td ON td.tape_id = or2.device_id
LEFT JOIN trk.heartbeats_v4_preserved hb ON hb.macid = td.tape_id;
GO

PRINT 'trk.ota_request_tapecfg_merge_v2 created successfully.';

-- ============================================================
-- Step 5: Side-by-side comparison
-- ============================================================

-- 5a. Performance (check Messages tab)
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT COUNT(*) AS v1_count FROM trk.ota_request_tapecfg_merge;
-- SELECT COUNT(*) AS v2_count FROM trk.ota_request_tapecfg_merge_v2;
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- 5b. Test with a real otaid from the app (replace the guid below)
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT * FROM trk.ota_request_tapecfg_merge   WHERE otaid = '16d4fc13-62c2-4b60-97af-eb1758739e00';
-- SELECT * FROM trk.ota_request_tapecfg_merge_v2 WHERE otaid = '16d4fc13-62c2-4b60-97af-eb1758739e00';
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- ============================================================
-- Step 6: Drop duplicate view (requires admin login)
-- ============================================================
-- DROP VIEW trk.ota_request_tapecfg_merge2;

-- ============================================================
-- Step 7: Swap (requires admin login)
-- ============================================================
-- EXEC sp_rename 'trk.ota_request_tapecfg_merge',    'ota_request_tapecfg_merge_old';
-- EXEC sp_rename 'trk.ota_request_tapecfg_merge_v2', 'ota_request_tapecfg_merge';

-- Verify
-- SELECT name, create_date, modify_date
-- FROM sys.views
-- WHERE name IN ('ota_request_tapecfg_merge', 'ota_request_tapecfg_merge_old', 'ota_request_tapecfg_merge2')
-- ORDER BY name;
