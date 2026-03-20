# sql-audit-logs

A containerized SQL Server 2022 environment for downloading, importing, and querying SQL Server Extended Events (XEL) audit logs from Azure Blob Storage.

---

## How It Works

1. Run `download-audit-logs.sh <date>` — downloads XEL files from Azure Blob, starts Docker + SQL Server, and imports everything into `AuditDB.dbo.AuditLogs`
2. Connect to the local SQL Server and query `AuditLogs` with standard T-SQL
3. The project root is mounted at `/var/opt/audit-logs` inside the container — XEL files are accessible directly without copying

---

## Project Structure

```
sql-audit-logs/
├── docker-compose.yml          # SQL Server 2022 container config
├── download-audit-logs.sh      # Main script: download + import pipeline
├── .env                        # Azure Blob SAS credentials (gitignored)
├── mssql-data/                 # Persistent SQL Server data (gitignored)
└── YYYY-MM-DD-audit-log/       # Downloaded XEL files per date (gitignored)
```

---

## Prerequisites

- Docker Desktop (Apple Silicon: Rosetta/amd64 emulation required)
- A SQL Server client: Azure Data Studio, SSMS, or `sqlcmd`
- `.env` file with Azure Blob credentials (see below)

---

## .env Setup

Create a `.env` file in the project root:

```
BLOB-SAS-URL=https://<account>.blob.core.windows.net/<container>?<sas>
BLOB-SAS-TOKEN=<sas-token>
BLOB-CONTAINER-FOLDER-POINTER=https://<account>.blob.core.windows.net/<container>/<path>/YYYY-MM-DD/
```

> The SAS token must have **Read** and **List** permissions on the container.

---

## Usage

### Download and import audit logs for a date

```bash
./download-audit-logs.sh 2026-03-20
```

The script will:
1. Start Docker Desktop if not running
2. Start the SQL Server container if not running
3. Wait for SQL Server to accept connections
4. Download all XEL files for the date from Azure Blob into `2026-03-20-audit-log/`
5. Create `AuditDB` database if it doesn't exist
6. Create `AuditLogs` table if it doesn't exist (with indexes)
7. Import the XEL data — skips if data for that date already exists

### Connect to SQL Server

| Setting | Value |
|---------|-------|
| Host | `localhost,1433` |
| Username | `sa` |
| Password | `YourStrong@Passw0rd123` |
| Database | `AuditDB` |

### Query imported logs

```sql
-- All events for a date
SELECT *
FROM AuditDB.dbo.AuditLogs
WHERE CAST(event_time AS DATE) = '2026-03-20'
ORDER BY event_time;

-- Top slowest queries
SELECT TOP 100 event_time, duration_milliseconds, client_ip, LEFT(statement, 200)
FROM AuditDB.dbo.AuditLogs
ORDER BY duration_milliseconds DESC;

-- Concurrent query pile-up check at a point in time
SELECT COUNT(*) AS concurrent
FROM AuditDB.dbo.AuditLogs
WHERE statement LIKE '%device_details%'
  AND event_time <= '2026-03-20 09:00:00'
  AND DATEADD(MILLISECOND, duration_milliseconds, event_time) >= '2026-03-20 09:00:00';
```

### Query raw XEL files directly (without importing)

```sql
SELECT *
FROM sys.fn_get_audit_file(
    '/var/opt/audit-logs/2026-03-20-audit-log/*.xel',
    DEFAULT, DEFAULT
);
```

### Stop the container

```bash
docker compose down
```

Data in `mssql-data/` and `AuditDB` persist across restarts.

---

## AuditLogs Table

Created automatically on first import via `SELECT INTO` from `sys.fn_get_audit_file`. Key columns:

| Column | Description |
|--------|-------------|
| `event_time` | When the event occurred |
| `action_id` | Action type (`SL` = SELECT, `IN` = INSERT, etc.) |
| `server_principal_name` | Login that ran the query |
| `database_name` | Database affected |
| `object_name` | Table/object affected |
| `statement` | Full SQL statement |
| `duration_milliseconds` | Query duration |
| `client_ip` | Client IP address |
| `succeeded` | Whether the action succeeded (0 = failed/aborted) |

Indexes created on `event_time` and `server_principal_name`.

---

## Production View Optimizations

Audit log analysis (2026-03-20) revealed severe query pile-ups on prod — up to **20 concurrent identical queries**, peaking at **2-hour duration** during 8–9am. Root cause: `trk.device_details` polled repeatedly by service at `20.1.208.85` without canceling in-flight requests.

### Optimization Approach

For each view:
1. Replace CTE + `ROW_NUMBER()` patterns with `OUTER APPLY TOP 1` — enables index seeks instead of full table scans
2. Inline scalar UDFs as `CASE` expressions — removes row-by-row execution and unlocks query parallelism
3. Add covering indexes to support the `OUTER APPLY` seeks

### Indexes Added to Production

