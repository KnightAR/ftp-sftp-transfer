# zpaq Scripts — Super Archive & SFTP Storage

Three scripts for building and storing `.zpaq` archives — either a single growing file or a multipart set — accumulating content from FTP, SFTP, or local sources over time, with full SFTP upload safety and disaster recovery.

| Script | Purpose |
|--------|---------|
| `zpaq_archive.sh` | Download sources → add files to a single-file `.zpaq` archive |
| `storezpaq.sh` | Upload a single-file `.zpaq` archive to SFTP with integrity checking and backup rotation |
| `storezpaq_multi.sh` | Download compressed sources, decompress, group by date, and build a growing multipart `.zpaq` archive with atomic per-part upload |

---

## Why zpaq?

`zpaqfranz` produces highly compressed, appendable archives. Unlike tar or zip, you can add new files to an existing `.zpaq` archive without re-reading the whole thing. Files already present in the archive are detected and skipped automatically, making repeated runs fully idempotent. Multipart archives extend this by splitting content across a numbered series of part files while preserving full cross-part deduplication.

### Installing zpaqfranz

```bash
# Build from source
wget https://github.com/fcorbelli/zpaqfranz/archive/refs/tags/64.6.tar.gz
tar xzf 64.6.tar.gz && cd zpaqfranz-64.6/NONWINDOWS
make && sudo cp zpaqfranz /usr/local/bin/

# Or on Debian 13+
sudo apt-get install zpaqfranz
```

---

## zpaq_archive.sh — Download Sources & Add to Single-File zpaq Archive

Downloads files from one or more FTP, SFTP, or local sources and stores them inside a single `.zpaq` archive. Files already present in the archive are skipped (idempotent). A `flock`-based exclusive lock prevents concurrent corruption.

### Usage

```
./zpaq_archive.sh [OPTIONS] <archive.zpaq> <source> [<source> ...]

Positional:
  <archive.zpaq>    Target .zpaq archive (created if absent)
  <source> ...      One or more sources:
                      ftp://[user:pass@]host[:port]/path
                      sftp://[user:pass@]host[:port]/path
                      /absolute/or/relative/local/path

Options:
  -c FILE    Config file for credentials    (default: ./transfer.conf)
  -u USER    Username for FTP/SFTP sources
  -p PASS    Password for FTP/SFTP sources
  -t DIR     Staging temp directory         (default: auto mktemp)
  -j N       Parallel download workers      (default: 4)
  -T N       zpaqfranz thread count         (default: 25% of nproc, max 8)
  -v         Verbose / DEBUG output
  -h         Show help

Lock file: <archive>.zpaq.lock
```

### Examples

```bash
# Archive a single FTP directory
./zpaq_archive.sh mybackup.zpaq ftp://ftp.example.com/backups/

# Archive multiple sources from different servers
./zpaq_archive.sh mybackup.zpaq \
    ftp://ftp.example.com/db/ \
    sftp://sftp.example.com/exports/ \
    /local/extra/files/

# Explicit credentials, 8 parallel download workers
./zpaq_archive.sh -u admin -p secret -j 8 mybackup.zpaq ftp://host/data/

# Preserve directory structure: zpaq/daily/backup.zpaq
./zpaq_archive.sh zpaq/daily/backup.zpaq sftp://host/exports/

# Verbose run with custom staging dir
./zpaq_archive.sh -v -t /mnt/fast/stage mybackup.zpaq ftp://host/data/
```

### Subpath Preservation

Internal names inside the archive reflect the source subpath relative to the source root:

```
Source:  ftp://host/slim/vxtl_helium.sql
Archive: slim/vxtl_helium.sql

Source:  ftp://host/db/2025/dump.sql
Archive: db/2025/dump.sql

Source:  /local/extra/report.pdf
Archive: report.pdf
```

For container formats (`.tar.gz`, `.zip`, `.7z`), each member is extracted and added individually, preserving its internal path under the source prefix.

### Supported Source Formats

