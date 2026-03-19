# src/ Module Reference

All top-level scripts source modules from `src/` rather than duplicating logic. Modules are designed to be sourced in dependency order — each group depends only on groups listed above it.

---

## Dependency Order

```
src/core/          ← no dependencies (source first)
src/system/        ← depends on core
src/transfer/      ← depends on core + system
src/compress/      ← depends on core only (TEMP_DIR from config)
src/split/         ← depends on core + system + transfer
src/zpaq/          ← depends on core + system
src/workers/       ← depends on core + system + transfer
src/pipeline/      ← depends on everything above
```

---

## src/core/

Foundation modules. Must be sourced before everything else.

### constants.sh
Declares every global variable used across the project. No functions — pure declarations and safe defaults. Sets `SCRIPT_NAME`, `SCRIPT_VERSION`, `DEFAULT_CONFIG`, `LOCK_FILE`, `LOCK_FD`, `LOG_FILE`, `ERROR_LOG_FILE`, worker PID arrays, and all `CNT_*` counters.

### args.sh
Parses CLI flags for `transfer.sh` (`-c`, `-e`, `-t`, `-d`, `-n`, `-f`, `-s`, `-v`, `-V`, `-h`) into `CLI_*` variables. Sets `CLI_VERBOSE`, `CLI_DRY_RUN`, `CLI_NO_DELETE`, etc.

### config.sh
Provides `load_config()` and `validate_config()`. Sources the config file, applies CLI overrides, sets defaults for all optional variables, and validates required variables and numeric ranges. Warns if the config file has open permissions.

### logging.sh
Provides `log LEVEL MESSAGE`. Writes atomically to `LOG_FILE` (and `ERROR_LOG_FILE` for ERROR-level events) using `flock`. DEBUG lines are written to log only when `CLI_VERBOSE=true`. Functions called inside `$(...)` must write directly to `${LOG_FILE}` — never call `log()` from a subshell used for capture.

---

## src/system/

System-level lifecycle management. Depends on core.

### lock.sh
Provides `acquire_lock()` and `release_lock()`. Uses `flock -n` on `LOCK_FILE` via `LOCK_FD` (file descriptor). The lock is OS-held — automatically released if the process dies without calling `release_lock()`. Writes the current PID into the lock file for operator inspection.

### temp.sh
Provides `setup_temp_dir()` and `cleanup_temp()`. Creates a `mktemp -d` staging area (or validates a custom path), builds all queue files and atomic counter files for the worker pipeline, and tears down only the files this script created (preserving custom directories).

### dependencies.sh
Checks for required binaries (`lftp`, `sshpass`, `sftp`). Offers to auto-install via `apt-get` when run interactively; prints install command and exits when run non-interactively (cron).

### trap.sh
Defines `trap_cleanup()` and registers it for `INT`, `TERM`, and `EXIT`. Sends `SIGTERM` to all tracked `WORKER_PIDS`, waits up to 5 seconds, force-kills survivors, then calls `cleanup_temp()`, `cleanup_job_dir()`, and `release_lock()`. The trap is removed at the end of a clean run to prevent double-cleanup.

---

## src/transfer/

FTP and SFTP I/O. Depends on core + system.

### ftp.sh
Provides `setup_ftp_connection()`, `run_lftp()`, and `get_ftp_file_list()`. Assembles the `FTP_CONNECT_STR` lftp settings prefix (TLS disabled), tests connectivity, and performs a two-pass recursive file listing (mirror dry-run for paths + per-directory `ls` for size/mtime).

### sftp.sh
Provides all SFTP server I/O for `transfer.sh`:
- `sftp_get_size()` — queries file size via `ls -l`, anchored to exact basename (avoids wrong-size bug on directory-listing servers)
- `sftp_get_size_retry()` — retries up to `MAX_TRIES` times for object-storage backends
- `sftp_mkdir_p()` — recursive remote directory creation via batch `-mkdir` commands
- `sftp_download_verify()` — re-downloads to `.verify` temp file and compares sha256
- `sftp_delete_file()` — removes a single remote file

All functions use `SSHPASS="${SFTP_PASS}" sshpass -e sftp -b <(printf '...')` batch mode.

### ftp_download.sh
Provides `ftp_parse_url()`, `ftp_download_path()`, and `ftp_download_url()` for `zpaq_archive.sh`. Parses `ftp://` URLs, downloads single files or directory trees via `lftp mirror`, and populates `FTP_DOWNLOADED_FILES[]` with local paths. Credentials are passed explicitly — never embedded in lftp command strings.