| Index | Table | Columns | Purpose |
|-------|-------|---------|---------|
| `IX_ota_req_device_time` | `trk.ota_req` | `(device_id, time_intiated DESC)` | Latest OTA per device |
| `IX_ota_req_device_status_time` | `trk.ota_req` | `(device_id, status, time_intiated DESC)` | Latest successful OTA per device |
| `IX_ota_req_otaid` | `trk.ota_req` | `(otaid)` + all columns INCLUDE | OTA lookup by batch ID |
| `IX_tapecfg_pkgcar` | `trk.tapecfg_db` | `(tape_personality, facility)` filtered to `PkgCar` | Device summary filter |

---

### Views Optimized

#### `trk.device_details` — 2026-03-20
**Problem:** Two CTEs scanning 1.7M rows in `trk.ota_req` with `ROW_NUMBER()` (no index on `device_id`). Scalar UDF `trk.ufn_GetOnlineStatus` called per-row blocking parallelism. Polling service firing without canceling prior requests — 20 concurrent copies stacking up.

**Changes:**
- Replaced both CTEs with `OUTER APPLY TOP 1` against `trk.ota_req`
- Inlined `ufn_GetOnlineStatus` as a `CASE` expression
- Created `IX_ota_req_device_time` and `IX_ota_req_device_status_time`

**Result:** `ota_req` logical reads **40,381 → ~0**. Query parallelized. Duration **3–7s → sub-second**.

**Rollback:** `EXEC sp_rename 'trk.device_details', 'device_details_v2'; EXEC sp_rename 'trk.device_details_old', 'device_details';`

---

#### `trk.device_summary` — 2026-03-20
**Problem:** `JSON_VALUE` evaluated twice per row (SELECT + GROUP BY). `LIKE 'PkgCar'` without wildcards bypasses index optimizations.

**Changes:**
- Wrapped in CTE to compute `JSON_VALUE` once before grouping
- Changed `LIKE 'PkgCar'` → `= 'PkgCar'`
- Created filtered index `IX_tapecfg_pkgcar`

**Note:** `heartbeats_v4_preserved` join (106K reads) investigated — persisted computed columns ruled out due to ~333 writes/second (100K devices heartbeating every 5 min).

**Result:** Moderate improvement. View was not causing pile-ups (12 calls/day, avg 5s).

**Rollback:** `EXEC sp_rename 'trk.device_summary', 'device_summary_v2'; EXEC sp_rename 'trk.device_summary_old', 'device_summary';`

---

#### `trk.ota_request_tapecfg_merge` — 2026-03-20
**Problem:** `FULL JOIN` with 1.7M row `ota_req` table, no index on `otaid`. Every query filtered by `otaid` but scanned the full table. Duplicate view `ota_request_tapecfg_merge2` (identical definition, zero usage).

**Changes:**
- Created `IX_ota_req_otaid` with all columns as INCLUDE
- Changed `FULL JOIN` → `LEFT JOIN` from `ota_req` (safe: all 252 audit log queries filter by `otaid`)
- Dropped `trk.ota_request_tapecfg_merge2`

**Result:** With app pagination (FETCH NEXT 100): heartbeats reads **54,178 → 412**, elapsed **~0ms**.

**Rollback:** `EXEC sp_rename 'trk.ota_request_tapecfg_merge', 'ota_request_tapecfg_merge_v2'; EXEC sp_rename 'trk.ota_request_tapecfg_merge_old', 'ota_request_tapecfg_merge';`

---

#### `trk.selected_devices_final_json` — 2026-03-20
**Problem:** Same as `device_details` — two `ota_req` CTEs + scalar UDF. Additional `selected_devices` CTE using `OPENJSON` to parse per-operator device JSON arrays.

**Changes:**
- Replaced both OTA CTEs with `OUTER APPLY TOP 1` (reuses existing indexes)
- Inlined `ufn_GetOnlineStatus` as `CASE` expression
- Kept `OPENJSON` CTE as-is — no alternative without schema changes

**Result:** `ota_req` logical reads **40,467 → ~0**. Query parallelized.

**Rollback:** `EXEC sp_rename 'trk.selected_devices_final_json', 'selected_devices_final_json_v2'; EXEC sp_rename 'trk.selected_devices_final_json_old', 'selected_devices_final_json';`

---

#### `trk.ota_summary` — 2026-03-20
**Status:** Reviewed, no changes needed.
- Clean aggregation over `trk.ota_req` with no JOINs or scalar UDFs
- SELECT queries (279 calls) benefit from `IX_ota_req_otaid` created above
- COUNT(*) queries filter by `test_device` — 99.99% of rows are `test_device = 0`, index would not help
- Not causing pile-ups (avg 1s, max 8s)

---

### Pending Investigation

| Item | Description |
|------|-------------|
| `cfg_filtered` ad-hoc query | Raw CTE query sent by app (not a view/SP). 74 calls, avg 26s, max 179s. Three `ROW_NUMBER()` window functions over `tapecfg_db`, no pagination. Likely a full device export — needs app-side fix. |
