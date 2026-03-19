# Compression Scripts — Recompress & Strip Archives

Two scripts for local archive manipulation. Both use shared compression utilities from `src/compress/compress_utils.sh` and read `transfer.conf` for `TEMP_DIR`.

| Script | Purpose |
|--------|---------|
| `recompress.sh` | Recompress `.bz2`, `.gz`, `.zip`, `.7z` archives to `.xz` |
| `strip_archive.sh` | Remove directories from a compressed tar archive |

---

## recompress.sh — Recompress Archives to XZ

Recompresses supported archive formats to `.xz`, staging output in `TEMP_DIR` before moving the result to the same directory as the source. XZ files are skipped automatically.

### Supported Input Formats

| Format | Decompressor |
|--------|-------------|
| `.bz2` / `.tar.bz2` | `pbzip2` (preferred) or `bzip2` |
| `.gz` / `.tar.gz` | `gzip` |
| `.zip` | `unzip` (or `7z` fallback) |
| `.7z` | `7z` |
| `.xz` / `.tar.xz` | Skipped |

### Usage

```
./recompress.sh <file|dir> [OPTIONS]

Positional:
  file|dir        File or directory to recompress

Options:
  -o              Overwrite existing .xz output (default: skip if exists)
  -r              Recursive directory scan      (default: flat)
  -d              Delete original after successful recompression
  -t              Force tar wrapping for multi-file zip/7z archives
  -l <1-9>        XZ compression level         (default: 9)
  -E              Disable --extreme             (default: on at level 9)
  -T <n>          XZ thread count              (default: 32, capped at nproc-1)
  -v              Verbose mode
  -c <file>       Config file override         (default: ./transfer.conf)
  -h              Help
```

### Examples

```bash
# Recompress a single bzip2 file to xz
./recompress.sh /backups/dump.sql.bz2

# Recompress all archives in a directory, overwrite existing outputs
./recompress.sh /backups/ -r -o

# Delete originals after successful recompression, level 6
./recompress.sh /backups/ -r -d -l 6

# Disable extreme flag and use 8 threads
./recompress.sh dump.tar.gz -E -T 8

# Force tar wrapping for a zip archive with multiple members
./recompress.sh archive.zip -t
```

### Behaviour

- Output is always written to `TEMP_DIR` first, then moved to the source directory on success. A partial output in `TEMP_DIR` is cleaned up on failure.
- Multi-file `.zip` and `.7z` archives contain multiple members. Without `-t` these are skipped with a warning. With `-t`, the members are extracted and wrapped in a tar before XZ compression.
- When `-r` is set, all supported archives in the directory are processed. Unsupported formats and XZ files are counted but skipped silently.

### Output Naming

| Input | Output |
|-------|--------|
| `dump.sql.bz2` | `dump.sql.xz` |
| `backup.tar.gz` | `backup.tar.xz` |
| `archive.zip` | `archive.zip.xz` (or `archive.tar.xz` with `-t`) |

---

## strip_archive.sh — Strip Directories from Compressed Tar Archives

Decompresses a compressed tar archive to a raw `.tar` in `TEMP_DIR`, removes the specified directories using `tar --delete`, then recompresses to `.tar.xz`.

Requires `bsdtar` (libarchive) for clean block reclamation after `tar --delete`:

```bash
sudo apt-get install -y libarchive-tools
```

### Supported Input Formats

`.tar.bz2`, `.tar.gz`, `.tar.xz`, `.tgz`, `.tbz2`, `.txz`

### Usage

```
./strip_archive.sh <archive> [dirs] [OPTIONS]

Positional:
  archive             Input archive file (required)
  dirs                Comma-separated directories to remove
                        (required unless -C)

Options:
  -o <file>       Output path
                    (default: <basename>-stripped.tar.xz, same dir as input)
  -p <prefix>     Path prefix to prepend to each directory  (default: none)
  -d              Delete original archive after successful output
  -O              Overwrite existing output file (clobber)
  -C              Continue/compress-only — skip tar --delete step
  -l <1-9>        XZ compression level  (default: 9)
  -E              Disable --extreme     (default: on at level 9)
  -T <n>          XZ thread count      (default: nproc-1, min 1)
  -v              Verbose mode
  -c <file>       Config file          (default: ./transfer.conf)
  -h              Help
```

### Examples

```bash
# Remove the 'logs' directory from an archive
./strip_archive.sh backup.tar.bz2 logs

# Remove multiple directories
./strip_archive.sh backup.tar.bz2 logs,tmp,cache

# Remove with a path prefix (e.g. if dirs are stored as ./logs inside the tar)
./strip_archive.sh backup.tar.bz2 logs -p "./"

# Custom output path, delete original on success
./strip_archive.sh backup.tar.bz2 logs -o /out/backup-clean.tar.xz -d

# Skip tar --delete and just recompress a staged .tar (resume after partial run)
./strip_archive.sh backup.tar.bz2 -C

# Clobber existing output, level 6 compression
./strip_archive.sh backup.tar.bz2 logs -O -l 6
```

### Resume Support

If a staging `.tar` already exists in `TEMP_DIR` for the given archive (from a previous interrupted run), the decompression step is skipped automatically. Use `-C` to explicitly skip `tar --delete` and go straight to recompression — useful when the `.tar` was already stripped manually.

### Staging Flow

```
1. Decompress input → TEMP_DIR/<basename>.tar
2. tar --delete listed directories from staged .tar
3. bsdtar repack (block reclamation)
4. xz compress → TEMP_DIR/<basename>.tar.xz
5. Move output to destination
6. Optionally delete original
```

The original archive is never modified. All intermediate work happens in `TEMP_DIR`.

---

## Shared Module: src/compress/compress_utils.sh

Both scripts source `src/compress/compress_utils.sh`, which provides:

- `detect_compression_tools` — checks for `xz`, `pbzip2`/`bzip2`, `gzip`, `unzip`, `7z`, `bsdtar`
- `load_temp_dir` — sources `transfer.conf` to get `TEMP_DIR`, or uses `/tmp` as fallback
- `xz_compress FILE OUTPUT` — runs `xz` with the configured level, extreme flag, and thread count
- Common option variable declarations consumed by both scripts (`OPT_XZ_LEVEL`, `OPT_XZ_THREADS`, etc.)

This module can be sourced by future compression scripts to pick up the same tool detection and XZ invocation logic without duplication.