# transfer.sh — FTP to SFTP Mirror

**Version:** 2.1.0

Mirrors files from a plain FTP server to an SFTP server using a decoupled parallel download/upload pipeline, sha256 checksum verification, disk-space guarding, mtime-based FTP retention/deletion, and structured logging.

---

## Requirements

| Binary | Package | Purpose |
|--------|---------|---------|
| `lftp` | `lftp` | FTP client — recursive listing and downloading |
| `sshpass` | `sshpass` | Non-interactive SFTP password injection |
| `sftp` | `openssh-client` | SFTP client for uploads, size checks, and deletes |

```bash
sudo apt-get install -y lftp sshpass openssh-client
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
  -v        Verbose output (DEBUG level)
  -V        Verify mode: re-download all FTP files, checksum-verify
            every SFTP copy, then run retention deletions
  -h        Show help message
```

### Common Examples

```bash
# Standard run
./transfer.sh

# Dry run — see what would happen without making changes
./transfer.sh -d -v

# Transfer only — no FTP deletions this run
./transfer.sh -n

# Override worker counts
./transfer.sh -f 1 -s 5

# Re-verify all previously uploaded files
./transfer.sh -V -n
```

---

## Configuration

All settings live in `transfer.conf` (copied from `transfer.example.conf`). Always restrict permissions after editing:

```bash
chmod 600 transfer.conf
```

### Full Reference

```bash
# === FTP Settings ===
FTP_HOST="ftp.example.com"
FTP_PORT="21"
FTP_USER="ftp_user"
FTP_PASS="ftp_password"
FTP_REMOTE_DIR="/"               # FTP root to mirror from (recursive)

# === SFTP Settings ===
SFTP_HOST="sftp.example.com"
SFTP_PORT="22"
SFTP_USER="sftp_user"
SFTP_PASS="sftp_password"
SFTP_REMOTE_DIR="/ihub-db-backups"   # Destination root on SFTP server

# === Transfer Settings ===
RETENTION_DAYS=7                 # Delete FTP files older than N days after confirmed upload
FTP_MAX_WORKERS=2                # Parallel FTP download workers
SFTP_MAX_WORKERS=10              # Parallel SFTP upload workers

# === Disk Space Management ===
DISK_SPACE_BUFFER_PCT=10         # % of TEMP_DIR disk to keep in reserve
DISK_WAIT_TIMEOUT=300            # Max seconds to wait for disk space
DISK_WAIT_INTERVAL=10            # Seconds between re-checks

# === Paths ===
TEMP_DIR=""                      # Leave empty for auto mktemp
EXCLUDE_LIST="./exclude.list"
LOG_DIR="./logs"
LOG_RETENTION_DAYS=30            # Error logs are never auto-deleted

# === Behavior Flags ===
DRY_RUN="false"
DELETE_FROM_FTP="true"
OVERWRITE_ON_SIZE_DIFF="true"

# === Verification ===
VERIFY_CHECKSUM="true"           # Re-download from SFTP and compare sha256
VERIFY_MODE="false"              # Re-verify all existing SFTP copies
REUPLOAD_LOG="./reupload.log"
```

---

## How It Works

### Pipeline Architecture

```
Stage 1 — FTP_MAX_WORKERS download workers
  Pop from work_queue → check SFTP state → download → push to ready_queue

Stage 2 — SFTP_MAX_WORKERS upload workers (concurrent with Stage 1)
  Pop from ready_queue → upload → size verify → sha256 verify → push to confirmed_queue

Stage 3 — FTP deletion (after all uploads confirmed)
  Pop from confirmed_queue → apply RETENTION_DAYS → delete old files from FTP
```

FTP workers and SFTP workers run in parallel — slow uploads never block downloads.

### Transfer Decision per File

```
1. Skip dot files
2. Skip exclusion list matches
3. Check reupload.log — force re-download if flagged
4. Check SFTP:
   a. VERIFY_MODE=true      → force re-download for re-verification
   b. Not on SFTP           → download and upload
   c. Size mismatch         → re-download and overwrite (or skip if OVERWRITE_ON_SIZE_DIFF=false)
   d. Size matches          → skip (queue for retention only)
5. Download → verify size → enqueue for upload
```

