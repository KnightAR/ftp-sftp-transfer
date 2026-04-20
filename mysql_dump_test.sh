#!/usr/bin/env bash
# ============================================================
# mysql_dump_test.sh — Connection & Credentials Test
#
# Validates that all external dependencies are reachable and
# correctly configured before running mysql_dump_zpaq.sh.
#
# Tests performed:
#   MySQL:
#     1. mysqladmin ping      — basic TCP + auth reachability
#     2. SHOW DATABASES       — SELECT privilege check
#     3. SELECT on mysql.user — SHOW GRANTS / backup privilege check
#
#   S3 / mc:
#     4. mc alias set         — credential + endpoint validation
#     5. mc ls bucket         — bucket exists and is accessible
#     6. mc put probe object  — write permission
#     7. mc stat probe object — read-back / object visibility
#     8. mc rm probe object   — delete permission (non-fatal if denied)
#
# Usage (inside container):
#   ./mysql_dump_test.sh
#   ./mysql_dump_test.sh -c /path/to/mysql_dump.conf
#   ./mysql_dump_test.sh -v          # verbose mc/mysql output
#
# All config is read from environment variables (same as the main
# script) or from an optional config file passed with -c.
#
# Exit codes:
#   0  — all required tests passed
#   1  — one or more required tests failed
# ============================================================

set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ============================================================
# Colour / formatting helpers
# ============================================================
_tput() { command -v tput &>/dev/null && tput "$@" 2>/dev/null || true; }
_BOLD="$(_tput bold)"
_GREEN="$(_tput setaf 2)"
_RED="$(_tput setaf 1)"
_YELLOW="$(_tput setaf 3)"
_CYAN="$(_tput setaf 6)"
_RESET="$(_tput sgr0)"

_pass()  { printf "  ${_GREEN}✔${_RESET}  %s\n" "$*"; }
_fail()  { printf "  ${_RED}✘${_RESET}  %s\n" "$*"; }
_warn()  { printf "  ${_YELLOW}⚠${_RESET}  %s\n" "$*"; }
_info()  { printf "  ${_CYAN}·${_RESET}  %s\n" "$*"; }
_head()  { printf "\n${_BOLD}%s${_RESET}\n" "$*"; }
_sep()   { printf '%s\n' "────────────────────────────────────────────────────────"; }

# ============================================================
# Result tracking
# ============================================================
RESULTS=()          # "PASS|label", "FAIL|label", "WARN|label", "SKIP|label"
FAIL_COUNT=0
WARN_COUNT=0

_record() {
    local status="$1"   # PASS FAIL WARN SKIP
    local label="$2"
    RESULTS+=("${status}|${label}")
    case "${status}" in
        FAIL) (( FAIL_COUNT++ )) || true ;;
        WARN) (( WARN_COUNT++ )) || true ;;
    esac
}

# ============================================================
# CLI parsing
# ============================================================
OPT_CONFIG=""
OPT_VERBOSE=false

_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

  -c FILE   Config file path (default: mysql_dump.conf in same directory)
  -v        Verbose — show raw command output
  -h        Show this help

All configuration is read from environment variables (same names as
mysql_dump_zpaq.sh). A config file is used as fallback if set.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c)  OPT_CONFIG="$2"; shift 2 ;;
        -v)  OPT_VERBOSE=true; shift ;;
        -h)  _usage; exit 0 ;;
        *)   echo "Unknown option: $1" >&2; _usage >&2; exit 1 ;;
    esac
done

