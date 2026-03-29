#!/usr/bin/env bash
# ============================================================
# scripts/install_zpaqfranz.sh — Download, compile, and install
# the latest zpaqfranz release on a Debian/Ubuntu system.
#
# Usage:
#   sudo ./scripts/install_zpaqfranz.sh            # latest release (SFTP enabled)
#   sudo ./scripts/install_zpaqfranz.sh 64.7       # specific version
#   sudo ./scripts/install_zpaqfranz.sh --no-sftp  # build without SFTP
#
# Options:
#   VERSION        Optional positional argument: tag to install (e.g. 64.7).
#                  Defaults to the latest GitHub release.
#   --no-sftp      Build without SFTP support (no libssh-4 runtime dep).
#   --static       Static binary (no SFTP, no -ldl; good for containers).
#   --jobs N       Parallel compile jobs (default: nproc).
#   --prefix DIR   Install prefix (default: /usr/local).
#   --keep-build   Do not remove the build directory after install.
#   --dry-run      Print steps without executing them.
#
# What this script does:
#   1. Checks for / installs required build packages (g++, make, etc.)
#   2. Queries the GitHub API for the latest release tag (or uses VERSION)
#   3. Downloads the source tarball from GitHub
#   4. Verifies the download is non-empty
#   5. Compiles using the top-level Makefile
#   6. Runs "make install" to copy to PREFIX/bin and strip the binary
#   7. Verifies the installed binary reports the expected version
#   8. Optionally cleans up the build directory
#
# Requirements:
#   - Debian 10+ / Ubuntu 20.04+ (uses apt-get)
#   - sudo / root privileges (for apt-get and /usr/local/bin write)
#   - Internet access (GitHub + apt mirrors)
#
# Runtime note (SFTP builds):
#   SFTP support uses dlopen() at runtime — the binary itself requires no
#   extra link flags, but the host system needs libssh-4 installed:
#     sudo apt-get install libssh-4
# ============================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ZPAQFRANZ_VERSION=""          # empty = fetch latest from GitHub API
ENABLE_SFTP="yes"
BUILD_STATIC="no"
JOBS=$(nproc 2>/dev/null || echo 2)
PREFIX="/usr/local"
KEEP_BUILD="no"
DRY_RUN="no"

GITHUB_API="https://api.github.com/repos/fcorbelli/zpaqfranz"
GITHUB_TARBALL="https://github.com/fcorbelli/zpaqfranz/archive/refs/tags"

# ---------------------------------------------------------------------------
# Colours (suppressed when not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()  { echo -e "${BOLD}==> $*${RESET}"; }
run()   {
    if [[ "${DRY_RUN}" == "yes" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-sftp)    ENABLE_SFTP="no";  shift ;;
        --static)     BUILD_STATIC="yes"; shift ;;
        --keep-build) KEEP_BUILD="yes";  shift ;;
        --dry-run)    DRY_RUN="yes";     shift ;;
        --jobs)       JOBS="${2:?--jobs requires a number}"; shift 2 ;;
        --prefix)     PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# ======/{ s/^# \{0,2\}//; p }' "$0"
            exit 0 ;;
        -*)           die "Unknown option: $1  (use --help)" ;;
        *)
            # Positional: version tag
            [[ -z "${ZPAQFRANZ_VERSION}" ]] \
                || die "Unexpected argument: $1"
            ZPAQFRANZ_VERSION="$1"
            shift ;;
    esac
done

# Static implies no SFTP (dlopen is incompatible with -static)
[[ "${BUILD_STATIC}" == "yes" ]] && ENABLE_SFTP="no"

BINDIR="${PREFIX}/bin"

# ---------------------------------------------------------------------------
# Root / sudo check
# ---------------------------------------------------------------------------
if [[ "${DRY_RUN}" != "yes" && "${EUID}" -ne 0 ]]; then
    die "This script must be run as root (use sudo)."
fi

# ---------------------------------------------------------------------------
# Step 1: Install build dependencies
# ---------------------------------------------------------------------------
step "Checking build dependencies"

APT_PKGS=()

need_pkg() {
    local pkg="$1" cmd="${2:-}"
    if [[ -n "${cmd}" ]]; then
        command -v "${cmd}" &>/dev/null && return 0
    fi
    dpkg -s "${pkg}" &>/dev/null 2>&1 && return 0
    APT_PKGS+=("${pkg}")
}

