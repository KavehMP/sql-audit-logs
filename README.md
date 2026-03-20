# sql-audit-logs

A containerized SQL Server 2022 environment for viewing and querying SQL Server Extended Events (XEL) audit logs.

## Purpose

The goal is simple: be able to open and inspect `.xel` audit log files using standard T-SQL. SQL Server can read XEL files directly — no separate import step needed. The Docker container gives you a SQL Server instance with the XEL files mounted inside it, so you can query them immediately.

## How It Works

1. Place `.xel` files in the project root
2. Start the SQL Server container — the root folder is mounted at `/var/opt/audit-logs` inside it
3. Connect to SQL Server and query the files directly using `sys.fn_xe_file_target_read_file`

## Structure

```
sql-audit-logs/
├── docker-compose.yml       # Container configuration
├── mssql-data/              # Persistent SQL Server data (mounted into container)
│   ├── data/                # Database files (.mdf, .ldf)
│   ├── log/                 # SQL Server error logs, .xel, .trc files
│   └── secrets/             # Machine-level security keys
└── *.xel                    # Extended Events audit log files (~160MB total)
```

## Prerequisites

- Docker with Rosetta/amd64 emulation support (required for `linux/amd64` image on Apple Silicon)
- A SQL Server client: Azure Data Studio, SSMS, or `sqlcmd`

## Usage

### Start the container

```bash
docker compose up -d
```

### Connect

- **Host**: `localhost,1433`
- **Username**: `sa`
- **Password**: `YourStrong@Passw0rd123`

### Query the audit logs

These XEL files are SQL Server **Database Audit** logs (created via `CREATE SERVER AUDIT`), so they must be read with `fn_get_audit_file` — not `fn_xe_file_target_read_file`.

```sql
SELECT *
FROM sys.fn_get_audit_file(
    '/var/opt/audit-logs/2026-03-20-audit-log/*.xel',
    DEFAULT, DEFAULT
);
```

This returns structured columns directly — no XML parsing needed. Key columns:

| Column | Description |
|--------|-------------|
| `event_time` | When the event occurred |
| `action_id` | Type of action (e.g. `SL` = SELECT, `IN` = INSERT) |
| `server_principal_name` | Login that performed the action |
| `database_name` | Database affected |
| `object_name` | Table/object affected |
| `statement` | The SQL statement executed |
| `succeeded` | Whether the action succeeded |

To filter by date range or action:

```sql
SELECT event_time, action_id, server_principal_name, database_name, object_name, statement
FROM sys.fn_get_audit_file(
    '/var/opt/audit-logs/2026-03-20-audit-log/*.xel',
    DEFAULT, DEFAULT
)
WHERE event_time >= '2026-03-20 00:00:00'
  AND succeeded = 1
ORDER BY event_time;
```

### Stop the container

```bash
docker compose down
```

Data in `mssql-data/` persists across restarts.

## XEL Files

Naming convention: `HH_MM_SS_mmm_sequence.xel` (time the session segment was created).

| File | Size |
|------|------|
| 07_41_44_602_980.xel | ~50MB |
| 07_46_12_148_981.xel | ~50MB |
| 07_50_48_602_982.xel | ~50MB |
| 08_25_08_904_983.xel | ~10MB |

## Notes

- SQL Server runs as **Developer Edition** (free, full-featured, not for production)
- Platform is pinned to `linux/amd64` for SQL Server compatibility (required on Apple Silicon)
- The container restarts automatically (`unless-stopped`)

---

## Production View Optimizations

Audit log analysis revealed severe query pile-ups on prod (up to 20 concurrent identical queries, 3–7 second avg duration, peaking at 2 hours during 8–9am). Root cause: `trk.device_details` was being called repeatedly by a polling service at `20.1.208.85` without canceling in-flight requests.

### Optimization approach

For each view:
1. Replace CTE + `ROW_NUMBER()` patterns with `OUTER APPLY TOP 1` — enables index seeks instead of full table scans
2. Inline scalar UDFs as `CASE` expressions — removes row-by-row execution and unlocks query parallelism
3. Add covering indexes to support the `OUTER APPLY` seeks

### Scripts

| Script | Purpose |
|--------|---------|
| `device_details_v2.sql` | Creates indexes + optimized view for side-by-side comparison |
| `swap_device_details_view.sql` | Renames views to deploy (v2 → prod, prod → _old) |

### Completed

#### `trk.device_details` — 2026-03-20
**Problem:** Two CTEs both doing `ROW_NUMBER()` over 1.7M rows in `trk.ota_req` (no index on `device_id`). Scalar UDF `trk.ufn_GetOnlineStatus` called per-row blocking parallelism.