Files downloaded from FTP/SFTP (or provided as local paths) are handled based on their content type:

| Format | Handling |
|--------|---------|
| `.gz`, `.bz2`, `.xz`, `.zst` | Decompressed transparently; stored without compression wrapper |
| `.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`, `.tar` | Members extracted individually |
| `.zip`, `.7z` | Members extracted individually |
| All others | Stored as-is |

### Execution Model

```
Phase 1 — Parallel downloads (up to -j workers)
  Each source downloads into its own staging subdirectory

Phase 2 — Serial zpaq add queue
  Files are added to the archive one at a time
  (zpaqfranz is not re-entrant on the same archive)
```

The two phases are separated — all downloads complete before zpaqfranz is invoked. This means network I/O and compression are not interleaved on the same CPU.

### Credentials

Priority order for FTP/SFTP sources:
1. Embedded in URL: `ftp://user:pass@host/path`
2. CLI flags: `-u USER -p PASS`
3. Config file: `FTP_USER`/`FTP_PASS` or `SFTP_USER`/`SFTP_PASS` from `transfer.conf`

### Log File

Written to `<archive_dir>/<archive_base>.log`, appended across runs.

---

## storezpaq.sh — Upload Single-File zpaq Archive to SFTP

Uploads a local `.zpaq` archive to SFTP with a full safety workflow: pre-upload integrity test, no-op detection, remote divergence warning, atomic upload with sha256 verification, timestamped backup rotation, and manifest tracking.

### Usage

```
./storezpaq.sh [OPTIONS] <archive.zpaq>

Positional:
  <archive.zpaq>    Local .zpaq archive to upload

Options:
  -c FILE    Config file                         (default: ./transfer.conf)
  -k N       Timestamped backups to keep         (default: 7)
  -t DIR     Temp dir for verification downloads (default: auto mktemp)
  -T N       zpaqfranz thread count              (default: 25% of nproc, max 8)
  -f         Force upload even if archive unchanged
  -v         Verbose / DEBUG output
  -h         Show help

Lock file: <archive>.zpaq.lock
```

### Remote Path Derivation

The remote destination is derived directly from the archive argument — no extra flags needed:

```
Remote path = SFTP_REMOTE_DIR + dirname(<archive.zpaq>)
```

| Command | Remote destination (SFTP_REMOTE_DIR=/ihub-db-backups) |
|---------|-------------------------------------------------------|
| `./storezpaq.sh backup.zpaq` | `/ihub-db-backups/backup.zpaq` |
| `./storezpaq.sh zpaq/daily/backup.zpaq` | `/ihub-db-backups/zpaq/daily/backup.zpaq` |
| `./storezpaq.sh /abs/path/backup.zpaq` | `/ihub-db-backups/backup.zpaq` |

Relative paths carry their directory structure to SFTP automatically. Absolute paths use the basename only (no local directory structure leaks to the remote).

### Examples

```bash
# Upload backup.zpaq to SFTP_REMOTE_DIR/
./storezpaq.sh backup.zpaq

# Upload into a subdirectory (derived from path)
./storezpaq.sh zpaq/daily/backup.zpaq

# Keep 14 timestamped backups instead of 7
./storezpaq.sh -k 14 zpaq/daily/backup.zpaq

# Force upload even if manifest shows no change
./storezpaq.sh -f backup.zpaq

# Verbose run with custom temp dir
./storezpaq.sh -v -t /mnt/fast/tmp backup.zpaq
```

### 5-Step Upload Workflow

```
Step 1 — Integrity test
  zpaqfranz t <archive>
  Aborts immediately if the local archive is corrupt.
  Never upload a broken archive.

Step 2 — No-op check
  Compare local sha256+size against local .manifest.
  Skip upload if archive is unchanged since last run.
  Override with -f.

Step 3 — Remote divergence check
  Download remote .manifest and compare sha256+size.
  Warn (but continue) if remote was modified outside storezpaq.sh.
  The prior remote version will be preserved as a timestamped backup.

Step 4 — Atomic upload
  a. Upload to <base>.zpaq.tmp_upload
  b. Re-download the uploaded file
  c. Verify sha256 matches local file
  d. Rename current live <base>.zpaq → <base>.<YYYYMMDDHHMMSS>.zpaq
     (timestamp from remote manifest = when that version was uploaded)
  e. Rename .tmp_upload → <base>.zpaq
  f. Prune old timestamped backups (keep last -k)

Step 5 — Upload manifest
  Write updated local .manifest, upload to SFTP.
```

