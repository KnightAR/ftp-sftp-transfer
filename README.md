# ftp-sftp-transfer

A collection of Bash scripts for transferring, archiving, splitting, and recompressing files between FTP servers, SFTP servers, and local storage. All scripts share a common configuration file (`transfer.conf`), logging conventions, and reusable `src/` modules.

---

## Scripts at a Glance

| Script | Purpose | Doc |
|--------|---------|-----|
| `transfer.sh` | Mirror an entire FTP server to SFTP with parallel workers, checksum verification, and mtime-based retention | [docs/transfer.md](docs/transfer.md) |
| `split_transfer.sh` | Download a single large file from FTP, split into parts, upload all parts to SFTP in parallel | [docs/split.md](docs/split.md) |
| `split_upload.sh` | Split a local file into parts and upload to SFTP (no FTP download) | [docs/split.md](docs/split.md) |
| `split_restore.sh` | Download parts from SFTP and stream-reassemble into the original file with sha256 verification | [docs/split.md](docs/split.md) |
| `recompress.sh` | Recompress `.bz2`, `.gz`, `.zip`, `.7z` archives to `.xz` format | [docs/compress.md](docs/compress.md) |
| `strip_archive.sh` | Remove directories from a compressed tar archive | [docs/compress.md](docs/compress.md) |
| `zpaq_archive.sh` | Download files from FTP/SFTP/local sources and add them to a single-file `.zpaq` super-archive | [docs/zpaq.md](docs/zpaq.md) |
| `storezpaq.sh` | Upload a single-file `.zpaq` archive to SFTP with integrity checking, atomic upload, and timestamped backup rotation | [docs/zpaq.md](docs/zpaq.md) |
| `storezpaq_multi.sh` | Download compressed sources, decompress, group by date, and build a growing **multipart** `.zpaq` archive with atomic per-part upload to SFTP | [docs/zpaq.md](docs/zpaq.md) |

---

## Quick Start

### 1. Install dependencies

```bash
# Core (required by transfer.sh, split scripts, zpaq scripts)
sudo apt-get install -y lftp sshpass openssh-client

# Compression scripts
sudo apt-get install -y libarchive-tools xz-utils pbzip2 p7zip-full unzip zstd

# zpaq scripts
sudo apt-get install zpaqfranz        # Debian 13+
# or build from source — see docs/zpaq.md

# storezpaq_multi.sh additional decompressors (optional, for best performance)
sudo apt-get install -y lbzip2 pigz
```

### 2. Configure

```bash
cp transfer.example.conf transfer.conf
nano transfer.conf
chmod 600 transfer.conf
```