# ============================================================
# Load config file (env vars take precedence)
# ============================================================
_load_config() {
    local cfg=""

    if [[ -n "${OPT_CONFIG}" ]]; then
        cfg="${OPT_CONFIG}"
    elif [[ -f "${SCRIPT_DIR}/mysql_dump.conf" ]]; then
        cfg="${SCRIPT_DIR}/mysql_dump.conf"
    fi

    if [[ -n "${cfg}" ]]; then
        if [[ ! -f "${cfg}" ]]; then
            echo "ERROR: config file not found: ${cfg}" >&2
            exit 1
        fi
        # Source config — env vars already set will take precedence because
        # the config file uses := (set-if-not-set) assignment style.
        # We wrap it so it doesn't abort us on set -e.
        # shellcheck disable=SC1090
        set +e
        source "${cfg}"
        set -e
        _info "Loaded config: ${cfg}"
    fi

    # Apply defaults for anything still unset
    : "${MYSQL_HOST:=127.0.0.1}"
    : "${MYSQL_PORT:=3306}"
    : "${MYSQL_USER:=}"
    : "${MYSQL_PASS:=}"
    : "${MC_ALIAS:=ovh}"
    : "${S3_ENDPOINT:=}"
    : "${S3_ACCESS_KEY:=}"
    : "${S3_SECRET_KEY:=}"
    : "${S3_BUCKET:=}"
    : "${S3_INSECURE:=}"
    : "${S3_MYSQL_PREFIX:=mysql}"
    : "${S3_ZPAQ_PREFIX:=zpaq}"
    : "${DUMP_XZ_MAX_SIZE_GB:=50}"
}

# ============================================================
# Verbose helper — show output only when -v
# ============================================================
_vout() {
    # Print $1 (label) and $2 (content) only in verbose mode
    if [[ "${OPT_VERBOSE}" == true ]] && [[ -n "${2:-}" ]]; then
        printf "      %s\n" "--- ${1} ---"
        while IFS= read -r _vline; do
            printf "      %s\n" "${_vline}"
        done <<< "$2"
    fi
}

# ============================================================
# Dependency check
# ============================================================
_check_deps() {
    _head "Checking required tools"
    local missing=0
    local tool
    for tool in mysqladmin mysql mc; do
        if command -v "${tool}" &>/dev/null; then
            _pass "${tool} found: $(command -v "${tool}")"
            _record PASS "tool:${tool}"
        else
            _fail "${tool} not found in PATH"
            _record FAIL "tool:${tool}"
            (( missing++ )) || true
        fi
    done
    return $(( missing > 0 ? 1 : 0 ))
}

# ============================================================
# Config display (mask secrets)
# ============================================================
_show_config() {
    _head "Configuration"
    _info "MYSQL_HOST       = ${MYSQL_HOST}"
    _info "MYSQL_PORT       = ${MYSQL_PORT}"
    _info "MYSQL_USER       = ${MYSQL_USER:-(empty)}"
    if [[ -n "${MYSQL_PASS}" ]]; then
        _info "MYSQL_PASS       = ******* (set)"
    else
        _info "MYSQL_PASS       = (empty)"
    fi
    _info "MC_ALIAS         = ${MC_ALIAS}"
    _info "S3_ENDPOINT      = ${S3_ENDPOINT:-(empty)}"
    if [[ -n "${S3_ACCESS_KEY}" ]]; then
        _info "S3_ACCESS_KEY    = ${S3_ACCESS_KEY:0:6}****"
    else
        _info "S3_ACCESS_KEY    = (empty)"
    fi
    if [[ -n "${S3_SECRET_KEY}" ]]; then
        _info "S3_SECRET_KEY    = ******* (set)"
    else
        _info "S3_SECRET_KEY    = (empty)"
    fi
    _info "S3_BUCKET        = ${S3_BUCKET:-(empty)}"
    _info "S3_MYSQL_PREFIX  = ${S3_MYSQL_PREFIX}"
    _info "S3_ZPAQ_PREFIX   = ${S3_ZPAQ_PREFIX}"
    _info "S3_INSECURE      = ${S3_INSECURE:-(not set)}"
    _info "DUMP_XZ_MAX_SIZE_GB = ${DUMP_XZ_MAX_SIZE_GB}"
}