### Manifest File

A `.manifest` file is maintained alongside each `.zpaq` archive (locally and on SFTP):

```
# zpaq manifest — managed by storezpaq.sh — do not edit manually
zpaq_file=backup.zpaq
sha256=<hex>
size=<bytes>
uploaded=20250319143022
```

The manifest enables:
- **No-op detection** — skip upload when nothing changed
- **Remote divergence detection** — detect external modifications
- **Backup timestamping** — name backups after their actual upload time (provenance), not the current time

### Timestamped Backup Rotation

Before overwriting the live remote archive, the current version is renamed using the `uploaded=` timestamp from its manifest:

```
/ihub-db-backups/backup.zpaq  →  /ihub-db-backups/backup.20250318120000.zpaq
```

The `-k` flag controls how many timestamped backups are kept (default: 7). Oldest backups beyond the limit are deleted from SFTP automatically.

### Configuration

Uses the same `transfer.conf` as all other scripts. Required variables:

```bash
SFTP_HOST="sftp.example.com"
SFTP_PORT="22"
SFTP_USER="sftp_user"
SFTP_PASS="sftp_password"
SFTP_REMOTE_DIR="/ihub-db-backups"
```

No new config variables are introduced.

### Log File

Written to `<archive_dir>/<archive_base>.log`, appended across runs.

---

## storezpaq_multi.sh — Multipart zpaq Archive from Compressed Sources

Builds and maintains a growing multipart `.zpaq` archive by downloading compressed source files from SFTP, FTP, or local paths, decompressing them, grouping them by date extracted from their filenames, and appending each date group to the archive using `zpaqfranz`. Each new part file is atomically uploaded and sha256-verified before the next group is processed. All parts are retained locally because zpaqfranz requires the complete part set for cross-part deduplication.

This script uses its own config file (`storezpaq.conf`) rather than `transfer.conf`, and its own lock file per archive basename.

### Usage

```
./storezpaq_multi.sh [OPTIONS] <basename> <source> [<source> ...]

Positional:
  <basename>   Archive base name — no extension, no ? characters.
               Parts are named <basename>0000001.zpaq, <basename>0000002.zpaq, etc.
  <source>     One or more SFTP/FTP/local source paths.
               Wildcards are supported if the argument is quoted:
                 'sftp://host/path/*.sql.xz'
                 '/local/data/*.sql.bz2'

Options:
  -c FILE           Config file                       (default: storezpaq.conf)
  -u USER           SFTP username override
  -p PASS           SFTP password override
  -t DIR            Temp/work directory               (default: /tmp/storezpaq_PID)
  -j N              Parallel download workers         (default: 4)
  -T N              zpaqfranz thread count override
  -backfill         Combine all unarchived groups into one zpaqfranz add
  -backfill-days N  Limit backfill to N most recent unarchived days
  -dry-run          Show what would be done; make no changes
  -v                Verbose / DEBUG output
  -h                Show help

Lock file:  <ZPAQ_LOCAL_DIR>/<basename>.zpaq.lock
Log file:   <ZPAQ_LOCAL_DIR>/<basename>_multi.log
```

### Examples