need_pkg "g++"     "g++"
need_pkg "make"    "make"
need_pkg "wget"    "wget"
need_pkg "ca-certificates"

if [[ ${#APT_PKGS[@]} -gt 0 ]]; then
    info "Installing missing packages: ${APT_PKGS[*]}"
    run apt-get update -qq
    run apt-get install -y -qq "${APT_PKGS[@]}"
else
    ok "All build dependencies already installed"
fi

# ---------------------------------------------------------------------------
# Step 2: Resolve version
# ---------------------------------------------------------------------------
step "Resolving zpaqfranz version"

if [[ -z "${ZPAQFRANZ_VERSION}" ]]; then
    info "Querying GitHub API for latest release..."
    if command -v curl &>/dev/null; then
        ZPAQFRANZ_VERSION=$(curl -fsSL "${GITHUB_API}/releases/latest" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" \
            2>/dev/null) || true
    fi
    if [[ -z "${ZPAQFRANZ_VERSION}" ]] && command -v wget &>/dev/null; then
        ZPAQFRANZ_VERSION=$(wget -qO- "${GITHUB_API}/releases/latest" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" \
            2>/dev/null) || true
    fi
    [[ -n "${ZPAQFRANZ_VERSION}" ]] \
        || die "Could not determine latest version from GitHub API."
    ok "Latest release: ${ZPAQFRANZ_VERSION}"
else
    ok "Using requested version: ${ZPAQFRANZ_VERSION}"
fi

TARBALL_URL="${GITHUB_TARBALL}/${ZPAQFRANZ_VERSION}.tar.gz"
BUILD_DIR="/tmp/zpaqfranz-build-${ZPAQFRANZ_VERSION}"

# ---------------------------------------------------------------------------
# Step 3: Download source tarball
# ---------------------------------------------------------------------------
step "Downloading zpaqfranz ${ZPAQFRANZ_VERSION}"

TARBALL_FILE="/tmp/zpaqfranz-${ZPAQFRANZ_VERSION}.tar.gz"

if [[ -f "${TARBALL_FILE}" && -s "${TARBALL_FILE}" ]]; then
    info "Using cached tarball: ${TARBALL_FILE}"
else
    info "URL: ${TARBALL_URL}"
    if command -v wget &>/dev/null; then
        run wget -q --show-progress -O "${TARBALL_FILE}" "${TARBALL_URL}" \
            || run wget -q -O "${TARBALL_FILE}" "${TARBALL_URL}"
    elif command -v curl &>/dev/null; then
        run curl -fL --progress-bar -o "${TARBALL_FILE}" "${TARBALL_URL}"
    else
        die "Neither wget nor curl found — cannot download."
    fi
fi

if [[ "${DRY_RUN}" != "yes" ]]; then
    [[ -s "${TARBALL_FILE}" ]] \
        || die "Downloaded tarball is empty: ${TARBALL_FILE}"
    ok "Tarball downloaded: ${TARBALL_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 4: Extract
# ---------------------------------------------------------------------------
step "Extracting source"

run rm -rf "${BUILD_DIR}"
run mkdir -p "${BUILD_DIR}"

if [[ "${DRY_RUN}" != "yes" ]]; then
    # GitHub tarballs extract to "fcorbelli-zpaqfranz-<hash>" or
    # "zpaqfranz-<version>" — use --strip-components=1 to normalise.
    tar xzf "${TARBALL_FILE}" -C "${BUILD_DIR}" --strip-components=1
    [[ -f "${BUILD_DIR}/zpaqfranz.cpp" ]] \
        || die "zpaqfranz.cpp not found after extraction — unexpected tarball layout."
    [[ -f "${BUILD_DIR}/Makefile" ]] \
        || die "Makefile not found after extraction."
    ok "Extracted to: ${BUILD_DIR}"
fi

# ---------------------------------------------------------------------------
# Step 5: Compile
# ---------------------------------------------------------------------------
step "Compiling (jobs=${JOBS})"

# Show the configuration the Makefile will use
if [[ "${DRY_RUN}" != "yes" ]]; then
    info "Build configuration:"
    make -C "${BUILD_DIR}" check 2>/dev/null || true
fi

MAKE_TARGET="build"
[[ "${BUILD_STATIC}" == "yes" ]] && MAKE_TARGET="static"

MAKE_ARGS=(
    -C "${BUILD_DIR}"
    -j "${JOBS}"
    "ENABLE_SFTP=${ENABLE_SFTP}"
    "${MAKE_TARGET}"
)

# Workaround: the upstream Makefile only adds -ldl when ENABLE_SFTP=yes,
# but zpaqfranz.cpp uses dlopen() for libsodium (encryption) and libcurl
# unconditionally on Linux — independent of the SFTP flag.  Without -ldl
# the linker fails with "undefined reference to dlopen/dlsym/dlclose".
# Always inject -ldl on Linux until this is fixed upstream.
if [[ "$(uname -s)" == "Linux" && "${BUILD_STATIC}" != "yes" ]]; then
    MAKE_ARGS+=( "LDLIBS=-lm -ldl" )
fi

run make "${MAKE_ARGS[@]}"

if [[ "${DRY_RUN}" != "yes" ]]; then
    [[ -x "${BUILD_DIR}/zpaqfranz" ]] \
        || die "Compilation failed — zpaqfranz binary not produced."
    ok "Compilation successful"
fi

# ---------------------------------------------------------------------------
# Step 6: Install
# ---------------------------------------------------------------------------
step "Installing to ${BINDIR}"

INSTALL_ARGS=(
    -C "${BUILD_DIR}"
    "PREFIX=${PREFIX}"
    install
)

run make "${INSTALL_ARGS[@]}"

if [[ "${DRY_RUN}" != "yes" ]]; then
    [[ -x "${BINDIR}/zpaqfranz" ]] \
        || die "Installation failed — ${BINDIR}/zpaqfranz not found."
    ok "Installed: ${BINDIR}/zpaqfranz"
fi

# ---------------------------------------------------------------------------
# Step 7: Verify installed version
# ---------------------------------------------------------------------------
step "Verifying installed binary"

if [[ "${DRY_RUN}" != "yes" ]]; then
    INSTALLED_LINE=$("${BINDIR}/zpaqfranz" 2>&1 | head -1 || true)
    INSTALLED_VER=$(echo "${INSTALLED_LINE}" \
        | awk '{ s = $0; sub(/.*v/, "", s); sub(/[^0-9.].*/, "", s); print s }')

    if [[ -z "${INSTALLED_VER}" ]]; then
        warn "Could not parse version from binary output: ${INSTALLED_LINE}"
    else
        ok "Installed version: ${INSTALLED_VER}  (requested: ${ZPAQFRANZ_VERSION})"

        # Warn if the binary version doesn't match what we built
        # (e.g. PATH shadowed by an older system binary)
        CANONICAL_VER=$(echo "${ZPAQFRANZ_VERSION}" \
            | awk '{ s = $0; sub(/[^0-9]*/, "", s); sub(/[^0-9.].*/, "", s); print s }')
        if [[ "${INSTALLED_VER}" != "${CANONICAL_VER}" ]]; then
            warn "Version mismatch: binary reports ${INSTALLED_VER}, expected ${CANONICAL_VER}"
            warn "Check that ${BINDIR} is earlier in PATH than any other zpaqfranz installation."
        fi
    fi

    # Print the full first line (contains JIT/SFTP/hw flags)
    info "Binary info: ${INSTALLED_LINE}"
fi

# ---------------------------------------------------------------------------
# Step 8: Cleanup
# ---------------------------------------------------------------------------
if [[ "${KEEP_BUILD}" == "no" ]]; then
    step "Cleaning up build directory"
    run rm -rf "${BUILD_DIR}"
    # Keep the tarball so a re-run with the same version doesn't re-download
    info "Tarball kept at: ${TARBALL_FILE} (re-run will reuse it)"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}zpaqfranz ${ZPAQFRANZ_VERSION} installed successfully.${RESET}"
echo ""
echo "  Binary : ${BINDIR}/zpaqfranz"
echo "  Symlink: ${BINDIR}/dir  (zpaqfranz alias)"
if [[ "${ENABLE_SFTP}" == "yes" ]]; then
    echo ""
    echo "  SFTP support is enabled.  Ensure libssh-4 is installed at runtime:"
    echo "    sudo apt-get install libssh-4"
fi
echo ""