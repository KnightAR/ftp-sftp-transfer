# FTP to SFTP Transfer Script

**Version:** 1.0.0  
**OS:** Ubuntu Linux  
**Purpose:** Automatically mirror files from an FTP server to an SFTP server, with size-based overwrite detection, mtime-based FTP retention/deletion, parallel transfers, and structured logging.

---

## Table of Contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Exclusion List](#exclusion-list)
5. [Usage](#usage)
6. [How It Works](#how-it-works)
7. [Logging](#logging)
8. [Running via Cron](#running-via-cron)
9. [Security Notes](#security-notes)
10. [Troubleshooting](#troubleshooting)

---

## Requirements

The following packages must be installed on the system:

| Binary | Package | Purpose |
|--------|---------|---------|
| `lftp` | `lftp` | FTP client — listing, downloading, FTPES support |
| `sshpass` | `sshpass` | Non-interactive SFTP password injection |
| `sftp` | `openssh-client` | SFTP client for uploads and remote size checks |

The script will detect missing dependencies at startup and offer to install them automatically via `apt-get` when run interactively. When run non-interactively (e.g. from cron), it will print the install command and exit.

To install manually:

```bash
sudo apt-get install -y lftp sshpass openssh-client
```

---

## Installation

```bash
# 1. Clone or copy the script files to your preferred location
mkdir -p /opt/ftp-sftp-transfer
cp transfer.sh transfer.conf exclude.list /opt/ftp-sftp-transfer/

# 2. Make the script executable
chmod +x /opt/ftp-sftp-transfer/transfer.sh

# 3. Secure the config file (contains credentials)
chmod 600 /opt/ftp-sftp-transfer/transfer.conf

# 4. Create the logs directory
mkdir -p /opt/ftp-sftp-transfer/logs
```

---

## Configuration

All settings are stored in `transfer.conf`. This file is sourced as a bash script at startup.

> **Security:** Always run `chmod 600 transfer.conf` after editing. The script will warn you if the file permissions are too open.

### Full Configuration Reference

```bash
# === FTP Settings ===
FTP_HOST="ftp.example.com"      # FTP server hostname or IP
FTP_PORT="21"                   # FTP port (usually 21)
FTP_USER="ftp_user"             # FTP username
FTP_PASS="ftp_password"         # FTP password
FTP_REMOTE_DIR="/"              # FTP root to mirror from (recursive)

# === SFTP Settings ===
SFTP_HOST="sftp.example.com"    # SFTP server hostname or IP
SFTP_PORT="22"                  # SFTP port (usually 22)
SFTP_USER="sftp_user"           # SFTP username
SFTP_PASS="sftp_password"       # SFTP password
SFTP_REMOTE_DIR="/ihub-db-backups"  # Destination root on SFTP

# === Transfer Settings ===
RETENTION_DAYS=7                # Files older than N days on FTP are deleted
                                # after confirmed upload to SFTP (uses FTP mtime)
MAX_PARALLEL=2                  # Max concurrent transfer workers
                                # (FTP server allows 3 connections max;
                                #  2 used for workers, 1 reserved for listing)

# === Paths ===
TEMP_DIR=""                     # Leave empty to use system temp (/tmp/ftp_sftp_XXXXX)
                                # Or set an absolute path: TEMP_DIR="/mnt/staging"
EXCLUDE_LIST="./exclude.list"   # Path to exclusion list file
LOG_DIR="./logs"                # Directory for log files
LOG_RETENTION_DAYS=30           # Auto-delete general logs after N days
                                # Error logs are NEVER auto-deleted

# === Behavior Flags ===
DRY_RUN="false"                 # "true" = simulate, no files moved or deleted
DELETE_FROM_FTP="true"          # "false" = transfer only, never delete from FTP
OVERWRITE_ON_SIZE_DIFF="true"   # "false" = skip size-mismatched files instead of overwriting
FTP_USE_TLS="true"              # "true" = try FTPES first, fallback to plain FTP
```

---

## Exclusion List

The `exclude.list` file controls which files are skipped during transfer. Patterns are matched against the **basename** of each file (not the full path). Matching is case-sensitive.

### Supported Pattern Formats

| Pattern | Matches | Example |
|---------|---------|---------|
| `*.tmp` | Any file ending in `.tmp` | `dump.sql.gz.tmp` |
| `*.sql` | Any file ending in `.sql` | `backup.sql` |
| `debug.log` | Exact filename | `debug.log` only |
| `backup_*` | Files starting with `backup_` | `backup_2024.tar.gz` |
| `*partial*` | Files containing `partial` | `db_partial_restore.sql` |
| `NOUPLOAD` | Exact filename, no extension | `NOUPLOAD` |

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
DONOTTRANSFER.sql
debug.log
```

Lines beginning with `#` are comments. Blank lines are ignored. Inline comments (after a value) are also stripped.

---

## Usage

```
./transfer.sh [OPTIONS]

Options:
  -c FILE   Path to config file           (default: ./transfer.conf)
  -e FILE   Path to exclusion list        (default: value in config)
  -t DIR    Override temp/staging dir     (this run only)
  -d        Enable dry-run mode           (no files moved or deleted)
  -n        Disable FTP deletion          (transfer only, no deletes)
  -p N      Override max parallel workers (this run only)
  -v        Verbose output (DEBUG level)  (stdout + log)
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

# Single worker (useful for debugging or low-bandwidth situations)
./transfer.sh -p 1

# Use a custom staging directory for this run
./transfer.sh -t /mnt/fast-disk/staging

# Override exclusion list for this run
./transfer.sh -e /etc/transfer/my_exclude.list
```

---

## How It Works

### Transfer Decision per File

For each file found on the FTP server, the script applies the following logic:

```
1. Skip if filename starts with "."  (dot files)
2. Skip if filename matches exclusion list
3. Check if file exists on SFTP:
   a. Does not exist on SFTP      → Transfer it
   b. Exists, but sizes differ    → Re-transfer (overwrite) if OVERWRITE_ON_SIZE_DIFF=true
                                     Skip with warning if OVERWRITE_ON_SIZE_DIFF=false
   c. Exists, sizes match         → Skip (already in sync)
4. FTP Retention Check (independent of transfer):
   - If file mtime is ≥ RETENTION_DAYS old:
     - AND file is confirmed on SFTP with correct size → Delete from FTP
     - Otherwise → Log warning, do NOT delete
```

### Safety Rule

> A file is **never** deleted from FTP unless its presence and matching size on SFTP has been explicitly verified during that same run. A failed transfer will never trigger FTP deletion.

### Directory Structure

The FTP directory structure is **fully mirrored** on the SFTP server under `SFTP_REMOTE_DIR`. For example:

```
FTP:  /db/2024/january/dump.sql.gz
SFTP: /ihub-db-backups/db/2024/january/dump.sql.gz
```

Missing destination directories on SFTP are created automatically.

### FTP Protocol Detection

When `FTP_USE_TLS="true"`, the script will:

1. Attempt an FTPES (explicit TLS, `AUTH TLS`) connection
2. If that fails, fall back to plain FTP with a warning
3. The detected protocol is used for all operations in that run

Set `FTP_USE_TLS="false"` to skip the TLS attempt and use plain FTP directly.

### Parallel Workers

The script spawns up to `MAX_PARALLEL` background workers that process files concurrently from a shared work queue. Each worker:

- Holds its own FTP and SFTP connections
- Reads the next available file from the queue atomically (using `flock`)
- Processes its assigned files independently

The default of 2 workers is chosen to stay within a typical FTP server limit of 3 total connections (2 workers + 1 used during initial listing).

---

## Logging

### Log Files

| File | Retention | Contents |
|------|-----------|---------|
| `logs/transfer_YYYYMMDD_HHMMSS.log` | Auto-deleted after `LOG_RETENTION_DAYS` days | Full run log (all levels) |
| `logs/errors_YYYYMMDD.log` | **Never auto-deleted** (manual only) | ERROR-level events only |

### Log Format

```
[2025-01-15 03:42:00] [INFO]  === transfer.sh v1.0.0 — Transfer run started (PID 12345) ===
[2025-01-15 03:42:01] [INFO]  FTP protocol in use: FTPES
[2025-01-15 03:42:02] [INFO]  Work queue populated: 47 file(s) to evaluate
[2025-01-15 03:42:03] [DEBUG] [W1] Skipping dot file: /.ftpaccess
[2025-01-15 03:42:03] [DEBUG] [W2] Skipping excluded file: dump.tmp
[2025-01-15 03:42:05] [INFO]  [W1] Transferred OK [524288000 bytes]: /db/dump_20250108.sql.gz → /ihub-db-backups/db/dump_20250108.sql.gz
[2025-01-15 03:42:05] [INFO]  [W1] Deleted from FTP (age ≥ 7d, confirmed on SFTP): /db/dump_20250108.sql.gz
[2025-01-15 03:42:07] [WARN]  [W2] Size mismatch, overwrite disabled — skipping: /db/partial.sql.gz
```

### Run Summary

At the end of each run, a summary is printed to stdout and appended to the run log:

```
╔══════════════════════════════════════════╗
║         Transfer Run Summary
╠══════════════════════════════════════════╣
║  Started      : 2025-01-15 03:42:00
║  Finished     : 2025-01-15 03:45:30
║  Duration     : 3m 30s
║  Protocol     : FTPES
║  Workers used : 2
╠══════════════════════════════════════════╣
║  Files Scanned      : 47
║  Files Transferred  : 12
║  Files Overwritten  : 2
║  Files Skipped      : 31
║  FTP Files Deleted  : 8
║  Errors             : 0
╚══════════════════════════════════════════╝
```

---

## Running via Cron

The script includes a PID lock file mechanism (via `flock`) to prevent overlapping runs. If a second instance starts while one is already running, it will exit immediately with an error.

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

### Non-Interactive Dependency Check

When run from cron (non-interactive), if any required binary is missing the script will print the install command to stderr and exit with code 1. The cron output will be captured in `cron.log`. You will need to install the missing packages manually and re-run.

---

## Security Notes

### Config File Permissions

The `transfer.conf` file contains FTP and SFTP credentials. Always restrict its permissions:

```bash
chmod 600 /opt/ftp-sftp-transfer/transfer.conf
```

The script will warn at startup if the permissions are too open, but it will not refuse to run.

### Password Handling

- `sshpass` is called using the `-e` flag, which reads the password from the `SSHPASS` environment variable rather than passing it as a command-line argument. This prevents the password from appearing in `ps aux` or process listings.
- FTP credentials are passed directly to `lftp` inline (standard `lftp` behaviour). Restrict access to the script and config file accordingly.

### SFTP Host Key Verification

By default, the script uses `-o StrictHostKeyChecking=no` for SFTP connections to allow first-time connections without manual intervention. For a hardened production environment, you can pre-populate the SFTP server's host key and enable strict checking:

```bash
# Add the SFTP server's host key to known_hosts
ssh-keyscan -p 22 sftp.example.com >> ~/.ssh/known_hosts

# Then change StrictHostKeyChecking=no to StrictHostKeyChecking=yes
# in the sftp_get_size(), sftp_mkdir_p(), and transfer_file() functions
```

### Temp Directory

Staging files are stored in a directory created with `mktemp -d` (mode `700`), making them inaccessible to other users on the system. If you specify a custom `TEMP_DIR`, ensure it has appropriate permissions.

---

## Troubleshooting

### Script exits immediately with "Another instance is already running"

A previous run may have crashed without releasing the lock file. Check if the PID is still active:

```bash
cat /tmp/ftp_sftp_transfer.lock    # See the PID
ps aux | grep transfer.sh          # Check if it's running
```

If the process is not running, remove the lock file manually:

```bash
rm /tmp/ftp_sftp_transfer.lock
```

### FTPES connection fails, falling back to plain FTP

Check that the FTP server supports explicit TLS (`AUTH TLS` on port 21) and that port 21 is not blocked by a firewall. You can test manually:

```bash
lftp -u username,password -e "set ftp:ssl-force true; open ftp://ftp.example.com:21; ls; quit"
```

Set `FTP_USE_TLS="false"` in `transfer.conf` to permanently skip the TLS attempt.

### Files are not being deleted from FTP after 7 days

Check the following:

1. `DELETE_FROM_FTP="true"` is set in `transfer.conf`
2. The file's mtime on the FTP server is correctly reported (some FTP servers have timezone issues)
3. The file exists on SFTP with a matching size — check the run log for warnings about unconfirmed files
4. Run with `-v` (verbose) to see per-file age and SFTP confirmation status

### Upload verification fails

This typically means the upload was interrupted or the SFTP server reported a different file size. The file will **not** be deleted from FTP in this case (safety rule). Check:

1. Available disk space on the SFTP server
2. Network stability between the script host and SFTP server
3. SFTP server quotas or size limits
4. The `errors_YYYYMMDD.log` file for details

### Dry run shows unexpected files

Run with `-d -v` to see full debug output including why each file is included or excluded:

```bash
./transfer.sh -d -v 2>&1 | less
```

### Dependencies missing in cron but present interactively

This is usually a `PATH` issue. Cron runs with a minimal environment. Add the full path to binaries or set `PATH` explicitly at the top of your crontab:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * /opt/ftp-sftp-transfer/transfer.sh ...
```