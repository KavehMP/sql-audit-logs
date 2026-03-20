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
-- Step 2: Create indexes if they don't already exist
-- ============================================================
SELECT 
    SUSER_NAME()    AS login,
    USER_NAME()     AS db_user,
    IS_MEMBER('db_ddladmin') AS is_ddladmin,
    IS_MEMBER('db_owner')    AS is_db_owner;


SELECT DB_NAME() AS current_db;

SELECT TABLE_SCHEMA, TABLE_NAME 
FROM INFORMATION_SCHEMA.TABLES 
WHERE TABLE_NAME = 'ota_req';

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('trk.ota_req')
    AND name = 'IX_ota_req_device_time'
)
BEGIN
    PRINT 'Creating IX_ota_req_device_time...';
    CREATE INDEX IX_ota_req_device_time
        ON trk.ota_req (device_id, time_intiated DESC)
        INCLUDE (otaid, status, otaType, requested_version, global_ota_req_status);
    PRINT 'IX_ota_req_device_time created.';
END
ELSE
    PRINT 'IX_ota_req_device_time already exists, skipping.';

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('trk.ota_req')
    AND name = 'IX_ota_req_device_status_time'
)
BEGIN
    PRINT 'Creating IX_ota_req_device_status_time...';
    CREATE INDEX IX_ota_req_device_status_time
        ON trk.ota_req (device_id, status, time_intiated DESC)
        INCLUDE (otaid);
    PRINT 'IX_ota_req_device_status_time created.';
END
ELSE
    PRINT 'IX_ota_req_device_status_time already exists, skipping.';

-- ============================================================
-- Step 3: Create device_details_v2 if it doesn't exist
-- ============================================================

IF OBJECT_ID('trk.device_details_v2', 'V') IS NOT NULL
BEGIN
    PRINT 'View trk.device_details_v2 already exists, dropping first...';
    DROP VIEW trk.device_details_v2;
END

PRINT 'Creating trk.device_details_v2...';
GO

CREATE VIEW [trk].[device_details_v2] AS
SELECT
    t.id,
    t.facility,
    t.AssetBarCode          AS package_car_id,
    t.tape_id,
    t.fw_version,
    t.mcu_version,
    t.k_version,
    t.os_version,
    t.qrcode,
    t.lastupdate,
    t.activation_date,
    t.hw_version,
    f.uld_type              AS car_type,
    or2.time_intiated       AS last_ota_update,
    or2.status              AS last_reported_status,
    or2.otaType             AS ota_type,
    or2.requested_version   AS ota_version,
    CASE
        WHEN t.lastupdate IS NULL OR ISNUMERIC(t.lastupdate) = 0                                   THEN 'OFFLINE'
        WHEN CAST(t.lastupdate AS INT) <= 1000000000                                               THEN 'OFFLINE'
        WHEN CAST(t.lastupdate AS INT) > DATEDIFF(SECOND, '1970-01-01', GETUTCDATE()) - 7200       THEN 'ONLINE'
        WHEN CAST(t.lastupdate AS INT) > DATEDIFF(SECOND, '1970-01-01', GETUTCDATE()) - 43200      THEN 'YELLOW'
        ELSE 'OFFLINE'
    END                     AS online_status,
    or3.otaid               AS has_had_successful_ota,
    or2.otaid               AS last_ota_id,
    or2.global_ota_req_status,
    t.lastupdate            AS last_heartbeat,
    hb.system_info_system_uptime,
    JSON_VALUE(hb.rfid_reader_metrics, '$.rfidReaderChipVer') AS rfid_reader_chip_ver,
    JSON_VALUE(hb.rfid_reader_metrics, '$.rfidReaderFwVer')   AS rfid_reader_fw_ver,
    fd.timezone
FROM trk.tapecfg_db t
JOIN trk.facility f
    ON t.AssetBarCode = f.id
LEFT JOIN trk.heartbeats_v4_preserved hb
    ON t.tape_id = hb.macid
LEFT JOIN trk.facility_details fd
    ON t.facility = fd.facility
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

PRINT 'trk.device_details_v2 created successfully.';

-- ============================================================
-- Step 4: Side-by-side comparison
-- Run these after the view is created
-- ============================================================

-- 4a. Performance comparison (check Messages tab for timing/IO)
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT COUNT(*) AS v1_count FROM trk.device_details;
-- SELECT COUNT(*) AS v2_count FROM trk.device_details_v2;
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- 4b. Data correctness — both should return 0 rows
-- SELECT * FROM trk.device_details EXCEPT SELECT * FROM trk.device_details_v2;
-- SELECT * FROM trk.device_details_v2 EXCEPT SELECT * FROM trk.device_details;
-- SELECT
--     v2.tape_id,
--     v2.online_status        AS v2_online_status,    v1.online_status        AS v1_online_status,
--     v2.last_ota_id          AS v2_last_ota_id,       v1.last_ota_id          AS v1_last_ota_id,
--     v2.last_reported_status AS v2_last_status,       v1.last_reported_status AS v1_last_status,
--     v2.has_had_successful_ota AS v2_successful,      v1.has_had_successful_ota AS v1_successful,
--     v2.last_ota_update      AS v2_ota_update,        v1.last_ota_update      AS v1_ota_update
-- FROM trk.device_details_v2 v2
-- JOIN trk.device_details v1 ON v1.tape_id = v2.tape_id
-- WHERE v2.tape_id IN (
--     '001F7B5E85EE','001F7B5E70F6','001F7B5D7502','001F7B5DBF20','001F7B5C98C2'
-- );
-- SELECT
--     v2.tape_id,
--     v2.ota_type                  AS v2_ota_type,               v1.ota_type                 AS v1_ota_type,
--     v2.ota_version               AS v2_ota_version,            v1.ota_version              AS v1_ota_version,
--     v2.global_ota_req_status     AS v2_global_ota_status,      v1.global_ota_req_status    AS v1_global_ota_status,
--     v2.system_info_system_uptime AS v2_uptime,                 v1.system_info_system_uptime AS v1_uptime,
--     v2.rfid_reader_chip_ver      AS v2_chip_ver,               v1.rfid_reader_chip_ver     AS v1_chip_ver,
--     v2.rfid_reader_fw_ver        AS v2_fw_ver,                 v1.rfid_reader_fw_ver       AS v1_fw_ver,
--     v2.timezone                  AS v2_timezone,               v1.timezone                 AS v1_timezone,
--     v2.car_type                  AS v2_car_type,               v1.car_type                 AS v1_car_type
-- FROM trk.device_details_v2 v2
-- JOIN trk.device_details v1 ON v1.tape_id = v2.tape_id
-- WHERE v2.tape_id IN (
--     '001F7B5E85EE','001F7B5E70F6','001F7B5D7502','001F7B5DBF20','001F7B5C98C2'
-- );


-- EXEC sp_rename 'trk.device_details', 'device_details_old';

-- -- Step 2: Rename optimized view to prod name
-- EXEC sp_rename 'trk.device_details_v2', 'device_details';

-- -- Verify
-- SELECT name, create_date, modify_date
-- FROM sys.views
-- WHERE name IN ('device_details', 'device_details_old')
-- ORDER BY name;