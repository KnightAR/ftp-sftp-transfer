# zpaq Scripts — Super Archive & SFTP Storage

Two scripts for building and storing `.zpaq` super-archives — single files that accumulate content from multiple FTP, SFTP, or local sources over time, with full SFTP upload safety and disaster recovery.

| Script | Purpose |
|--------|---------|
| `zpaq_archive.sh` | Download sources → add files to a `.zpaq` archive |
| `storezpaq.sh` | Upload a `.zpaq` archive to SFTP with integrity checking and backup rotation |

---

## Why zpaq?

`zpaqfranz` produces highly compressed, appendable archives. Unlike tar or zip, you can add new files to an existing `.zpaq` archive without re-reading the whole thing. Files already present in the archive are detected and skipped automatically, making repeated runs fully idempotent.

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

## zpaq_archive.sh — Download Sources & Add to zpaq Archive

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

## storezpaq.sh — Upload zpaq Archive to SFTP

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

## Typical Workflow

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

---

## Dependencies

```bash
# zpaqfranz — build from source or install from apt (Debian 13+)
sudo apt-get install zpaqfranz   # Debian 13+

# For FTP sources
sudo apt-get install -y lftp

# For SFTP sources
sudo apt-get install -y sshpass openssh-client

# For zip/7z container extraction
sudo apt-get install -y unzip p7zip-full

# For zstd decompression
sudo apt-get install -y zstd
```

---

## src/zpaq/ Module Reference

These modules are designed as a clean, reusable library. Any future script can source them independently.

| Module | Functions |
|--------|-----------|
| `src/zpaq/zpaq_utils.sh` | `detect_zpaqfranz()`, `zpaq_file_exists()`, `zpaq_test_archive()` |
| `src/zpaq/zpaq_manifest.sh` | `manifest_path()`, `manifest_write()`, `manifest_read()`, `manifest_compute()`, `manifest_changed()`, `manifest_remote_diverged()` |
| `src/zpaq/zpaq_archive_ops.sh` | `detect_archive_format()`, `decompress_to_stdout()`, `zpaq_add_stdin()`, `zpaq_add_local_file()`, `zpaq_add_container()`, `zpaq_add_source()` |
| `src/zpaq/zpaq_sftp_ops.sh` | `zpaq_sftp_upload_workflow()`, `zpaq_sftp_download_manifest()`, `zpaq_sftp_upload_manifest()`, `zpaq_sftp_prune_backups()` |

All modules require `src/core/logging.sh` to be sourced first (they use `log()`). `zpaq_sftp_ops.sh` additionally requires `SFTP_HOST`, `SFTP_PORT`, `SFTP_USER`, `SFTP_PASS` to be set.