# ============================================================
# Validate required variables are non-empty
# ============================================================
_check_required_vars() {
    _head "Validating required variables"
    local ok=true
    local var val

    for var in MYSQL_HOST MYSQL_PORT MYSQL_USER MYSQL_PASS \
               S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET; do
        val="${!var:-}"
        if [[ -z "${val}" ]]; then
            _fail "${var} is not set"
            _record FAIL "var:${var}"
            ok=false
        else
            _pass "${var} is set"
            _record PASS "var:${var}"
        fi
    done

    if [[ "${ok}" == true ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================
# MySQL Tests
# ============================================================
_test_mysql() {
    _head "MySQL connectivity"

    local mysql_conn_args=(
        -h"${MYSQL_HOST}"
        -P"${MYSQL_PORT}"
        -u"${MYSQL_USER}"
        -p"${MYSQL_PASS}"
        --connect-timeout=10
    )

    # ── Test 1: mysqladmin ping ──────────────────────────────
    local ping_out ping_rc=0
    ping_out=$(mysqladmin ping \
        -h"${MYSQL_HOST}" \
        -P"${MYSQL_PORT}" \
        -u"${MYSQL_USER}" \
        -p"${MYSQL_PASS}" \
        --connect-timeout=10 \
        2>&1) || ping_rc=$?

    _vout "mysqladmin ping" "${ping_out}"

    if (( ping_rc == 0 )); then
        _pass "mysqladmin ping — server is alive"
        _record PASS "mysql:ping"
    else
        _fail "mysqladmin ping failed (rc=${ping_rc}) — check MYSQL_HOST, MYSQL_PORT, credentials"
        _vout "mysqladmin ping (error)" "${ping_out}"
        _record FAIL "mysql:ping"
        # No point continuing MySQL tests
        _warn "Skipping further MySQL tests due to ping failure"
        _record SKIP "mysql:show_databases"
        _record SKIP "mysql:read_mysql_user"
        return 1
    fi

    # ── Test 2: SHOW DATABASES ───────────────────────────────
    local db_out db_rc=0
    db_out=$(mysql "${mysql_conn_args[@]}" \
        --batch --skip-column-names \
        -e "SHOW DATABASES;" \
        2>&1) || db_rc=$?

    _vout "SHOW DATABASES" "${db_out}"

    if (( db_rc == 0 )); then
        local db_count
        db_count=$(echo "${db_out}" | grep -c '.' || true)
        _pass "SHOW DATABASES — OK (${db_count} database(s) visible)"
        _record PASS "mysql:show_databases"
    else
        _fail "SHOW DATABASES failed (rc=${db_rc}) — user may lack SELECT privilege"
        _record FAIL "mysql:show_databases"
    fi

    # ── Test 3: mysql.user read (needed for SHOW GRANTS) ────
    local user_out user_rc=0
    user_out=$(mysql "${mysql_conn_args[@]}" \
        --batch --skip-column-names \
        -e "SELECT COUNT(*) FROM mysql.user;" \
        2>&1) || user_rc=$?

    _vout "SELECT COUNT(*) FROM mysql.user" "${user_out}"

    if (( user_rc == 0 )); then
        local user_count="${user_out//[^0-9]/}"
        _pass "SELECT on mysql.user — OK (${user_count} user(s) found)"
        _record PASS "mysql:read_mysql_user"
    else
        # Non-fatal: grants backup is optional
        _warn "SELECT on mysql.user failed (rc=${user_rc}) — grants backup will be skipped"
        _warn "Grant the backup user: GRANT SELECT ON mysql.user TO '${MYSQL_USER}'@'%';"
        _record WARN "mysql:read_mysql_user"
    fi

    return 0
}

# ============================================================
# S3 / mc Tests
# ============================================================
_test_s3() {
    _head "S3 / mc connectivity"

    local insecure_flag=""
    [[ -n "${S3_INSECURE:-}" ]] && insecure_flag="--insecure"

    # ── Test 4: mc alias set ─────────────────────────────────
    # Always (re-)set the alias for the test run so we validate the
    # credentials regardless of any cached state.
    local alias_out alias_rc=0
    alias_out=$(mc alias set "${MC_ALIAS}" \
        "${S3_ENDPOINT}" \
        "${S3_ACCESS_KEY}" \
        "${S3_SECRET_KEY}" \
        ${insecure_flag} \
        2>&1) || alias_rc=$?

    _vout "mc alias set" "${alias_out}"

    if (( alias_rc == 0 )); then
        _pass "mc alias set '${MC_ALIAS}' → ${S3_ENDPOINT}"
        _record PASS "s3:alias_set"
    else
        _fail "mc alias set failed (rc=${alias_rc}) — check S3_ENDPOINT, S3_ACCESS_KEY, S3_SECRET_KEY"
        _vout "mc alias set (error)" "${alias_out}"
        _record FAIL "s3:alias_set"
        _warn "Skipping further S3 tests due to alias failure"
        _record SKIP "s3:ls_bucket"
        _record SKIP "s3:put_probe"
        _record SKIP "s3:stat_probe"
        _record SKIP "s3:rm_probe"
        return 1
    fi

    # ── Test 5: mc ls bucket ─────────────────────────────────
    local bucket_path="${MC_ALIAS}/${S3_BUCKET}"
    local ls_out ls_rc=0
    ls_out=$(mc ls "${bucket_path}" ${insecure_flag} 2>&1) || ls_rc=$?

    _vout "mc ls ${bucket_path}" "${ls_out}"

    if (( ls_rc == 0 )); then
        _pass "mc ls ${bucket_path} — bucket accessible"
        _record PASS "s3:ls_bucket"
    else
        _fail "mc ls ${bucket_path} failed (rc=${ls_rc}) — bucket may not exist or credentials lack ListBucket"
        _vout "mc ls (error)" "${ls_out}"
        _record FAIL "s3:ls_bucket"
        _warn "Skipping probe object tests"
        _record SKIP "s3:put_probe"
        _record SKIP "s3:stat_probe"
        _record SKIP "s3:rm_probe"
        return 1
    fi

    # ── Test 6: mc put probe object ──────────────────────────
    # Write a small probe file to <bucket>/<mysql_prefix>/.test_probe
    local probe_key="${S3_MYSQL_PREFIX}/.connection_test_$(date +%s)"
    local probe_path="${MC_ALIAS}/${S3_BUCKET}/${probe_key}"
    local probe_content="mysql_dump_zpaq connection test $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    # Calculate part size using the same formula as calc_mc_part_size_mib()
    # in mysql_dump_ops.sh (inlined here — test script does not source modules).
    local probe_part_mib
    probe_part_mib=$(python3 -c "
import math
max_mib = int('${DUMP_XZ_MAX_SIZE_GB:-50}') * 1024
part = math.ceil(max_mib / 9000)
part = max(part, 15)
part = min(part, 500)
print(part)
")
    _info "mc part-size: ${probe_part_mib}MiB (DUMP_XZ_MAX_SIZE_GB=${DUMP_XZ_MAX_SIZE_GB:-50})"

    local put_out put_rc=0
    put_out=$(echo "${probe_content}" \
        | mc pipe "${probe_path}" \
            --attr "Content-Type=application/x-xz" \
            --part-size "${probe_part_mib}MiB" \
            ${insecure_flag} 2>&1) || put_rc=$?

    _vout "mc pipe (probe put) → ${probe_path}" "${put_out}"

    if (( put_rc == 0 )); then
        _pass "mc pipe probe → ${probe_path} — write OK"
        _record PASS "s3:put_probe"
    else
        _fail "mc pipe probe failed (rc=${put_rc}) — credentials may lack PutObject on '${S3_MYSQL_PREFIX}/'"
        _vout "mc pipe (error)" "${put_out}"
        _record FAIL "s3:put_probe"
        _record SKIP "s3:stat_probe"
        _record SKIP "s3:rm_probe"
        return 1
    fi

    # ── Test 7: mc stat probe object ─────────────────────────
    local stat_out stat_rc=0
    stat_out=$(mc stat "${probe_path}" ${insecure_flag} 2>&1) || stat_rc=$?

    _vout "mc stat ${probe_path}" "${stat_out}"

    if (( stat_rc == 0 )); then
        # Extract size
        local probe_size
        probe_size=$(echo "${stat_out}" | grep -i "^Size" | grep -oP '\d+' | head -1 || echo "?")
        _pass "mc stat probe — object visible (${probe_size} bytes)"
        _record PASS "s3:stat_probe"
    else
        _fail "mc stat probe failed (rc=${stat_rc}) — object written but not readable back"
        _vout "mc stat (error)" "${stat_out}"
        _record FAIL "s3:stat_probe"
    fi

    # ── Test 8: mc rm probe object ───────────────────────────
    local rm_out rm_rc=0
    rm_out=$(mc rm "${probe_path}" ${insecure_flag} 2>&1) || rm_rc=$?

    _vout "mc rm ${probe_path}" "${rm_out}"

    if (( rm_rc == 0 )); then
        _pass "mc rm probe — delete OK"
        _record PASS "s3:rm_probe"
    else
        # Delete permission may be intentionally restricted; warn only
        _warn "mc rm probe failed (rc=${rm_rc}) — delete permission not granted (non-fatal)"
        _warn "Probe object left at: ${probe_path}"
        _record WARN "s3:rm_probe"
    fi

    # ── Bonus: list zpaq prefix ──────────────────────────────
    # Non-fatal check — just confirms the zpaq prefix is reachable
    local zpaq_path="${MC_ALIAS}/${S3_BUCKET}/${S3_ZPAQ_PREFIX}/"
    local zpaq_ls_out zpaq_ls_rc=0
    zpaq_ls_out=$(mc ls "${zpaq_path}" ${insecure_flag} 2>&1) || zpaq_ls_rc=$?

    _vout "mc ls ${zpaq_path}" "${zpaq_ls_out}"

    if (( zpaq_ls_rc == 0 )); then
        _pass "mc ls zpaq prefix (${S3_ZPAQ_PREFIX}/) — accessible"
        _record PASS "s3:ls_zpaq_prefix"
    else
        _warn "mc ls zpaq prefix (${S3_ZPAQ_PREFIX}/) failed — prefix may not exist yet (non-fatal for first run)"
        _record WARN "s3:ls_zpaq_prefix"
    fi

    return 0
}

# ============================================================
# Summary
# ============================================================
_print_summary() {
    _head "Test Summary"
    _sep

    local pass=0 fail=0 warn=0 skip=0
    local entry status label

    for entry in "${RESULTS[@]}"; do
        status="${entry%%|*}"
        label="${entry#*|}"
        case "${status}" in
            PASS) (( pass++ )) || true;  _pass "${label}" ;;
            FAIL) (( fail++ )) || true;  _fail "${label}" ;;
            WARN) (( warn++ )) || true;  _warn "${label}" ;;
            SKIP) (( skip++ )) || true;  _info "SKIP  ${label}" ;;
        esac
    done

    _sep
    printf "\n  Passed: ${_GREEN}%d${_RESET}   Failed: ${_RED}%d${_RESET}   Warnings: ${_YELLOW}%d${_RESET}   Skipped: %d\n\n" \
        "${pass}" "${fail}" "${warn}" "${skip}"

    if (( fail > 0 )); then
        printf "  ${_RED}${_BOLD}RESULT: FAILED${_RESET} — fix the errors above before running mysql_dump_zpaq.sh\n\n"
        return 1
    elif (( warn > 0 )); then
        printf "  ${_YELLOW}${_BOLD}RESULT: PASSED WITH WARNINGS${_RESET} — review warnings above\n\n"
        return 0
    else
        printf "  ${_GREEN}${_BOLD}RESULT: ALL TESTS PASSED${_RESET}\n\n"
        return 0
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    printf "\n${_BOLD}mysql_dump_zpaq — Connection & Credentials Test${_RESET}\n"
    printf "Run at: %s\n" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    _sep

    _load_config
    _show_config
    _check_deps || true          # record results but keep going to show all failures
    _check_required_vars || true # same
    _test_mysql  || true
    _test_s3     || true
    _print_summary
}

main "$@"