### sftp_download.sh
Provides `sftp_dl_parse_url()`, `sftp_download_path()`, and `sftp_download_url()` for `zpaq_archive.sh`. Parses `sftp://` URLs, performs recursive BFS directory listing via `sshpass+sftp ls -l`, downloads each file individually, and populates `SFTP_DOWNLOADED_FILES[]` with local paths.

### exclusions.sh
Loads and applies the `exclude.list` file. Provides `is_excluded FILENAME` — returns 0 if the basename matches any glob pattern in the list.

### archive_verify.sh
Provides `verify_archive_integrity FILE` — runs format-appropriate integrity checks (e.g. `bzip2 -t`, `gzip -t`, `xz -t`) on downloaded files before further processing. Controlled by `VERIFY_ARCHIVE_INTEGRITY=true` in config.

### reupload.sh
Provides `load_reupload_log()`, `is_flagged_for_reupload()`, `flag_for_reupload()`, and `clear_reupload_flag()`. Manages `reupload.log` — a persistent plain-text file tracking FTP paths that must be force-re-uploaded due to a previous checksum failure.

### ftp_delete.sh
Provides `delete_from_ftp FTP_PATH FTP_MTIME` — applies the `RETENTION_DAYS` policy and deletes old files from FTP via `lftp`. Only called after a file has been confirmed uploaded and verified in the current run.

---

## src/compress/

Shared compression utilities. Depends on core only.

### compress_utils.sh
Shared module sourced by both `recompress.sh` and `strip_archive.sh`. Provides:
- `detect_compression_tools()` — verifies `xz`, `pbzip2`/`bzip2`, `gzip`, `unzip`, `7z`, `bsdtar` are available
- `load_temp_dir()` — sources `transfer.conf` (if present) to get `TEMP_DIR`, falls back to `/tmp`
- `xz_compress INPUT OUTPUT` — runs `xz` with `OPT_XZ_LEVEL`, `OPT_XZ_EXTREME`, `OPT_XZ_THREADS`
- Common option variable declarations (`OPT_XZ_LEVEL`, `OPT_XZ_THREADS`, `OPT_VERBOSE`, `OPT_CONFIG`)

---

## src/split/

Large-file split/restore pipeline. Depends on core + system + transfer.

### split_args.sh
Parses CLI arguments for `split_transfer.sh`. Sets `SPLIT_FTP_PATH`, `SPLIT_PART_SIZE`, `SPLIT_WORKERS`, and other `SPLIT_*` variables.

### split_upload_args.sh
Parses CLI arguments for `split_upload.sh`. Sets `SPLIT_SOURCE_FILE`, `SPLIT_REMOTE_SUBPATH`, and other `SPLIT_*` variables.

### restore_args.sh
Parses CLI arguments for `split_restore.sh`. Sets `RESTORE_MANIFEST_PATH`, `RESTORE_OUTPUT`, `RESTORE_WORKERS`, `RESTORE_VERIFY_ONLY`.

### split_config.sh
Validates split-specific config variables and computes derived values (e.g. resolved SFTP remote path, staging subdirectory layout).

### split_manifest.sh
Provides `write_split_manifest()` and `parse_split_manifest()`. The manifest format records `original_sha256`, `original_size`, `part_size`, `part_count`, and per-part `sha256`+`size` for every part. Used by both upload scripts (write) and `split_restore.sh` (read).

### split_ops.sh
Provides the core split pipeline operations: concurrent sha256+split, per-part hash collection, and the staged-original deletion after split completes.

### split_worker.sh
Provides `split_upload_worker()` — uploads a single part to SFTP, verifies its size, and marks it `UPLOADED` or `FAILED` in the worker result file.

### restore_worker.sh
Provides `restore_download_worker()` — downloads assigned parts from SFTP, verifies per-part sha256, and marks them ready for the commit thread.

### restore_commit.sh
Provides `restore_commit_thread()` — runs as a background process alongside download workers, streaming completed parts into the output file in strict order to minimise peak disk usage.

---

## src/zpaq/

zpaqfranz utilities. Depends on core only (plus SFTP credentials for `zpaq_sftp_ops.sh`). Designed as a clean reusable library — any future script can source individual modules independently.

### zpaq_utils.sh
- `detect_zpaqfranz()` — locates `zpaqfranz` on PATH, sets `ZPAQFRANZ_BIN`. Exits with install hint if not found.
- `zpaq_calc_threads [N]` — calculates the thread count for zpaqfranz and sets `ZPAQFRANZ_THREADS`. With no argument: 25% of `nproc`, minimum 1, maximum 8. With an explicit N > 0: uses N directly. All zpaqfranz invocations read `ZPAQFRANZ_THREADS` automatically.
- `zpaq_file_exists ARCHIVE INTERNAL_NAME` — returns 0 if the internal name is already in the archive (uses `zpaqfranz l | grep -F "+ NAME"`).
- `zpaq_test_archive ARCHIVE` — runs `zpaqfranz t -threads N`, streams output to log at DEBUG level. Returns 0 on success.

