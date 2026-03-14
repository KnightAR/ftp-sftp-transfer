# FTP to SFTP Transfer Script

**Version:** 2.1.0
**OS:** Ubuntu Linux
**Purpose:** Mirror files from a plain FTP server to an SFTP server with a decoupled parallel download/upload pipeline, sha256 checksum verification, disk-space guarding, mtime-based FTP retention/deletion, and structured logging.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Exclusion List](#exclusion-list)
5. [Usage](#usage)
6. [How It Works](#how-it-works)
7. [Checksum Verification](#checksum-verification)
8. [Re-upload Flag (`reupload.log`)](#re-upload-flag-reuploadlog)
9. [Verify Mode (`-V`)](#verify-mode--v)
10. [Logging](#logging)
11. [Running via Cron](#running-via-cron)
12. [Security Notes](#security-notes)
13. [Troubleshooting](#troubleshooting)

---

## Requirements

The following packages must be installed on the system:

| Binary | Package | Purpose |
|--------|---------|---------|
| `lftp` | `lftp` | FTP client — recursive listing and downloading |
| `sshpass` | `sshpass` | Non-interactive SFTP password injection |
| `sftp` | `openssh-client` | SFTP client for uploads, size checks, and deletes |

The script detects missing dependencies at startup and offers to install them automatically via `apt-get` when run interactively. When run non-interactively (e.g. from cron), it prints the install command and exits.

To install manually:

```bash
sudo apt-get install -y lftp sshpass openssh-client
```

---

## Installation

```bash
# 1. Clone or copy the script files to your preferred location
mkdir -p /opt/ftp-sftp-transfer
cp transfer.sh transfer.conf.example exclude.list /opt/ftp-sftp-transfer/

# 2. Create your config file from the example
cp /opt/ftp-sftp-transfer/transfer.conf.example /opt/ftp-sftp-transfer/transfer.conf

# 3. Edit the config file with your credentials and settings
nano /opt/ftp-sftp-transfer/transfer.conf

# 4. Make the script executable
chmod +x /opt/ftp-sftp-transfer/transfer.sh

# 5. Secure the config file (contains credentials)
chmod 600 /opt/ftp-sftp-transfer/transfer.conf

# 6. Create the logs directory
mkdir -p /opt/ftp-sftp-transfer/logs
```

---

## Configuration

All settings are stored in `transfer.conf`. This file is sourced as a bash script at startup. Copy `transfer.conf.example` as a starting point.

> **Security:** Always run `chmod 600 transfer.conf` after editing. The script will warn you if the file permissions are too open.

### Full Configuration Reference

```bash
# === FTP Settings ===
FTP_HOST="ftp.example.com"          # FTP server hostname or IP
FTP_PORT="21"                       # FTP port (usually 21)
FTP_USER="ftp_user"                 # FTP username
FTP_PASS="ftp_password"             # FTP password
FTP_REMOTE_DIR="/"                  # FTP root to mirror from (recursive)

# === SFTP Settings ===
SFTP_HOST="sftp.example.com"        # SFTP server hostname or IP
SFTP_PORT="22"                      # SFTP port (usually 22)
SFTP_USER="sftp_user"               # SFTP username
SFTP_PASS="sftp_password"           # SFTP password
SFTP_REMOTE_DIR="/ihub-db-backups"  # Destination root on SFTP server

# === Transfer Settings ===
RETENTION_DAYS=7                    # Files older than N days on FTP are deleted
                                    # after confirmed upload to SFTP (uses FTP mtime)

FTP_MAX_WORKERS=2                   # Parallel FTP download workers
                                    # Keep at/below the FTP server's max connection limit
                                    # (reserve at least 1 for listings)

SFTP_MAX_WORKERS=10                 # Parallel SFTP upload workers
                                    # Independent of FTP_MAX_WORKERS — tune to saturate
                                    # SFTP bandwidth

# === Disk Space Management ===
DISK_SPACE_BUFFER_PCT=10            # Percentage of TEMP_DIR disk to keep in reserve
DISK_WAIT_TIMEOUT=300               # Max seconds to wait for disk space before skipping
DISK_WAIT_INTERVAL=10               # Seconds between disk space re-checks

# === Paths ===
TEMP_DIR=""                         # Leave empty for system temp (/tmp/ftp_sftp_XXXXX)
                                    # Or set absolute path: TEMP_DIR="/mnt/staging"
EXCLUDE_LIST="./exclude.list"       # Path to exclusion list file
LOG_DIR="./logs"                    # Directory for log files
LOG_RETENTION_DAYS=30               # Auto-delete general logs after N days
                                    # Error logs are NEVER auto-deleted

# === Behavior Flags ===
DRY_RUN="false"                     # "true" = simulate, no files moved or deleted
DELETE_FROM_FTP="true"              # "false" = transfer only, never delete from FTP
OVERWRITE_ON_SIZE_DIFF="true"       # "false" = skip size-mismatched files instead of
                                    #           overwriting them on SFTP

# === Verification ===
VERIFY_CHECKSUM="true"              # "true" = after each upload, re-download from SFTP
                                    #          and compare sha256 against staged file
                                    # Recommended on intranet/uncapped connections

VERIFY_MODE="false"                 # "true" = re-download every FTP file, verify every
                                    #          SFTP copy via checksum, then run retention
                                    #          deletions. Equivalent to the -V CLI flag.

REUPLOAD_LOG="./reupload.log"       # Persistent file for tracking checksum failures
                                    # across runs. Auto-managed — see Re-upload Flag section.
```

All variables except credentials and server addresses have safe defaults — missing optional variables will not cause the script to error out.

---

## Exclusion List

The `exclude.list` file controls which files are skipped during transfer. Patterns are matched against the **basename** of each file (not the full path). Matching uses bash glob patterns and is case-sensitive.

### Supported Pattern Formats

| Pattern | Matches | Example |
|---------|---------|---------|
| `*.tmp` | Any file ending in `.tmp` | `dump.sql.gz.tmp` |
| `*.sql` | Any file ending in `.sql` | `backup.sql` |
| `debug.log` | Exact filename | `debug.log` only |
| `backup_*` | Files starting with `backup_` | `backup_2024.tar.gz` |
| `*partial*` | Files containing `partial` | `db_partial_restore.sql` |

Lines beginning with `#` are comments. Blank lines are ignored. Inline comments are stripped.

### Example `exclude.list`

```
# Incomplete transfer files
*.tmp
*.partial
*.part

# Editor lock files
*.swp
*.lck

# Specific filenames
DONOTUPLOAD
debug.log
```

---

## Usage

```
./transfer.sh [OPTIONS]

Options:
  -c FILE   Path to config file               (default: ./transfer.conf)
  -e FILE   Path to exclusion list            (default: value in config)
  -t DIR    Override temp/staging dir         (this run only)
  -d        Enable dry-run mode               (no files moved or deleted)
  -n        Disable FTP deletion              (transfer only, no deletes)
  -f N      Override FTP download workers     (this run only)
  -s N      Override SFTP upload workers      (this run only)
  -v        Verbose output (DEBUG level)      (stdout + log)
  -V        Verify mode: re-download all FTP files, checksum-verify
            every SFTP copy, then run retention deletions
  -h        Show help message
```

### Common Examples

```bash
# Standard run using default config
./transfer.sh

# Dry run — see what would happen without making any changes
./transfer.sh -d

# Dry run with verbose debug output
./transfer.sh -d -v

# Use a config file in a different location
./transfer.sh -c /etc/transfer/transfer.conf

# Transfer only — disable all FTP deletions for this run
./transfer.sh -n

# Override worker counts for this run
./transfer.sh -f 1 -s 5

# Use a custom staging directory for this run
./transfer.sh -t /mnt/fast-disk/staging

# Re-confirm all previously uploaded files before allowing FTP deletion
./transfer.sh -V

# Re-confirm all files without deleting anything from FTP
./transfer.sh -V -n
```

---

## How It Works

### Pipeline Architecture

The script runs a three-stage decoupled pipeline where FTP downloads and SFTP uploads run concurrently:

```
Stage 1: FTP_MAX_WORKERS download workers
         - Pop files from work_queue
         - Check SFTP state (skip if already synced)
         - Download from FTP to local staging
         - Push to ready_queue

Stage 2: SFTP_MAX_WORKERS upload workers (start immediately, run concurrently with Stage 1)
         - Pop files from ready_queue
         - Upload to SFTP
         - Verify size on SFTP
         - Verify checksum (re-download + sha256 compare)
         - Push to confirmed_queue

Stage 3: FTP deletion (runs after all uploads confirmed)
         - Pop files from confirmed_queue
         - Apply mtime-based retention policy
         - Delete files older than RETENTION_DAYS from FTP
```

This design means slow SFTP uploads never block fast FTP downloads — the 2 FTP workers and 10 SFTP workers run independently.

### Transfer Decision per File

For each file found on the FTP server, the download worker applies the following logic:

```
1. Skip if filename starts with "."  (dot files)
2. Skip if filename matches exclusion list
3. Check reupload.log — if flagged, force re-download regardless of SFTP state
4. Check SFTP state:
   a. VERIFY_MODE=true              → force re-download for checksum re-verification
   b. Does not exist on SFTP        → download and upload
   c. Exists, sizes differ          → re-download and overwrite (if OVERWRITE_ON_SIZE_DIFF=true)
                                      skip with warning (if OVERWRITE_ON_SIZE_DIFF=false)
   d. Exists, sizes match           → skip (queue for retention check only)
5. Download from FTP to local staging directory
6. Verify downloaded file size matches FTP-reported size
7. Enqueue for SFTP upload
```

### FTP Directory Structure Preservation

The full FTP directory hierarchy is preserved under `SFTP_REMOTE_DIR`. For example:

```
FTP:  /db/2024/dump.sql.bz2         →  SFTP: /ihub-db-backups/db/2024/dump.sql.bz2
FTP:  /slim/dump.sql.bz2            →  SFTP: /ihub-db-backups/slim/dump.sql.bz2
FTP:  /dump.sql.bz2                 →  SFTP: /ihub-db-backups/dump.sql.bz2
```

Files with the same name in different FTP directories (e.g. `/file.bz2` and `/slim/file.bz2`) are staged to separate local paths so they never overwrite each other during concurrent downloads.

### Disk Space Guard

Before each FTP download, the script checks available disk space in `TEMP_DIR`:

```
usable = disk_available - in_flight_reserved - (total_disk * DISK_SPACE_BUFFER_PCT / 100)
```

If `usable < file_size`, the worker waits up to `DISK_WAIT_TIMEOUT` seconds. If no other downloads or uploads are active (nothing can free space), it exits immediately rather than waiting the full timeout.

### Safety Rule

> A file is **never** deleted from FTP unless its SFTP upload has been explicitly confirmed during that same run — meaning size verification AND checksum verification (if enabled) both passed. A failed transfer, size mismatch, or checksum failure will never trigger FTP deletion.

---

## Checksum Verification

When `VERIFY_CHECKSUM="true"` (the default), every successfully uploaded file goes through two verification steps:

1. **Size check** — `sftp_get_size` confirms the remote file byte count matches the expected size. Uses a retry loop (up to 4 attempts, 3 seconds apart) to handle object-storage backends that may report a partial size briefly after a write completes.

2. **Checksum check** — re-downloads the uploaded file from SFTP to a temporary `.verify` file, computes `sha256sum` of both the local staged copy and the re-downloaded copy, and compares the hashes.

If either check fails, the upload is counted as an error and the staged file is deleted. The file is **not** added to `confirmed_queue`, so FTP deletion is never triggered.

If the checksum fails, the corrupt SFTP copy is automatically deleted and the file is flagged in `reupload.log` for forced re-upload on the next run — see [Re-upload Flag](#re-upload-flag-reuploadlog).

Set `VERIFY_CHECKSUM="false"` to disable checksum verification and rely on size verification only (faster, but provides weaker integrity guarantee).

### Log output

```
# Success
[INFO]  [UL3] Upload confirmed [52428800 bytes, checksum OK]: /backup.bz2 → /ihub-db-backups/backup.bz2

# Size mismatch after upload
[ERROR] [UL3] Upload size verification failed (expected=52428800, sftp_reported=262144000): ...

# Checksum mismatch
[ERROR] [UL3] Checksum MISMATCH (staged=a1b2c3..., sftp=d4e5f6...): /ihub-db-backups/backup.bz2
[ERROR] [UL3] Checksum verification failed — flagging for re-upload and deleting corrupt SFTP copy
[WARN]  [UL3] Deleted corrupt SFTP file to force re-upload on next run: /ihub-db-backups/backup.bz2
[WARN]  Flagged for re-upload in ./reupload.log: /backup.bz2
```

---

## Re-upload Flag (`reupload.log`)

`reupload.log` is a persistent plain-text file (one FTP path per line) that tracks files requiring forced re-upload due to a previous checksum failure. It lives alongside the script in `SCRIPT_DIR` by default (configurable via `REUPLOAD_LOG`).

### How it works

**On checksum failure:**
1. The FTP path is written to `reupload.log` immediately, before any delete attempt
2. The corrupt SFTP copy is deleted so the next run finds `NOT_FOUND`
3. If the SFTP delete fails, the file remains in `reupload.log` as a safety net — the next run will still force a re-upload regardless of what it finds on SFTP
4. The file is counted as an error; FTP deletion is blocked

**On the next run:**
1. The download worker checks `reupload.log` before the normal SFTP size comparison
2. If the file is flagged, it is force-re-downloaded from FTP regardless of SFTP state
3. The upload worker re-uploads, re-verifies size, and re-verifies checksum
4. If checksum passes: entry is removed from `reupload.log` and the file proceeds to the normal retention/deletion stage
5. If checksum fails again: entry stays in `reupload.log`, cycle repeats

### Startup warning

If `reupload.log` has entries when the script starts, it logs a warning before any processing begins:

```
[WARN] *** REUPLOAD PENDING: 2 file(s) flagged for forced re-upload from a previous checksum failure ***
[WARN]     Flagged file list: /opt/ftp-sftp-transfer/reupload.log
[WARN]     Re-upload pending: /helium_rewards_20250112.sql.bz2
[WARN]     Re-upload pending: /helium_rewards_20250105.sql.bz2
```

### Manual intervention

You can edit `reupload.log` directly:
- **Add a path** to force re-upload of a specific file on the next run
- **Remove a path** if you have manually verified and fixed the SFTP copy and do not want a re-upload

---

## Verify Mode (`-V`)

The `-V` flag (or `VERIFY_MODE="true"` in config) runs a full re-confirmation pass over all files. This is intended as a one-time operation after a bulk upload to verify all files are correct before FTP retention deletion begins.

```bash
./transfer.sh -V          # Re-confirm all files, then run retention deletions
./transfer.sh -V -n       # Re-confirm without deleting anything from FTP
./transfer.sh -V -v       # Re-confirm with verbose debug output
```

### What verify mode does differently

| Step | Normal mode | Verify mode |
|------|-------------|-------------|
| Already on SFTP, size matches | Skip (queue for retention only) | Force re-download from FTP |
| SFTP upload | Always uploads | **Skipped** — verifies existing SFTP copy only |
| Size check | Post-upload | Against existing SFTP copy |
| Checksum | Re-downloads SFTP copy | Re-downloads SFTP copy |
| On checksum pass | Clear reupload.log, confirm | Clear reupload.log, confirm |
| On checksum fail | Flag reupload.log, delete SFTP copy | Flag reupload.log, delete SFTP copy |
| FTP deletion | After confirmed upload | After confirmed verify |

### Log output in verify mode

```
[INFO]  [UL3] [VERIFY] Skipping upload — verifying existing SFTP copy: /ihub-db-backups/backup.bz2
[INFO]  [UL3] [VERIFY] Verified OK [52428800 bytes, checksum OK]: /backup.bz2 → /ihub-db-backups/backup.bz2

# File missing on SFTP
[ERROR] [UL3] [VERIFY] File not found on SFTP — was never uploaded: /ihub-db-backups/missing.bz2

# Checksum failure
[ERROR] [UL3] [VERIFY] Checksum FAILED — flagging for re-upload and deleting corrupt SFTP copy
```

---

## Logging

### Log Files

| File | Retention | Contents |
|------|-----------|---------|
| `logs/transfer_YYYYMMDD_HHMMSS.log` | Auto-deleted after `LOG_RETENTION_DAYS` days | Full run log (all levels) |
| `logs/errors_YYYYMMDD.log` | **Never auto-deleted** | ERROR-level events only |
| `reupload.log` | Managed by script | FTP paths flagged for forced re-upload |

All log writes are atomic — concurrent workers use `flock` on a shared lock file so lines from different workers are never interleaved.

### Log Levels

| Level | Written to | When |
|-------|-----------|------|
| `ERROR` | Log file + error log + stderr | Transfer failures, verification failures, unexpected conditions |
| `WARN` | Log file + stdout | Skipped files, retention decisions, re-upload flags, disk wait |
| `INFO` | Log file + stdout | Normal progress: transfers, confirmations, deletions, summary |
| `DEBUG` | Log file + stdout (only with `-v`) | Per-file decisions, SFTP size queries, worker state |

### Log Format

```
[2025-03-14 18:00:00] [INFO]  === transfer.sh v2.1.0 — Transfer run started (PID 12345) ===
[2025-03-14 18:00:01] [INFO]  Checksum verification enabled (VERIFY_CHECKSUM=true)
[2025-03-14 18:00:02] [INFO]  Work queue populated: 47 file(s) to evaluate
[2025-03-14 18:00:02] [INFO]  Starting pipeline: 2 FTP download worker(s), 10 SFTP upload worker(s)
[2025-03-14 18:00:03] [DEBUG] [DL1] Already synced — queuing for retention check only: /old_backup.bz2
[2025-03-14 18:00:05] [INFO]  [DL2] Downloading (new file): /backup_20250314.sql.bz2 → staging
[2025-03-14 18:00:08] [INFO]  [UL4] Upload confirmed [4196709757 bytes, checksum OK]: /backup_20250314.sql.bz2 → /ihub-db-backups/backup_20250314.sql.bz2
[2025-03-14 18:00:09] [INFO]  [DEL1] Deleted from FTP (age ≥ 7d, confirmed on SFTP): /old_backup.bz2
```

### Run Summary

At the end of each run, a summary is printed to stdout and appended to the run log:

```
╔══════════════════════════════════════════════════╗
║         Transfer Run Summary
╠══════════════════════════════════════════════════╣
║  Started        : 2025-03-14 18:00:00
║  Finished       : 2025-03-14 18:07:30
║  Duration       : 7m 30s
║  DL Workers     : 2  (FTP → staging)
║  UL Workers     : 10  (staging → SFTP)
╠══════════════════════════════════════════════════╣
║  Files Scanned      : 47
║  Files Transferred  : 12
║  Files Overwritten  : 0
║  Files Skipped      : 35
║  FTP Files Deleted  : 8
║  Errors             : 0
╚══════════════════════════════════════════════════╝
```

---

## Running via Cron

The script uses a PID lock file (`/tmp/ftp_sftp_transfer.lock`) to prevent overlapping runs. If a second instance starts while one is already running, it exits immediately with an error.

### Example Crontab Entry

```cron
# Run FTP-to-SFTP transfer daily at 2:00 AM
0 2 * * * /opt/ftp-sftp-transfer/transfer.sh -c /opt/ftp-sftp-transfer/transfer.conf >> /opt/ftp-sftp-transfer/logs/cron.log 2>&1
```

### Setting Up the Crontab

```bash
# Edit the crontab for the current user
crontab -e

# Or for a specific user (as root)
crontab -u www-data -e
```

### Recommended Workflow for Initial Setup

```bash
# 1. Do a dry run first to see what would be transferred
./transfer.sh -d -v

# 2. Run the actual transfer
./transfer.sh

# 3. After transfer completes, run a verify pass to confirm all files
#    before FTP deletion begins
./transfer.sh -V -n    # -n disables FTP deletion during the verify pass

# 4. If verify passes cleanly, run with deletions enabled
./transfer.sh -V
```

### Non-Interactive Dependency Check

When run from cron (non-interactive), if any required binary is missing the script will print the install command to stderr and exit with code 1. The cron output will be captured in `cron.log`. Install the missing packages manually and re-run.

---

## Security Notes

### Config File Permissions

The `transfer.conf` file contains FTP and SFTP credentials. Always restrict its permissions:

```bash
chmod 600 /opt/ftp-sftp-transfer/transfer.conf
```

The script warns at startup if permissions are too open, but does not refuse to run.

### Password Handling

- **SFTP:** `sshpass` is called with the `-e` flag, which reads the password from the `SSHPASS` environment variable rather than as a command-line argument. This prevents the password from appearing in `ps aux` or process listings.
- **FTP:** Credentials are passed inline to `lftp` (standard lftp behaviour). Restrict access to the script and config file accordingly.

### FTP Protocol

This script uses **plain FTP with TLS disabled** (`set ftp:ssl-allow no`). This is intentional for servers that do not support FTPES. All FTP traffic is unencrypted — this is acceptable on a trusted intranet/private network but should not be used over the public internet.

### SFTP Host Key Verification

By default, the script uses `-o StrictHostKeyChecking=no` to allow first-time connections without manual intervention. For a hardened production environment, pre-populate the SFTP server's host key:

```bash
# Add the SFTP server's host key to known_hosts
ssh-keyscan -p 22 sftp.example.com >> ~/.ssh/known_hosts
```

Then change `StrictHostKeyChecking=no` to `StrictHostKeyChecking=yes` in the `sftp_get_size`, `sftp_mkdir_p`, `sftp_download_verify`, and `sftp_delete_file` functions in `transfer.sh`.

### Temp Directory

Staging files are stored in a directory created with `mktemp -d` (mode `700`), making them inaccessible to other users. If you specify a custom `TEMP_DIR`, ensure it has appropriate permissions and sufficient disk space for `FTP_MAX_WORKERS × largest_file_size`.

---

## Troubleshooting

### Script exits with "Another instance is already running"

A previous run may have crashed without releasing the lock file. Check if the PID is still active:

```bash
cat /tmp/ftp_sftp_transfer.lock    # See the PID
ps aux | grep transfer.sh          # Check if it's still running
```

If the process is not running, remove the lock file manually:

```bash
rm /tmp/ftp_sftp_transfer.lock
```

### Files keep being re-downloaded on every run

The most common causes are:

1. **FTP reports a different size than SFTP** — run with `-v` to see `sftp_get_size` debug output and compare with the FTP listing
2. **File is in `reupload.log`** — check the file; if the entry is stale, remove it manually
3. **`OVERWRITE_ON_SIZE_DIFF=true`** with genuinely mismatched files — inspect the file on both servers

### Upload verification fails (`Upload size verification failed`)

Some object-storage SFTP backends report a partial/chunk size briefly after a write completes. The script retries `sftp_get_size` up to 4 times with 3-second gaps. If it still fails after all retries:

1. Check available disk/quota on the SFTP server
2. Check network stability
3. Look at the `errors_YYYYMMDD.log` for the exact expected vs reported sizes
4. Run with `-v` to see the raw SFTP `ls -l` output

### Checksum verification fails

```
[ERROR] Checksum MISMATCH (staged=a1b2..., sftp=d4e5...): /ihub-db-backups/file.bz2
```

This means the file on SFTP does not match the file downloaded from FTP. The script automatically:
1. Flags the file in `reupload.log`
2. Deletes the corrupt SFTP copy

On the next run the file will be re-downloaded from FTP and re-uploaded. If failures persist, check:
1. Whether the FTP source file itself is corrupt
2. Network issues causing silent data corruption
3. Whether the SFTP server has storage problems

### Files are not being deleted from FTP after `RETENTION_DAYS`

Check the following:

1. `DELETE_FROM_FTP="true"` is set in `transfer.conf`
2. The file's mtime on the FTP server is correct (some FTP servers have timezone issues)
3. The file completed a verified upload in the current or a previous run — check `confirmed_queue` behavior in the log
4. Run with `-v` to see per-file age calculations and SFTP confirmation status

### Upload workers show as idle for a long time

This is normal when FTP downloads are slow relative to uploads. The upload workers poll the ready queue every second and log an aggregated idle message at most once every `DISK_WAIT_INTERVAL` seconds:

```
[DEBUG] Upload Workers: 10/10 thread(s) idle, waiting for downloads
```

This is not an error — the workers will pick up files as soon as the download workers enqueue them.

### Dependencies missing in cron but present interactively

This is usually a `PATH` issue. Add the full path to binaries or set `PATH` explicitly in your crontab:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * /opt/ftp-sftp-transfer/transfer.sh ...
```

### Disk space wait timeout

```
[WARN] [DL1] Disk space wait timed out after 300s — skipping (need 4294967296B, usable -1073741824B)
```

The staging directory is full and no workers freed space in time. Options:
1. Increase `TEMP_DIR` disk capacity
2. Reduce `DISK_SPACE_BUFFER_PCT`
3. Point `TEMP_DIR` to a larger filesystem
4. Reduce `FTP_MAX_WORKERS` so fewer large files are staged simultaneously