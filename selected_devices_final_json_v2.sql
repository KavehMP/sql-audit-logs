-- ============================================================
-- Step 1: Verify indexes on ota_req are in place
-- (created during device_details optimization)
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

-- Expected: IX_ota_req_device_time and IX_ota_req_device_status_time should already exist

-- ============================================================
-- Step 2: Create selected_devices_final_json_v2
-- Changes vs original:
--   1. Replace ota_device CTE      → OUTER APPLY TOP 1 (uses IX_ota_req_device_time)
--   2. Replace ota_device_success  → OUTER APPLY TOP 1 (uses IX_ota_req_device_status_time)
--   3. Inline ufn_GetOnlineStatus  → CASE expression (enables parallelism)
--   4. selected_devices CTE kept as-is (OPENJSON pattern, no structural alternative)
-- ============================================================
IF OBJECT_ID('trk.selected_devices_final_json_v2', 'V') IS NOT NULL
BEGIN
    PRINT 'View trk.selected_devices_final_json_v2 already exists, dropping first...';
    DROP VIEW trk.selected_devices_final_json_v2;
END

PRINT 'Creating trk.selected_devices_final_json_v2...';
GO

CREATE VIEW [trk].[selected_devices_final_json_v2] AS
WITH selected_devices AS (
    SELECT d.operator, ua.[value]
    FROM trk.selected_devices d
    CROSS APPLY OPENJSON(d.selected_json) ua
    INNER JOIN trk.tapecfg_db a ON a.tape_id = ua.[value]
    WHERE d.ota_id IS NULL
      AND d.selected_json IS NOT NULL
      AND d.selected_json != '[]'
)
SELECT
    or4.operator,
    t.id,
    t.facility,
    t.AssetBarCode      AS package_car_id,
    t.tape_id,
    t.fw_version,
    t.mcu_version,
    t.k_version,
    t.os_version,
    t.qrcode,
    t.lastupdate,
    t.activation_date,
    t.hw_version,
    f.uld_type          AS car_type,
    or2.time_intiated   AS last_ota_update,
    or2.status          AS last_reported_status,
    or2.otaType         AS ota_type,
    or2.requested_version AS ota_version,
    CASE
        WHEN t.lastupdate IS NULL OR ISNUMERIC(t.lastupdate) = 0                                   THEN 'OFFLINE'
        WHEN CAST(t.lastupdate AS INT) <= 1000000000                                               THEN 'OFFLINE'
        WHEN CAST(t.lastupdate AS INT) > DATEDIFF(SECOND, '1970-01-01', GETUTCDATE()) - 7200       THEN 'ONLINE'
        WHEN CAST(t.lastupdate AS INT) > DATEDIFF(SECOND, '1970-01-01', GETUTCDATE()) - 43200      THEN 'YELLOW'
        ELSE 'OFFLINE'
    END                 AS online_status,
    or3.otaid           AS has_had_successful_ota,
    or2.otaid           AS last_ota_id,
    or2.global_ota_req_status,
    t.lastupdate        AS last_heartbeat
FROM trk.tapecfg_db t
JOIN trk.facility f
    ON t.AssetBarCode = f.id
JOIN selected_devices or4
    ON or4.value = t.tape_id
OUTER APPLY (
    SELECT TOP 1 otaid, time_intiated, status, otaType, requested_version, global_ota_req_status
    FROM trk.ota_req
    WHERE device_id = t.tape_id
    ORDER BY time_intiated DESC
) or2
OUTER APPLY (
    SELECT TOP 1 otaid
    FROM trk.ota_req
    WHERE device_id = t.tape_id
      AND status = 'successful'
    ORDER BY time_intiated DESC
) or3
WHERE
    t.qrcode   IS NOT NULL AND t.qrcode   != 'undefined'
AND t.tape_id  IS NOT NULL AND t.tape_id  != 'undefined'
AND t.facility IS NOT NULL AND t.facility != 'undefined';
GO

PRINT 'trk.selected_devices_final_json_v2 created successfully.';

-- ============================================================
-- Step 3: Side-by-side comparison
-- ============================================================

-- 3a. Performance (check Messages tab)
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT COUNT(*) AS v1_count FROM trk.selected_devices_final_json;
-- SELECT COUNT(*) AS v2_count FROM trk.selected_devices_final_json_v2;
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- 3b. Test with a real operator value from the audit logs
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT * FROM trk.selected_devices_final_json    WHERE operator = 'anshul@trackonomysystems.com' ORDER BY id OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY;
-- SELECT * FROM trk.selected_devices_final_json_v2 WHERE operator = 'anshul@trackonomysystems.com' ORDER BY id OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY;
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- 3c. Data correctness — both should return 0 rows
-- SELECT * FROM trk.selected_devices_final_json   EXCEPT SELECT * FROM trk.selected_devices_final_json_v2;
-- SELECT * FROM trk.selected_devices_final_json_v2 EXCEPT SELECT * FROM trk.selected_devices_final_json;

-- ============================================================
-- Step 4: Swap (requires admin login)
-- ============================================================
-- EXEC sp_rename 'trk.selected_devices_final_json',    'selected_devices_final_json_old';
-- EXEC sp_rename 'trk.selected_devices_final_json_v2', 'selected_devices_final_json';

-- Verify
-- SELECT name, create_date, modify_date
-- FROM sys.views
-- WHERE name IN ('selected_devices_final_json', 'selected_devices_final_json_old')
-- ORDER BY name;
