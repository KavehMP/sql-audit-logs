-- ============================================================
-- Step 1: Check existing indexes on tapecfg_db
-- ============================================================
SELECT
    i.name          AS index_name,
    i.type_desc,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS key_columns
FROM sys.indexes i
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('trk.tapecfg_db')
GROUP BY i.name, i.type_desc
ORDER BY i.name;

-- ============================================================
-- Step 2: Create filtered index if it doesn't exist
-- ============================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('trk.tapecfg_db')
    AND name = 'IX_tapecfg_pkgcar'
)
BEGIN
    PRINT 'Creating IX_tapecfg_pkgcar...';
    CREATE INDEX IX_tapecfg_pkgcar
        ON trk.tapecfg_db (tape_personality, facility)
        INCLUDE (fw_version, os_version, k_version, mcu_version, hw_version, tape_id)
        WHERE tape_personality = 'PkgCar';
    PRINT 'IX_tapecfg_pkgcar created.';
END
ELSE
    PRINT 'IX_tapecfg_pkgcar already exists, skipping.';

-- ============================================================
-- Step 3: Create device_summary_v2
-- ============================================================
IF OBJECT_ID('trk.device_summary_v2', 'V') IS NOT NULL
BEGIN
    PRINT 'View trk.device_summary_v2 already exists, dropping first...';
    DROP VIEW trk.device_summary_v2;
END

PRINT 'Creating trk.device_summary_v2...';
GO

CREATE VIEW [trk].[device_summary_v2] AS
WITH base AS (
    SELECT
        td.facility,
        td.fw_version,
        td.os_version,
        td.k_version,
        td.mcu_version,
        td.hw_version,
        JSON_VALUE(hb.rfid_reader_metrics, '$.rfidReaderChipVer') AS rfid_reader_chip_ver,
        JSON_VALUE(hb.rfid_reader_metrics, '$.rfidReaderFwVer')   AS rfid_reader_fw_ver
    FROM trk.tapecfg_db td
    LEFT JOIN trk.heartbeats_v4_preserved hb ON td.tape_id = hb.macid
    WHERE td.facility IS NOT NULL
      AND td.facility != 'undefined'
      AND td.facility != ''
      AND td.tape_personality = 'PkgCar'
)
SELECT
    facility,
    fw_version,
    os_version,
    k_version,
    mcu_version,
    hw_version,
    rfid_reader_chip_ver,
    rfid_reader_fw_ver,
    COUNT(*) AS count
FROM base
GROUP BY
    facility, fw_version, os_version, k_version,
    mcu_version, hw_version, rfid_reader_chip_ver, rfid_reader_fw_ver;
GO

PRINT 'trk.device_summary_v2 created successfully.';

-- ============================================================
-- Step 4: Side-by-side comparison
-- ============================================================

-- 4a. Performance (check Messages tab)
-- SET STATISTICS TIME ON;
-- SET STATISTICS IO ON;
-- SELECT COUNT(*) AS v1_count FROM trk.device_summary;
-- SELECT COUNT(*) AS v2_count FROM trk.device_summary_v2;
-- SET STATISTICS TIME OFF;
-- SET STATISTICS IO OFF;

-- 4b. Data correctness — both should return 0 rows
-- SELECT * FROM trk.device_summary   EXCEPT SELECT * FROM trk.device_summary_v2;
-- SELECT * FROM trk.device_summary_v2 EXCEPT SELECT * FROM trk.device_summary;

-- ============================================================
-- Step 5: Swap (run with admin login)
-- ============================================================
-- EXEC sp_rename 'trk.device_summary',    'device_summary_old';
-- EXEC sp_rename 'trk.device_summary_v2', 'device_summary';

-- Verify
-- SELECT name, create_date, modify_date
-- FROM sys.views
-- WHERE name IN ('device_summary', 'device_summary_old')
-- ORDER BY name;