```bash
# Normal mode — one zpaqfranz add per date group, newest to oldest skipped
./storezpaq_multi.sh myarchive sftp://host/backups/'*.sql.xz'

# Multiple sources (mixed formats, mixed servers)
./storezpaq_multi.sh myarchive \
    sftp://host/slim/'*.sql.xz' \
    sftp://host/vxtl/'*.sql.bz2' \
    /local/extra/'*.sql.gz'

# Backfill — all unarchived date groups in one zpaqfranz add
./storezpaq_multi.sh -backfill myarchive sftp://host/backups/'*.sql.xz'

# Backfill limited to the 30 most recent unarchived days
./storezpaq_multi.sh -backfill -backfill-days 30 myarchive sftp://host/backups/'*.sql.xz'

# Dry run — show grouping and space estimates, make no changes
./storezpaq_multi.sh -dry-run myarchive sftp://host/backups/'*.sql.xz'

# Explicit credentials and custom config
./storezpaq_multi.sh -c /etc/zpaq.conf -u admin -p secret myarchive sftp://host/db/'*.sql.xz'

# 8 parallel download workers, verbose
./storezpaq_multi.sh -j 8 -v myarchive sftp://host/backups/'*.sql.xz'
```

### Source Filename Convention

Source filenames must contain a date in the format `_YYYYMMDD.` to be grouped correctly:

```
vxtl_helium_20240113.sql.xz      → date group 20240113
slim_backup_20240114.sql.bz2     → date group 20240114
report_20240114.sql.gz           → date group 20240114 (combined with above)
undated_file.sql.xz              → "undated" group (processed last)
```

Multiple files sharing the same date are combined into a single `zpaqfranz add` in normal mode, and all together in backfill mode.

### Supported Source Formats

| Format | Decompressor | Size Estimation |
|--------|-------------|-----------------|
| `.xz` | `xz -d -T4` | Exact — `xz --list --robot` |
| `.bz2` | `lbzip2` → `pbzip2` → `bzip2` (first found) | Historical ratio from `<basename>.size_history` |
| `.gz` | `pigz` → `gzip` (first found) | `gzip -l` header; wraparound fallback for >4 GB |
| `.zip` | `unzip` | Exact — `unzip -l` |
| `.sql` | passthrough (no decompression) | File size |

Files decompress into `$ZPAQ_TEMP_DIR/` preserving any source subdirectory structure (e.g. `slim/vxtl_helium_20240113.sql`). Collision detection aborts if a decompressed filename already exists in the staging area.

### bz2 Size Estimation

Since bzip2 archives contain no uncompressed-size metadata, `storezpaq_multi.sh` maintains a per-basename history file (`<ZPAQ_LOCAL_DIR>/<basename>.size_history`) recording actual compressed → uncompressed byte counts from previous runs. Space estimates average the last `SIZE_HISTORY_SAMPLES` (default: 5) entries and apply a `SIZE_ESTIMATE_SAFETY_FACTOR` (default: 1.20) safety multiplier. When no history exists, `BZ2_DEFAULT_RATIO` (default: 3.5×) is used.

```
# size history format
# compressed_bytes  uncompressed_bytes  date  pattern
892104832           3012445184          20250320  *.sql.bz2
```

### Normal Mode Pipeline (per date group)

```
1. Download source files for this date group from SFTP/FTP/local
2. Estimate uncompressed size; verify disk space (with ZPAQ_HEADROOM_RATIO headroom)
3. Decompress files into ZPAQ_TEMP_DIR (collision-checked; source .xz/.bz2/.gz deleted after decompress)
4. Check content cache — skip files already in the archive
5. pushd ZPAQ_TEMP_DIR; zpaqfranz a <pattern????> <file list> -fragment N -threads N [flags]
   (falls back to '.' sweep if total argument bytes > ARGMAX_SAFE_THRESHOLD)
6. Identify the newly created part file
7. sha256sum the new part
8. Upload part to SFTP remote_dir/.tmp_upload/<partname>
9. Download part back from SFTP; verify sha256 matches
10. Rename .tmp_upload/<partname> → live <partname> on SFTP
11. Update in-memory manifest; upload manifest to SFTP
12. Update content cache with newly added files
13. Delete decompressed .sql files from ZPAQ_TEMP_DIR
14. Update size history file
```

### Backfill Mode Pipeline