**Changes:**
- Replaced both CTEs with `OUTER APPLY TOP 1` against `trk.ota_req`
- Inlined `ufn_GetOnlineStatus` as a `CASE` expression
- Created two covering indexes on `trk.ota_req`:
  - `IX_ota_req_device_time` on `(device_id, time_intiated DESC)`
  - `IX_ota_req_device_status_time` on `(device_id, status, time_intiated DESC)`

**Result:** `ota_req` logical reads dropped from **40,381 → ~0**. Query now runs in parallel. Duration went from 3–7s (degrading to hours under load) to sub-second.

**Rollback:** `EXEC sp_rename 'trk.device_details', 'device_details_v2'; EXEC sp_rename 'trk.device_details_old', 'device_details';`

---

#### `trk.device_summary` — 2026-03-20
**Problem:** `JSON_VALUE` evaluated twice per row (once in `SELECT`, once in `GROUP BY`). `LIKE 'PkgCar'` without wildcards bypasses index seek optimizations.

**Changes:**
- Wrapped query in a CTE so `JSON_VALUE` is computed once per row before grouping
- Changed `LIKE 'PkgCar'` → `= 'PkgCar'`
- Created filtered index `IX_tapecfg_pkgcar` on `trk.tapecfg_db (tape_personality, facility)` with INCLUDE columns, filtered to `WHERE tape_personality = 'PkgCar'`

**Note:** `heartbeats_v4_preserved` join reads 106K logical reads (full scan). Investigated adding persisted computed columns for JSON values but ruled out — table receives ~333 writes/second (100K devices × every 5 min), write overhead outweighs read benefit.

**Result:** Moderate improvement. View was not causing pile-ups (12 calls/day, avg 5s, max 12s).

**Rollback:** `EXEC sp_rename 'trk.device_summary', 'device_summary_v2'; EXEC sp_rename 'trk.device_summary_old', 'device_summary';`

---

#### `trk.ota_request_tapecfg_merge` — 2026-03-20
**Problem:** `FULL JOIN` between `tapecfg_db` and `ota_req` (1.7M rows) with no index on `otaid`. Every query filtered by `otaid` but had to scan the full table. Duplicate view `ota_request_tapecfg_merge2` existed with identical definition and zero usage.

**Changes:**
- Created index `IX_ota_req_otaid` on `trk.ota_req (otaid)` with all columns as INCLUDE
- Changed `FULL JOIN` → `LEFT JOIN` starting from `ota_req` (safe: all 252 queries in audit logs filter by `otaid`; 11,002 tapecfg_db-only rows were always filtered out anyway)
- Dropped duplicate view `trk.ota_request_tapecfg_merge2` (zero calls in audit logs, created 2025-03-21)

**Result:** With pagination (FETCH NEXT 100 as used by app): heartbeats reads **54,178 → 412**, tapecfg_db reads **10,467 → 601**, elapsed ~0ms. Index seek on `otaid` makes the 1.7M row scan irrelevant.

**Rollback:** `EXEC sp_rename 'trk.ota_request_tapecfg_merge', 'ota_request_tapecfg_merge_v2'; EXEC sp_rename 'trk.ota_request_tapecfg_merge_old', 'ota_request_tapecfg_merge';`

---

#### `trk.selected_devices_final_json` — 2026-03-20
**Problem:** Identical issues to `device_details` — two CTEs scanning all 1.7M rows of `trk.ota_req` with `ROW_NUMBER()`, scalar UDF `trk.ufn_GetOnlineStatus` blocking parallelism. Additional `selected_devices` CTE using `OPENJSON` to parse per-operator device lists.

**Changes:**
- Replaced both `ota_device` and `ota_device_success_history` CTEs with `OUTER APPLY TOP 1` (reuses `IX_ota_req_device_time` and `IX_ota_req_device_status_time` created for `device_details`)
- Inlined `ufn_GetOnlineStatus` as a `CASE` expression (enables parallelism)
- Kept `selected_devices` CTE with `OPENJSON` as-is — no structural alternative without schema changes

**Result:** `ota_req` logical reads **40,467 → ~0**. Query now runs in parallel. `selected_devices` OPENJSON is now the remaining bottleneck but unavoidable without schema changes.

**Rollback:** `EXEC sp_rename 'trk.selected_devices_final_json', 'selected_devices_final_json_v2'; EXEC sp_rename 'trk.selected_devices_final_json_old', 'selected_devices_final_json';`

---

### Pending (1 remaining)

| View | Status |
|------|--------|
| `cfg_filtered` ad-hoc query | Pending investigation |
