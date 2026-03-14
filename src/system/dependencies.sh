#!/usr/bin/env bash
# ============================================================
# src/system/dependencies.sh — Dependency Checking & Install Prompt
#
# Declares the map of required binaries to their apt package names
# and provides check_dependencies(), which:
#
#   1. Iterates DEP_PACKAGES and reports which binaries are present.
#   2. If any are missing, prints a clear install command.
#   3. When running interactively (stdin is a TTY), prompts the operator
#      to run the install command immediately and re-validates afterwards.
#   4. When running non-interactively (cron, CI, pipe), exits with an
#      error and the manual install command — never blocks a scheduled run.
#
# Dependency order:
#   Must be sourced after src/core/logging.sh (uses log()) and
#   src/core/constants.sh (uses SCRIPT_NAME).
# ============================================================

# Map of binary → apt package name.
# Add new entries here if additional tools are required in future.
declare -A DEP_PACKAGES=(
    [lftp]="lftp"
    [sshpass]="sshpass"
    [sftp]="openssh-client"
)

check_dependencies() {
    local missing=()
    local missing_pkgs=()

    echo "Checking required dependencies..."

    for binary in "${!DEP_PACKAGES[@]}"; do
        if ! command -v "${binary}" &>/dev/null; then
            missing+=("${binary}")
            missing_pkgs+=("${DEP_PACKAGES[${binary}]}")
        else
            echo "  [OK] ${binary} ($(command -v "${binary}"))"
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        echo "  All dependencies satisfied."
        echo ""
        return 0
    fi

    # --- One or more binaries are missing ---
    echo ""
    echo "============================================================"
    echo " MISSING DEPENDENCIES DETECTED"
    echo "============================================================"
    echo " The following required binaries were not found on this system:"
    echo ""
    for i in "${!missing[@]}"; do
        echo "   - ${missing[$i]}  (package: ${missing_pkgs[$i]})"
    done
    echo ""

    # Build the install command for only the missing packages.
    # De-duplicate packages in case two binaries share one package.
    local unique_pkgs
    unique_pkgs=$(printf '%s\n' "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    local install_cmd="sudo apt-get install -y ${unique_pkgs}"

    echo " To install the missing dependencies, run:"
    echo "   ${install_cmd}"
    echo "============================================================"
    echo ""

    # Detect whether we are running interactively
    if [[ -t 0 ]]; then
        local answer=""
        while true; do
            read -rp " Would you like to run this command now? [y/N]: " answer
            case "${answer,,}" in
                y|yes)
                    echo ""
                    echo " Running: ${install_cmd}"
                    echo "------------------------------------------------------------"
                    eval "${install_cmd}"
                    local install_exit=$?
                    if (( install_exit == 0 )); then
                        echo "------------------------------------------------------------"
                        echo " Installation complete. Re-checking dependencies..."
                        echo ""
                        local still_missing=()
                        for binary in "${missing[@]}"; do
                            if ! command -v "${binary}" &>/dev/null; then
                                still_missing+=("${binary}")
                            else
                                echo "  [OK] ${binary} now found at: $(command -v "${binary}")"
                            fi
                        done
                        if (( ${#still_missing[@]} > 0 )); then
                            echo ""
                            echo "ERROR: The following binaries are still missing after installation:" >&2
                            printf '  - %s\n' "${still_missing[@]}" >&2
                            echo "       Please install them manually and re-run the script." >&2
                            exit 1
                        fi
                        echo ""
                        echo " All dependencies are now satisfied. Continuing..."
                        echo ""
                        return 0
                    else
                        echo ""
                        echo "ERROR: apt-get installation failed (exit code ${install_exit})." >&2
                        echo "       Please install the packages manually and re-run the script." >&2
                        exit 1
                    fi
                    ;;
                n|no|"")
                    echo ""
                    echo " Aborting. Please install the missing dependencies manually:"
                    echo "   ${install_cmd}"
                    echo " Then re-run the script."
                    exit 1
                    ;;
                *)
                    echo " Please answer 'y' (yes) or 'n' (no)."
                    ;;
            esac
        done
    else
        # Non-interactive (cron, CI, pipe) — just exit with error
        echo "ERROR: Running non-interactively — cannot prompt for installation." >&2
        echo "       Please install missing packages manually and re-run the script:" >&2
        echo "         ${install_cmd}" >&2
        exit 1
    fi
}