### Path Preservation

```
FTP: /db/2024/dump.sql.bz2   →   SFTP: /ihub-db-backups/db/2024/dump.sql.bz2
FTP: /slim/dump.sql.bz2      →   SFTP: /ihub-db-backups/slim/dump.sql.bz2
```

---

## Checksum Verification

When `VERIFY_CHECKSUM="true"` (default), every upload goes through two checks:

1. **Size check** — `sftp_get_size` confirms the remote byte count (retries up to 4× for object-storage backends that report partial sizes briefly after write).
2. **Checksum check** — re-downloads the SFTP copy to a `.verify` temp file and compares `sha256sum` against the staged original.

If either check fails the upload is counted as an error, FTP deletion is blocked, and the file is flagged in `reupload.log` for forced re-upload on the next run.

---

## Re-upload Flag (`reupload.log`)

`reupload.log` tracks files requiring forced re-upload due to a previous checksum failure.

- **On failure:** FTP path written to `reupload.log`, corrupt SFTP copy deleted.
- **Next run:** file is force re-downloaded regardless of SFTP state. On success the entry is cleared; on continued failure it remains.

You can edit `reupload.log` directly to add or remove entries.

---

## Verify Mode (`-V`)

Runs a full re-confirmation pass over all existing SFTP copies. Does not upload — only re-downloads and checks checksums. Use before enabling FTP deletion on a new installation.

```bash
./transfer.sh -V -n    # Verify everything, delete nothing
./transfer.sh -V       # Verify then run retention deletions
```

---

## Exclusion List

`exclude.list` patterns match against the **basename** of each file (glob, case-sensitive). Lines starting with `#` are comments.

```
*.tmp
*.partial
*.swp
DONOTUPLOAD
```

---

## Logging

| File | Retention | Contents |
|------|-----------|----------|
| `logs/transfer_YYYYMMDD_HHMMSS.log` | `LOG_RETENTION_DAYS` days | Full run log |
| `logs/errors_YYYYMMDD.log` | **Never deleted** | ERROR events only |

All log writes are atomic via `flock` — worker lines are never interleaved.

Log levels: `ERROR` → `WARN` → `INFO` → `DEBUG` (`-v` only).

---

## Running via Cron

The script uses a PID lock file (`/tmp/ftp_sftp_transfer.lock`) to prevent overlapping runs.

```cron
0 2 * * * /opt/ftp-sftp-transfer/transfer.sh -c /opt/ftp-sftp-transfer/transfer.conf >> /opt/ftp-sftp-transfer/logs/cron.log 2>&1
```

---

## Security Notes

- **SFTP password** is passed via the `SSHPASS` environment variable (not a CLI arg) — invisible in `ps aux`.
- **FTP** uses plain unencrypted FTP (`set ftp:ssl-allow no`) — only appropriate on a trusted intranet.
- **Host key verification** uses `StrictHostKeyChecking=no` by default. Pre-populate `~/.ssh/known_hosts` and switch to `yes` for hardened environments.
- **Config file** must be `chmod 600` — the script warns if permissions are too open.

---

## Troubleshooting

**"Another instance is already running"**
```bash
cat /tmp/ftp_sftp_transfer.lock   # Check PID
ps aux | grep transfer.sh         # Confirm it's not running
rm /tmp/ftp_sftp_transfer.lock    # Remove if stale
```

**Files re-downloaded on every run**
- FTP size ≠ SFTP size → run `-v` to inspect `sftp_get_size` output
- File is in `reupload.log` → check or clear the entry

**Upload size verification fails**
- Retry logic handles object-storage backends (4 attempts, 3s gap)
- Check SFTP quota and network stability

**Files not deleted from FTP after `RETENTION_DAYS`**
- Confirm `DELETE_FROM_FTP="true"` and `RETENTION_DAYS` in config
- File must have completed a verified upload in the current or previous run

**Disk space wait timeout**
- Increase `TEMP_DIR` capacity, reduce `DISK_SPACE_BUFFER_PCT`, or lower `FTP_MAX_WORKERS`