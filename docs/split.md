# Split Scripts — Large-File Split Transfer & Restore

Three scripts work together to handle files too large to transfer or store as a single unit:

| Script | Purpose |
|--------|---------|
| `split_transfer.sh` | Download from FTP → split → upload parts to SFTP |
| `split_upload.sh` | Split a local file → upload parts to SFTP |
| `split_restore.sh` | Download parts from SFTP → reassemble → verify |

All three share the same `transfer.conf`, `src/core/`, `src/system/`, and `src/split/` modules.

---

## split_transfer.sh — FTP Download → Split → SFTP Upload

Downloads a single large file from the FTP server, splits it into fixed-size parts, computes per-part sha256 hashes, uploads all parts in parallel to SFTP, and writes a manifest file so `split_restore.sh` can later reconstruct and verify the original.

### Usage

```
./split_transfer.sh <ftp_path> [OPTIONS]

Positional:
  ftp_path        FTP path of the file to transfer (required)

Options:
  -c CONFIG       Config file path          (default: transfer.conf)
  -s SIZE         Part size, e.g. 500m, 2g (default: 1g)
  -p WORKERS      Parallel upload workers  (default: 10)
  -t TEMP_DIR     Override temp directory
  -n              No delete — keep original FTP file after split
  -v              Verbose / debug logging
  -h              Show help
```

### Examples

```bash
# Split a 100 GB dump into 1 GB parts and upload
./split_transfer.sh /backups/dump_20250101.sql.bz2

# Use 500 MB parts, 4 upload workers, keep original on FTP
./split_transfer.sh /backups/dump_20250101.sql.bz2 -s 500m -p 4 -n

# Verbose run with custom staging dir
./split_transfer.sh /backups/dump.sql.bz2 -v -t /mnt/fast/staging
```

### Pipeline

```
1. Load config + validate
2. Check dependencies (lftp, sshpass, split, sha256sum)
3. Download file from FTP → local staging
4. Concurrent: sha256sum + gnu split (both read sequentially, both finish before proceeding)
5. Collect per-part sizes and sha256 hashes
6. Write manifest to staging
7. Delete staged original (reclaim disk)
8. Upload manifest to SFTP
9. Upload parts in parallel
10. Verify all parts uploaded (none FAILED)
11. Optionally delete original from FTP (unless -n)
12. Print summary
```

### Disk Usage

```
During split:  original_file + all parts  ≈ 2× file size
After split:   parts only                 ≈ 1× file size
(Original deleted from staging immediately after split+sha256 complete)
```

### SFTP Layout Produced

```
<original_ftp_dir>/
  <filename>.manifest
  split/
    <filename>.part.00001
    <filename>.part.00002
    ...
```

---

## split_upload.sh — Local File → Split → SFTP Upload

Like `split_transfer.sh` but the source file already exists locally — no FTP download is performed. The source file is read in-place (not copied to staging), so no extra disk space is needed beyond the split parts.

### Usage

```
./split_upload.sh <source_file> [OPTIONS]

Positional:
  source_file     Local file to split and upload (required)

Options:
  -r PATH         Remote SFTP subpath relative to SFTP_REMOTE_DIR
                    Example: -r /zpaq/daily stores under SFTP_REMOTE_DIR/zpaq/daily/
                    (default: / — stored at SFTP_REMOTE_DIR root)
  -s SIZE         Part size override (split -b syntax, e.g. 500m, 2g)
  -p N            Parallel upload workers
  -t DIR          Staging temp dir override
  -d              Delete source file after successful upload + verification
  -c FILE         Config file override
  -v              Verbose / DEBUG output
  -h              Help
```

### Examples

```bash
# Upload a local archive, store at SFTP_REMOTE_DIR root
./split_upload.sh /data/bigdump.sql.bz2

# Upload into a subdirectory on SFTP
./split_upload.sh /data/bigdump.sql.bz2 -r /db/2025

# Upload and delete source after verified upload
./split_upload.sh /data/bigdump.sql.bz2 -d

# 500 MB parts, 4 workers, verbose
./split_upload.sh /data/bigdump.sql.bz2 -s 500m -p 4 -v
```