Backfill mode combines all unarchived date groups into a single `zpaqfranz add` for maximum cross-file deduplication. This is the recommended approach for initial population of a new archive or for adding a large batch of historical data.

```
1. Expand all sources and identify all unarchived files across all date groups
2. Optionally limit to the N most recent unarchived days (-backfill-days N)
3. Estimate total uncompressed size; enforce BACKFILL_MIN_FREE_GB floor
   (if not enough space, drop oldest date groups until it fits)
4. Download and decompress all qualifying files into ZPAQ_TEMP_DIR
5. Single zpaqfranz add of all files (pushd ZPAQ_TEMP_DIR; explicit list or '.' sweep)
6. Atomic upload of the single new part; manifest update
7. Cleanup
```

The `BACKFILL_MIN_FREE_GB` config key (default: 100 GB) sets an absolute floor — backfill will never proceed if free disk would fall below this threshold even after dropping date groups.

### Fragment Lock-In

The `-fragment N` value controls zpaqfranz's content-defined chunking block size:

| Fragment | Average chunk size | Use case |
|----------|-------------------|----------|
| 3 | ~8 KB | High deduplication across small SQL deltas (default) |
| 6 | ~64 KB | zpaqfranz default; better for large binary files |
| N | 2^(N+3) KB average | — |

`ZPAQ_FRAGMENT` (default: 3) is written to the multipart manifest on the **first** `zpaqfranz add` and validated against the config on every subsequent run. A mismatch causes an immediate abort. This lock-in is required because changing the fragment size mid-archive defeats cross-part deduplication.

> **Note:** This script never uses `-stdin`, so any fragment value 0–22 is fully supported. The `-stdin` mode in zpaqfranz hard-codes fragment=6 internally and would prevent configuring other values.

### Remote Sync

Before any new content is added, `storezpaq_multi.sh` downloads the remote manifest and compares `total_parts` with the local state:

- **Remote has more parts** — downloads, sha256-verifies, and `zpaqfranz t`-tests any missing parts before proceeding. This handles the case where another host added parts.
- **In sync** — proceeds normally.
- **Local has more parts (upload gap)** — re-uploads any locally-present parts that are absent on SFTP before adding new content.

### ARG_MAX Protection

zpaqfranz is invoked with an explicit list of files rather than shell globbing. When the total byte length of the file list exceeds `ARGMAX_SAFE_THRESHOLD` (default: 131072 bytes, a conservative fraction of the Linux ARG_MAX), the script falls back to a `.` sweep (`zpaqfranz a <pattern> .`) inside `ZPAQ_TEMP_DIR`. This is safe because the temp directory is freshly created per PID and contains only the files intended for this add.

### Multipart Manifest File

A `.zpaq.manifest` file is maintained alongside the part files in `ZPAQ_LOCAL_DIR` (and uploaded to SFTP after each new part):

```
# zpaq multipart manifest — managed by storezpaq_multi.sh — do not edit manually
archive_type=multipart
basename=myarchive
question_mark_count=7
fragment=3
total_parts=4
total_size=12884901888
last_updated=20250320143512

[parts]
myarchive0000001.zpaq   size=3221225472     sha256=<hex>  added=20250318090000
myarchive0000002.zpaq   size=3221225472     sha256=<hex>  added=20250319090000
myarchive0000003.zpaq   size=3221225472     sha256=<hex>  added=20250320090000
myarchive0000004.zpaq   size=3221225472     sha256=<hex>  added=20250320143512
```

Fields:
- `fragment` — locked on first add; mismatches abort all future runs
- `total_parts` — used for remote sync divergence detection
- `total_size` — cumulative uncompressed bytes across all parts
- `[parts]` — per-part sha256, size, and upload timestamp for integrity verification and gap detection

### Configuration

`storezpaq_multi.sh` reads `storezpaq.conf` from the script directory. The config file is **optional** — all keys have built-in defaults. Required variables (no defaults) must be provided via config or CLI flags.

**Required variables (no defaults):**