### zpaq_manifest.sh
Manages `.manifest` files co-located with `.zpaq` archives:
- `manifest_path ZPAQ_FILE` — echoes the expected `.manifest` path
- `manifest_write ZPAQ_FILE SHA256 SIZE UPLOADED` — atomic write via tmp+mv
- `manifest_read MANIFEST_FILE` — parses key=value into `MANIFEST_*` variables
- `manifest_compute ZPAQ_FILE` — computes sha256+size into `COMPUTED_*` variables
- `manifest_changed ZPAQ_FILE` — returns 0 if archive changed since last manifest write
- `manifest_remote_diverged LOCAL REMOTE` — returns 0 if remote manifest differs from local

### zpaq_archive_ops.sh
Handles the per-file processing pipeline for `zpaq_archive.sh`:
- `detect_archive_format FILEPATH` — identifies format by magic bytes (`file -b`), sets `ARCHIVE_FORMAT`
- `decompress_to_stdout FILEPATH FORMAT` — streams decompressed content to stdout (gz/bz2/xz/zst/plain)
- `zpaq_add_stdin ARCHIVE INTERNAL_NAME` — reads stdin, adds to archive via `zpaqfranz a ... -stdin -m5 -ssd`
- `zpaq_add_local_file ARCHIVE INTERNAL_NAME LOCAL_FILE` — pipes a file through `zpaq_add_stdin`
- `zpaq_add_container ARCHIVE PREFIX FILEPATH FORMAT TEMP_DIR` — extracts multi-member containers (tar, zip, 7z) and adds each member individually
- `zpaq_add_source ARCHIVE PREFIX FILEPATH` — top-level dispatcher; detects format and routes to the correct add function

### zpaq_sftp_ops.sh
Full SFTP upload workflow for `storezpaq.sh`:
- `zpaq_sftp_upload_workflow ZPAQ_FILE REMOTE_DIR KEEP TEMP_DIR` — complete 5-step upload pipeline
- `zpaq_sftp_download_manifest REMOTE_DIR ZPAQ_FILE LOCAL_DEST` — downloads remote `.manifest`
- `zpaq_sftp_upload_manifest ZPAQ_FILE REMOTE_DIR` — uploads local `.manifest` to SFTP
- `zpaq_sftp_prune_backups REMOTE_DIR BASE KEEP` — lists and removes oldest timestamped backups beyond the keep limit

---

## src/workers/

Parallel pipeline workers for `transfer.sh`. Depends on core + system + transfer.

### counters.sh
Provides atomic read/increment/decrement operations on shared counter files using `flock`. Used by workers to track in-flight bytes, active downloader/uploader counts, and idle state without race conditions.

### disk_guard.sh
Provides `wait_for_disk_space FILE_SIZE`. Computes usable staging space as `available - in_flight_reserved - buffer` and blocks until enough space is free or `DISK_WAIT_TIMEOUT` is reached. Exits immediately if no other workers are active (nothing can free space).

### download_worker.sh
Implements one FTP download worker. Pops entries from `work_queue.txt`, applies transfer decision logic (skip/overwrite/download), downloads from FTP, verifies size, and pushes to `ready_queue.txt`.

### upload_worker.sh
Implements one SFTP upload worker. Pops entries from `ready_queue.txt`, uploads to SFTP, verifies size (with retry), verifies sha256, manages `reupload.log`, and pushes confirmed entries to `confirmed_queue.txt`.

---

## src/pipeline/

Orchestration for `transfer.sh`. Depends on everything above.

### pipeline.sh
Provides `run_pipeline()`. Populates the work queue, spawns all download and upload workers as background processes, tracks their PIDs in `WORKER_PIDS[]`, and waits for completion.

### deletion_stage.sh
Provides `run_deletion_stage()`. Reads `confirmed_queue.txt` and applies `RETENTION_DAYS` FTP deletion policy to confirmed files.

### summary.sh
Provides `print_summary()`. Merges per-worker result files into `CNT_*` globals and prints the formatted summary box.

### main.sh
Defines `main()` for `transfer.sh`. Orchestrates the full run: parse args → load config → setup logging → acquire lock → check dependencies → setup staging → connect FTP → list files → run pipeline → run deletion → print summary → clean shutdown.