### Resume Behaviour

| State | Action |
|-------|--------|
| Manifest + parts in staging | Skip split, resume upload |
| Parts dir empty, job dir exists | Re-run split, then upload |
| Nothing staged | Full run from scratch |

### SFTP Layout Produced

```
SFTP_REMOTE_DIR<remote_path>/
  <filename>.manifest
  split/
    <filename>.part.00001
    <filename>.part.00002
    ...
```

---

## split_restore.sh — SFTP Parts → Reassemble → Verify

Downloads all parts of a split file from SFTP, streams them into the reassembled output file in strict part order (minimising peak disk usage), then verifies the final sha256 against the manifest.

### Usage

```
./split_restore.sh <manifest_path> [OPTIONS]

Positional:
  manifest_path   SFTP path of the .manifest file (required)

Options:
  -o OUTPUT       Local path to write the reassembled file
                    (required unless -V / --verify-only)
  -c CONFIG       Config file path          (default: transfer.conf)
  -p WORKERS      Parallel download workers (default: 10)
  -t TEMP_DIR     Override temp directory
  -V              Verify-only — download + sha256 check all parts
                    without assembling output file
  -v              Verbose / debug logging
  -h              Show help
```

### Examples

```bash
# Restore a split archive to /data/restored.sql.bz2
./split_restore.sh /ihub-db-backups/split/dump.sql.bz2.manifest \
    -o /data/restored.sql.bz2

# Verify all parts on SFTP are intact (no output written)
./split_restore.sh /ihub-db-backups/split/dump.sql.bz2.manifest -V

# Restore with 4 parallel download workers
./split_restore.sh /ihub-db-backups/split/dump.sql.bz2.manifest \
    -o /data/restored.sql.bz2 -p 4
```

### Pipeline

```
1. Load config + validate
2. Check dependencies (sshpass, sha256sum, stat)
3. Download manifest from SFTP and parse it
4. Build restore_part_queue.txt (all part filenames in strict order)
5. Create parts staging directory
6. Start commit thread (background) — streams completed parts into output file in order
7. Spawn N download workers in parallel
8. Wait for all download workers to finish
9. Wait for commit thread to finish
10. Verify final output sha256 against MANIFEST_ORIGINAL_SHA256
11. Print summary
```

### Disk Usage (Streaming Benefit)

The commit thread streams parts into the output file as they are downloaded in order — it does not wait for all parts to land before assembling.

```
Peak ≈ output_file_growing + (workers × part_size)

Example: 140 GB file, 1 GB parts, 4 workers → peak ≈ 144 GB
Naive:   all parts + output                  → peak ≈ 280 GB
```

### Verify-Only Mode (`-V`)

Downloads and sha256-checks every part without writing any output. Use this to verify SFTP storage integrity after `split_transfer.sh` or `split_upload.sh` without needing local disk space for the full reassembled file.

---

## Manifest Format

Both upload scripts produce a `.manifest` file stored alongside the parts on SFTP:

```
# split manifest — managed by split_transfer.sh / split_upload.sh
original_file=dump.sql.bz2
original_sha256=<hex>
original_size=<bytes>
part_size=1073741824
part_count=47
part_00001_file=dump.sql.bz2.part.00001
part_00001_sha256=<hex>
part_00001_size=1073741824
part_00002_file=dump.sql.bz2.part.00002
...
```

`split_restore.sh` reads this manifest to determine download order, expected sizes, and per-part checksums before assembling the final file.

---

## Dependencies

```bash
sudo apt-get install -y lftp sshpass openssh-client coreutils
# split and sha256sum are part of coreutils
```

---

## Configuration

Uses the same `transfer.conf` as `transfer.sh`. All SFTP variables (`SFTP_HOST`, `SFTP_PORT`, `SFTP_USER`, `SFTP_PASS`, `SFTP_REMOTE_DIR`) are required. FTP variables are only required by `split_transfer.sh`.

See the [main configuration reference](transfer.md#configuration) for the full variable list.