| Variable | Description |
|----------|-------------|
| `SFTP_HOST` | SFTP server hostname or IP |
| `SFTP_USER` | SFTP username |
| `SFTP_PASS` | SFTP password |
| `SFTP_REMOTE_DIR` | Remote directory for parts and manifest |
| `ZPAQ_LOCAL_DIR` | Local directory where all `.zpaq` parts are stored |

**Optional variables with defaults:**

| Variable | Default | Description |
|----------|---------|-------------|
| `SFTP_PORT` | `22` | SFTP port |
| `ZPAQ_COMPRESSION` | `-m5` | zpaqfranz compression level flag |
| `ZPAQ_EXTRA_FLAGS` | `-ssd` | Additional zpaqfranz flags |
| `ZPAQ_STDINSIZE_HINT` | `true` | When `true`, passes `-stdinsize <N>` to zpaqfranz so the progress bar shows real % completion instead of throughput-only. Requires zpaqfranz >= v64.7 (upstream release, 2026-03-26). Set to `false` if running an older build. |
| `ZPAQ_FRAGMENT` | `3` | CDC fragment exponent (locked per archive on first add) |
| `ZPAQ_MULTIPART_QUESTION_MARKS` | `7` | Number of `?` in archive pattern (supports up to 9,999,999 parts) |
| `XZ_DECOMPRESS_THREADS` | `4` | Thread count for `xz -d -T` |
| `ZPAQ_HEADROOM_RATIO` | `0.30` | Extra free-space fraction required above estimate |
| `BACKFILL_MIN_FREE_GB` | `100` | Absolute free disk floor for backfill (GB) |
| `SIZE_HISTORY_SAMPLES` | `5` | Recent bz2 decompressions to average for estimates |
| `SIZE_ESTIMATE_SAFETY_FACTOR` | `1.20` | Safety multiplier on bz2 size estimates |
| `BZ2_DEFAULT_RATIO` | `3.5` | Fallback bz2 expansion ratio when no history exists |
| `ARGMAX_SAFE_THRESHOLD` | `131072` | Max file-list bytes before `.` sweep fallback |
| `UPLOAD_RETRY_COUNT` | `3` | Per-part upload retry attempts |
| `ZPAQ_LOCAL_SIZE_WARN_GB` | `500` | Warn when local archive set exceeds this size (GB) |
| `LOG_RETENTION_DAYS` | `30` | Days to retain run logs |

### Log File

Written to `<ZPAQ_LOCAL_DIR>/logs/<basename>_multi_YYYYMMDD_HHMMSS.log`, appended across runs.

### Dependencies

```bash
# Required
sudo apt-get install -y zpaqfranz sshpass openssh-client xz-utils

# Recommended (parallel decompressors)
sudo apt-get install -y lbzip2 pigz

# For .zip sources
sudo apt-get install -y unzip

# Fallback bz2 decompressors (used if lbzip2 not found)
sudo apt-get install -y pbzip2
```

---

## Typical Workflows

### Single-file archive (zpaq_archive.sh + storezpaq.sh)

```bash
# 1. Build/update the zpaq archive from all sources
./zpaq_archive.sh zpaq/daily/backup.zpaq \
    ftp://ftp.example.com/db/ \
    sftp://sftp2.example.com/exports/

# 2. Upload to SFTP with integrity check and backup rotation
./storezpaq.sh zpaq/daily/backup.zpaq

# 3. Run both as a cron job
0 3 * * * /opt/ftp-sftp-transfer/zpaq_archive.sh zpaq/daily/backup.zpaq ftp://host/db/ && \
          /opt/ftp-sftp-transfer/storezpaq.sh zpaq/daily/backup.zpaq
```

### Multipart archive (storezpaq_multi.sh)