All scripts read `transfer.conf` (or `storezpaq.conf` for `storezpaq_multi.sh`) from the same directory. See [Configuration](#configuration) below for the full variable reference.

### 3. Run

```bash
# Mirror FTP → SFTP
./transfer.sh

# Split and upload a large local file
./split_upload.sh /data/bigfile.sql.bz2

# Build a single-file zpaq super-archive from multiple sources
./zpaq_archive.sh backup.zpaq ftp://host/db/ sftp://host2/exports/

# Upload the single-file zpaq archive to SFTP
./storezpaq.sh backup.zpaq

# Build a growing multipart zpaq archive from dated compressed sources
./storezpaq_multi.sh myarchive sftp://host/backups/'*.sql.xz'

# Backfill all unarchived history in one pass
./storezpaq_multi.sh -backfill myarchive sftp://host/backups/'*.sql.xz'
```

---

## Configuration

### transfer.conf — Shared by all scripts except storezpaq_multi.sh

Copy `transfer.example.conf` as a starting point.

> **Security:** Always `chmod 600 transfer.conf` after editing — it contains credentials. Scripts warn on startup if permissions are too open.

```bash
# === FTP Settings ===
FTP_HOST="ftp.example.com"
FTP_PORT="21"
FTP_USER="ftp_user"
FTP_PASS="ftp_password"
FTP_REMOTE_DIR="/"               # Root to mirror from (transfer.sh)

# === SFTP Settings ===
SFTP_HOST="sftp.example.com"
SFTP_PORT="22"
SFTP_USER="sftp_user"
SFTP_PASS="sftp_password"
SFTP_REMOTE_DIR="/ihub-db-backups"   # Destination root on SFTP server

# === Transfer Settings (transfer.sh) ===
RETENTION_DAYS=7                 # Delete FTP files older than N days after confirmed upload
FTP_MAX_WORKERS=2                # Parallel FTP download workers
SFTP_MAX_WORKERS=10              # Parallel SFTP upload workers

# === Disk Space Management ===
DISK_SPACE_BUFFER_PCT=10
DISK_WAIT_TIMEOUT=300
DISK_WAIT_INTERVAL=10

# === Paths ===
TEMP_DIR=""                      # Leave empty for auto mktemp
EXCLUDE_LIST="./exclude.list"
LOG_DIR="./logs"
LOG_RETENTION_DAYS=30

# === Behavior Flags ===
DRY_RUN="false"
DELETE_FROM_FTP="true"
OVERWRITE_ON_SIZE_DIFF="true"

# === Verification ===
VERIFY_CHECKSUM="true"
VERIFY_MODE="false"
REUPLOAD_LOG="./reupload.log"
VERIFY_ARCHIVE_INTEGRITY=true
```

### storezpaq.conf — storezpaq_multi.sh

`storezpaq_multi.sh` reads `storezpaq.conf` (in the same directory as the script) rather than `transfer.conf`. The config file is **optional** — all keys have built-in defaults and can be overridden at the command line. Only the five required variables must be set (via config or CLI flags).

```bash
# === Required ===
SFTP_HOST="sftp.example.com"
SFTP_PORT="22"                   # default: 22
SFTP_USER="sftp_user"
SFTP_PASS="sftp_password"
SFTP_REMOTE_DIR="/ihub-db-backups"
ZPAQ_LOCAL_DIR="/data/zpaq"      # Local directory where all .zpaq parts are stored

# === zpaqfranz compression ===
ZPAQ_COMPRESSION="-m5"           # default: -m5
ZPAQ_EXTRA_FLAGS="-ssd"          # default: -ssd
ZPAQ_FRAGMENT=3                  # CDC fragment size exponent (default: 3 = avg 8 KB)
                                 # Locked per archive on first add — cannot change later
ZPAQ_THREADS=""                  # default: 25% of nproc, max 8

# === Multipart naming ===
ZPAQ_MULTIPART_QUESTION_MARKS=7  # Number of ? in archive pattern (default: 7)
                                 # basename??????? → basename0000001.zpaq, etc.

# === Decompression ===
XZ_DECOMPRESS_THREADS=4          # Threads for xz -d (default: 4)

# === Space management ===
ZPAQ_HEADROOM_RATIO=0.30         # Extra headroom fraction on top of estimated size (default: 0.30)
BACKFILL_MIN_FREE_GB=100         # Minimum free disk floor for backfill mode (default: 100)
SIZE_HISTORY_SAMPLES=5           # Number of recent .bz2 decompressions to average (default: 5)
SIZE_ESTIMATE_SAFETY_FACTOR=1.20 # Safety multiplier applied to bz2 estimates (default: 1.20)
BZ2_DEFAULT_RATIO=3.5            # Fallback bz2 expansion ratio when no history exists (default: 3.5)

# === ARG_MAX protection ===
ARGMAX_SAFE_THRESHOLD=131072     # Max bytes in zpaqfranz file list before falling back to . (default: 131072)

# === Upload ===
UPLOAD_RETRY_COUNT=3             # Per-part upload retry attempts (default: 3)

# === Monitoring ===
ZPAQ_LOCAL_SIZE_WARN_GB=500      # Warn when local archive set exceeds this size (default: 500)

# === Logging ===
LOG_DIR=""                       # default: ZPAQ_LOCAL_DIR/logs
LOG_RETENTION_DAYS=30            # default: 30
```

---

## Script Summaries

### transfer.sh — FTP → SFTP Mirror

Mirrors an entire FTP directory tree to SFTP using a decoupled parallel pipeline: `FTP_MAX_WORKERS` download workers feed a shared queue consumed by `SFTP_MAX_WORKERS` upload workers. Each file is sha256-verified after upload. Files older than `RETENTION_DAYS` on FTP are deleted after confirmed upload.

```bash
./transfer.sh                    # Standard run
./transfer.sh -d -v              # Dry run with verbose output
./transfer.sh -n                 # Transfer only, no FTP deletions
./transfer.sh -V -n              # Re-verify all SFTP copies, delete nothing
```

→ [Full documentation](docs/transfer.md)

---

### split_transfer.sh / split_upload.sh / split_restore.sh — Large File Splitting

For files too large to transfer or store as a single unit. Files are split into fixed-size parts (default 1 GB), each part sha256-hashed, and a `.manifest` file written alongside the parts on SFTP. `split_restore.sh` uses the manifest to download and stream-reassemble the original with minimal peak disk usage.

```bash
# FTP → split → SFTP (500 MB parts)
./split_transfer.sh /backups/dump.sql.bz2 -s 500m

# Local → split → SFTP (into a subdirectory)
./split_upload.sh /data/bigfile.sql.bz2 -r /db/2025

# SFTP parts → reassemble locally
./split_restore.sh /ihub-db-backups/dump.sql.bz2.manifest -o /data/restored.sql.bz2

# Verify parts on SFTP without downloading output
./split_restore.sh /ihub-db-backups/dump.sql.bz2.manifest -V
```

Peak disk usage during restore ≈ `output_file_size + (workers × part_size)` — parts are streamed into the output file in order rather than accumulated first.

→ [Full documentation](docs/split.md)

---

### recompress.sh — Recompress to XZ

Converts `.bz2`, `.gz`, `.zip`, `.7z` archives to `.xz` format. Output is staged in `TEMP_DIR` before being moved to the source directory. XZ files are skipped automatically.

```bash
./recompress.sh /backups/dump.sql.bz2          # Single file
./recompress.sh /backups/ -r -o -d             # Recursive, overwrite, delete originals
./recompress.sh archive.zip -t                 # Force tar-wrap multi-member zip
```

→ [Full documentation](docs/compress.md)

---

### strip_archive.sh — Remove Directories from Tar Archives

Decompresses a compressed tar archive, removes specified directories via `tar --delete`, and recompresses to `.tar.xz`. All staging is done in `TEMP_DIR`. Supports resume if interrupted.

```bash
./strip_archive.sh backup.tar.bz2 logs,tmp,cache
./strip_archive.sh backup.tar.bz2 logs -o /out/backup-clean.tar.xz -d
./strip_archive.sh backup.tar.bz2 -C            # Skip --delete, just recompress staged .tar
```

Requires `bsdtar`: `sudo apt-get install libarchive-tools`

→ [Full documentation](docs/compress.md)

---

### zpaq_archive.sh — Build a Single-File zpaq Super-Archive

Downloads files from one or more `ftp://`, `sftp://`, or local sources and appends them to a single `.zpaq` archive using `zpaqfranz`. Already-archived files are skipped (idempotent). Downloads run in parallel; `zpaqfranz` add calls are serialised. Subpaths are preserved relative to each source root.

```bash
./zpaq_archive.sh backup.zpaq ftp://host/db/ sftp://host2/exports/ /local/extra/
./zpaq_archive.sh -j 8 backup.zpaq ftp://host/data/
./zpaq_archive.sh zpaq/daily/backup.zpaq ftp://host/db/
```

→ [Full documentation](docs/zpaq.md)

---

### storezpaq.sh — Upload Single-File zpaq Archive to SFTP

Uploads a `.zpaq` archive to SFTP with a 5-step safety workflow:

1. **Integrity test** — `zpaqfranz t` before uploading
2. **No-op check** — skip if sha256/size unchanged since last upload
3. **Remote divergence check** — warn if remote was modified externally
4. **Atomic upload** — upload to `.tmp_upload`, re-download + sha256 verify, rename with timestamped backup of prior version
5. **Manifest upload** — track state for future no-op detection

```bash
./storezpaq.sh backup.zpaq                     # → SFTP_REMOTE_DIR/backup.zpaq
./storezpaq.sh zpaq/daily/backup.zpaq          # → SFTP_REMOTE_DIR/zpaq/daily/backup.zpaq
./storezpaq.sh -k 14 zpaq/daily/backup.zpaq    # Keep 14 timestamped backups
./storezpaq.sh -f backup.zpaq                  # Force upload even if unchanged
```

→ [Full documentation](docs/zpaq.md)

---

### storezpaq_multi.sh — Multipart zpaq Archive from Compressed Sources

Downloads compressed source files (`.xz`, `.bz2`, `.gz`, `.zip`, `.sql`) from SFTP, FTP, or local paths, decompresses them into a flat staging area, groups them by date extracted from filenames (`*_YYYYMMDD.*`), and appends each group to a growing multipart `.zpaq` archive using `zpaqfranz`. Each part is atomically uploaded and sha256-verified before the next group is processed.

Key features:

- **Multipart naming** — `basename???????` pattern produces `basename0000001.zpaq`, `basename0000002.zpaq`, etc. All parts are retained locally (required for zpaqfranz cross-part deduplication)
- **Fragment lock-in** — `ZPAQ_FRAGMENT` (default 3) is written to the manifest on first add and validated on every subsequent run; mismatches abort immediately
- **Single content cache** — one `zpaqfranz l` at startup builds an in-memory lookup; no per-file archive scans
- **Pre-add remote sync** — downloads any parts present on SFTP but missing locally before adding new content
- **Per-part atomic upload** — upload to `.tmp_upload` → download-back sha256 verify → rename live → update manifest
- **Backfill mode** (`-backfill`) — combines all unarchived date groups into a single `zpaqfranz add` for maximum cross-file deduplication
- **bz2 size estimation** — uses a per-basename history file of actual compressed/uncompressed ratios (last 5 samples × 1.20 safety factor) since bzip2 has no uncompressed-size metadata
- **ARG_MAX protection** — passes an explicit file list to zpaqfranz; falls back to a `.` sweep when the total argument bytes exceed `ARGMAX_SAFE_THRESHOLD` (128 KB)

```bash
# Normal mode — one zpaq add per date group
./storezpaq_multi.sh myarchive sftp://host/backups/'*.sql.xz'

# Backfill all unarchived history
./storezpaq_multi.sh -backfill myarchive sftp://host/backups/'*.sql.xz'

# Limit backfill to the 30 most recent unarchived days
./storezpaq_multi.sh -backfill -backfill-days 30 myarchive sftp://host/backups/'*.sql.xz'

# Dry run — show what would be done without making changes
./storezpaq_multi.sh -dry-run myarchive sftp://host/backups/'*.sql.xz'

# Multiple sources with explicit credentials
./storezpaq_multi.sh -u admin -p secret myarchive \
    sftp://host/slim/'*.sql.bz2' \
    sftp://host/vxtl/'*.sql.xz'
```

→ [Full documentation](docs/zpaq.md)

---

## Project Structure

```
ftp-sftp-transfer/
├── transfer.sh             FTP → SFTP mirror
├── split_transfer.sh       FTP download → split → SFTP upload
├── split_upload.sh         Local split → SFTP upload
├── split_restore.sh        SFTP parts → reassemble
├── recompress.sh           Recompress archives to XZ
├── strip_archive.sh        Strip directories from tar archives
├── zpaq_archive.sh         Build / update a single-file .zpaq super-archive
├── storezpaq.sh            Upload single-file .zpaq to SFTP with safety workflow
├── storezpaq_multi.sh      Build multipart .zpaq archive from compressed sources
│
├── transfer.conf           Credentials and settings for all scripts except storezpaq_multi.sh
├── storezpaq.conf          Credentials and settings for storezpaq_multi.sh (optional)
├── transfer.example.conf   Example config — copy and edit
├── exclude.list            Basename glob patterns to skip in transfer.sh
│
├── src/
│   ├── core/               constants, args, config, logging
│   ├── system/             lock, temp, dependencies, trap
│   ├── transfer/           ftp, sftp, ftp_download, sftp_download,
│   │                         exclusions, archive_verify, reupload, ftp_delete
│   ├── compress/           compress_utils (shared by recompress + strip_archive)
│   ├── split/              split_args, split_upload_args, restore_args,
│   │                         split_config, split_manifest, split_ops,
│   │                         split_worker, restore_worker, restore_commit
│   ├── zpaq/               zpaq_utils, zpaq_manifest,
│   │                         zpaq_archive_ops, zpaq_sftp_ops,
│   │                         zpaq_multipart_manifest, zpaq_multipart_ops,
│   │                         zpaq_grouping
│   ├── workers/            counters, disk_guard, download_worker, upload_worker
│   └── pipeline/           pipeline, deletion_stage, summary, main
│
├── docs/
│   ├── transfer.md         transfer.sh detailed documentation
│   ├── split.md            split_transfer / split_upload / split_restore docs
│   ├── compress.md         recompress / strip_archive docs
│   ├── zpaq.md             zpaq_archive / storezpaq / storezpaq_multi docs
│   └── modules.md          src/ module reference
│
└── logs/                   Run logs (auto-created)
```

→ [Full src/ module reference](docs/modules.md)

---

## Locking

Every script that reads or writes the same file uses a `flock`-based exclusive lock to prevent concurrent corruption:

| Script | Lock File |
|--------|-----------|
| `transfer.sh` | `/tmp/ftp_sftp_transfer.lock` |
| `split_transfer.sh` | `/tmp/ftp_sftp_transfer.lock` |
| `split_upload.sh` | `/tmp/ftp_sftp_transfer.lock` |
| `split_restore.sh` | `/tmp/ftp_sftp_transfer.lock` |
| `zpaq_archive.sh` | `<archive>.zpaq.lock` |
| `storezpaq.sh` | `<archive>.zpaq.lock` |
| `storezpaq_multi.sh` | `<ZPAQ_LOCAL_DIR>/<basename>.zpaq.lock` |

Locks are OS-held via a file descriptor — automatically released if the process dies without calling `release_lock()`. No stale lock files after crashes.

---

## Security Notes

- **SFTP passwords** are passed via the `SSHPASS` environment variable (not a CLI argument) — invisible in `ps aux` and process listings.
- **FTP** uses plain unencrypted FTP (`set ftp:ssl-allow no`) — appropriate only on a trusted intranet.
- **Host key verification** uses `StrictHostKeyChecking=no` by default for first-run convenience. For hardened environments, pre-populate `~/.ssh/known_hosts` via `ssh-keyscan` and switch to `yes`.
- **Config file** must be `chmod 600`. All scripts warn on startup if permissions are too open.

---

## Running via Cron

```cron
# Daily FTP → SFTP mirror at 2:00 AM
0 2 * * * /opt/ftp-sftp-transfer/transfer.sh >> /opt/ftp-sftp-transfer/logs/cron.log 2>&1

# Daily zpaq archive update + upload at 3:00 AM (single-file workflow)
0 3 * * * /opt/ftp-sftp-transfer/zpaq_archive.sh zpaq/daily/backup.zpaq ftp://host/db/ && \
          /opt/ftp-sftp-transfer/storezpaq.sh zpaq/daily/backup.zpaq \
          >> /opt/ftp-sftp-transfer/logs/zpaq_cron.log 2>&1

# Daily multipart zpaq archive update at 4:00 AM
0 4 * * * /opt/ftp-sftp-transfer/storezpaq_multi.sh myarchive \
          sftp://host/backups/'*.sql.xz' \
          >> /opt/ftp-sftp-transfer/logs/multi_cron.log 2>&1
```

Set `PATH` explicitly in crontab if binaries are not found:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```