```bash
# 1. Initial backfill — archive all historical data
./storezpaq_multi.sh -backfill myarchive \
    sftp://host/slim/'*.sql.xz' \
    sftp://host/vxtl/'*.sql.bz2'

# 2. Daily incremental — add only new date groups
./storezpaq_multi.sh myarchive \
    sftp://host/slim/'*.sql.xz' \
    sftp://host/vxtl/'*.sql.bz2'

# 3. Run daily as a cron job
0 4 * * * /opt/ftp-sftp-transfer/storezpaq_multi.sh myarchive \
          sftp://host/slim/'*.sql.xz' sftp://host/vxtl/'*.sql.bz2' \
          >> /opt/ftp-sftp-transfer/logs/multi_cron.log 2>&1
```

---

## Dependencies Summary

```bash
# All zpaq scripts
sudo apt-get install -y zpaqfranz sshpass openssh-client

# zpaq_archive.sh — FTP sources
sudo apt-get install -y lftp

# zpaq_archive.sh — zip/7z container extraction
sudo apt-get install -y unzip p7zip-full

# zpaq_archive.sh — zstd decompression
sudo apt-get install -y zstd

# storezpaq_multi.sh — parallel decompressors (recommended)
sudo apt-get install -y lbzip2 pigz pbzip2 xz-utils unzip
```

---

## src/zpaq/ Module Reference

These modules are designed as a clean, reusable library. Any future script can source them independently.

| Module | Used by | Functions |
|--------|---------|-----------|
| `src/zpaq/zpaq_utils.sh` | all | `detect_zpaqfranz()`, `zpaq_calc_threads()`, `zpaq_file_exists()`, `zpaq_test_archive()` |
| `src/zpaq/zpaq_manifest.sh` | `zpaq_archive.sh`, `storezpaq.sh` | `manifest_path()`, `manifest_write()`, `manifest_read()`, `manifest_compute()`, `manifest_changed()`, `manifest_remote_diverged()` |
| `src/zpaq/zpaq_archive_ops.sh` | `zpaq_archive.sh` | `detect_archive_format()`, `decompress_to_stdout()`, `zpaq_add_stdin()`, `zpaq_add_local_file()`, `zpaq_add_container()`, `zpaq_add_source()` |
| `src/zpaq/zpaq_sftp_ops.sh` | `zpaq_archive.sh`, `storezpaq.sh` | `zpaq_sftp_upload_workflow()`, `zpaq_sftp_download_manifest()`, `zpaq_sftp_upload_manifest()`, `zpaq_sftp_prune_backups()` |
| `src/zpaq/zpaq_multipart_manifest.sh` | `storezpaq_multi.sh` | `multipart_manifest_path()`, `multipart_manifest_read()`, `multipart_manifest_write()`, `multipart_manifest_add_part()`, `multipart_manifest_part_known()`, `multipart_manifest_get_fragment()`, `multipart_manifest_check_fragment()`, `multipart_manifest_remote_diverged()` |
| `src/zpaq/zpaq_multipart_ops.sh` | `storezpaq_multi.sh` | `zpaq_multipart_build_cache()`, `zpaq_multipart_file_known()`, `zpaq_multipart_add()`, `zpaq_multipart_upload_part()`, `zpaq_multipart_upload_manifest()`, `zpaq_multipart_download_manifest()`, `zpaq_multipart_remote_sync()`, `check_archive_format_conflict()` |
| `src/zpaq/zpaq_grouping.sh` | `storezpaq_multi.sh` | `detect_decompressor()`, `extract_date_from_filename()`, `group_files_by_date()`, `expand_sftp_wildcard()`, `expand_local_wildcard()`, `xz_list_uncompressed_size()`, `gz_list_uncompressed_size()`, `zip_list_uncompressed_size()`, `bz2_estimate_uncompressed_size()`, `estimate_group_uncompressed_size()`, `update_size_history()`, `check_space()`, `check_filename_collision()`, `decompress_file()` |

All modules require `src/core/logging.sh` to be sourced first (they use `log()`). `zpaq_sftp_ops.sh` and `zpaq_multipart_ops.sh` additionally require `SFTP_HOST`, `SFTP_PORT`, `SFTP_USER`, `SFTP_PASS` to be set.