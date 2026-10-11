#!/bin/bash

# Configuration
SERVER_FILE="servers.txt"
REPORT_FILE="os_update_report.txt"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# Check server list
if [[ ! -f "$SERVER_FILE" ]]; then
    echo "ERROR: $SERVER_FILE not found."
    exit 1
fi

# Initialize report
{
    echo "GLOBAL OS UPDATE REPORT"
    echo "Generated on: $(date)"
    echo "============================================================"
    echo
} > "$REPORT_FILE"

# Process each server
while IFS= read -r SERVER || [[ -n "$SERVER" ]]; do

    # Skip blank lines and comments
    [[ -z "${SERVER//[[:space:]]/}" ]] && continue
    [[ "$SERVER" =~ ^[[:space:]]*# ]] && continue

    echo "Checking server: $SERVER"

    {
        echo "Server name: $SERVER"
        echo "============================================================"
    } >> "$REPORT_FILE"

    # Connect to remote server and collect platform-native system information
    RESULT=$(ssh $SSH_OPTS "$SERVER" 'bash -s' <<'REMOTE'
set -u

# Get basic server information
HOSTNAME_VALUE=$(hostname -f 2>/dev/null || hostname)
OS_VALUE="Unknown"
OS_FAMILY="Unknown"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_VALUE="${PRETTY_NAME:-Unknown}"
    
    # Detect the package manager paradigm using ID or ID_LIKE
    if [[ "${ID:-}" =~ ^(rhel|centos|fedora|amzn)$ ]] || [[ "${ID_LIKE:-}" =~ (rhel|centos|fedora) ]]; then
        OS_FAMILY="redhat"
    elif [[ "${ID:-}" =~ ^(ubuntu|debian)$ ]] || [[ "${ID_LIKE:-}" =~ (ubuntu|debian) ]]; then
        OS_FAMILY="debian"
    elif [[ "${ID:-}" =~ ^(sles|opensuse)$ ]] || [[ "${ID_LIKE:-}" =~ (sles|suse) ]]; then
        OS_FAMILY="suse"
    fi
fi

# Fallback detection if os-release properties are minimal
if [[ "$OS_FAMILY" == "Unknown" ]]; then
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        OS_FAMILY="redhat"
    elif command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
    elif command -v zypper >/dev/null 2>&1; then
        OS_FAMILY="suse"
    fi
fi

echo "REMOTE_HOSTNAME: $HOSTNAME_VALUE"
echo "SERVER_OS: $OS_VALUE"
echo "OS_FAMILY: $OS_FAMILY"

if [[ "$OS_FAMILY" == "Unknown" ]]; then
    echo "ERROR: Unsupported Linux distribution or no package manager found."
    exit 0
fi

# Initialize update parsing block
COUNT=0
UPDATES=""

case "$OS_FAMILY" in
    "debian")
        if ! sudo -n apt-get update -qq 2>/dev/null; then
            echo "ERROR: APT metadata refresh failed or passwordless sudo is unavailable."
            exit 0
        fi
        UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2)
        if [[ -n "$UPDATES" ]]; then
            COUNT=$(printf '%s\n' "$UPDATES" | grep -c .)
            echo "UPDATE_COUNT: $COUNT"
            echo "PACKAGE_DETAILS_BEGIN"
            printf '%s\n' "$UPDATES" | awk '{
                split($1, pkg_arr, "/"); package = pkg_arr[1]; target = $2; current = "Unknown";
                for (i=1; i<=NF; i++) { if ($i == "from:") { current = $(i+1); sub(/\]/, "", current); break; } }
                printf "%-30s %-25s %-25s\n", package, current, target
            }'
            echo "PACKAGE_DETAILS_END"
        else
            echo "UPDATE_COUNT: 0"
        fi
        ;;

    "redhat")
        PKG_MGR=$(command -v dnf || command -v yum)
        # Check for updates (dnf/yum returns exit status 100 if updates exist, 0 if none)
        RAW_UPDATES=$(sudo -n "$PKG_MGR" check-update -q 2>/dev/null)
        STATUS=$?
        
        # If exit status is neither 0 nor 100, passwordless sudo or repo sync failed
        if [[ $STATUS -ne 0 && $STATUS -ne 100 ]]; then
            echo "ERROR: DNF/YUM update check failed or passwordless sudo is unavailable."
            exit 0
        fi
        
        # Clean up lines and drop headers
        CLEANED_UPDATES=$(printf '%s\n' "$RAW_UPDATES" | grep -E '\.(x86_64|noarch|i386|aarch64)\s+' | grep -v 'Obsoleting Packages')
        
        if [[ -n "$CLEANED_UPDATES" ]]; then
            COUNT=$(printf '%s\n' "$CLEANED_UPDATES" | grep -c .)
            echo "UPDATE_COUNT: $COUNT"
            echo "PACKAGE_DETAILS_BEGIN"
            printf '%s\n' "$CLEANED_UPDATES" | awk '{
                package = $1; target = $2; current = "Installed";
                printf "%-30s %-25s %-25s\n", package, current, target
            }'
            echo "PACKAGE_DETAILS_END"
        else
            echo "UPDATE_COUNT: 0"
        fi
        ;;

    "suse")
        # Refresh repos
        if ! sudo -n zypper --non-interactive refresh -q >/dev/null 2>&1; then
            echo "ERROR: Zypper metadata refresh failed or passwordless sudo is unavailable."
            exit 0
        fi
        # List updates out in a clean csv-like format
        RAW_UPDATES=$(sudo -n zypper --non-interactive list-updates -g 2>/dev/null | tail -n +5)
        
        if [[ -n "$RAW_UPDATES" ]]; then
            COUNT=$(printf '%s\n' "$RAW_UPDATES" | grep -c .)
            echo "UPDATE_COUNT: $COUNT"
            echo "PACKAGE_DETAILS_BEGIN"
            printf '%s\n' "$RAW_UPDATES" | awk -F'|' '{
                gsub(/[ \t]+/, "", $3); gsub(/[ \t]+/, "", $4); gsub(/[ \t]+/, "", $5);
                package = $3; current = $4; target = $5;
                if (package != "") { printf "%-30s %-25s %-25s\n", package, current, target }
            }'
            echo "PACKAGE_DETAILS_END"
        else
            echo "UPDATE_COUNT: 0"
        fi
        ;;
esac
REMOTE
)

    SSH_STATUS=$?

    # Catch network failures
    if [[ $SSH_STATUS -ne 0 ]] || [[ -z "$RESULT" ]]; then
        {
            echo "Status: FAILED"
            echo "Reason: SSH connection failed or remote engine returned no data."
            echo; echo
        } >> "$REPORT_FILE"
        echo "WARNING: Failed to connect to $SERVER"
        continue
    fi

    # Catch runtime errors sent back by target system execution
    if printf '%s\n' "$RESULT" | grep -q '^ERROR:'; then
        {
            echo "Status: ERROR"
            printf '%s\n' "$RESULT" | grep '^ERROR:'
            echo; echo
        } >> "$REPORT_FILE"
        echo "WARNING: Logic execution failure on $SERVER"
        continue
    fi

    # Read extracted details
    REMOTE_HOSTNAME=$(printf '%s\n' "$RESULT" | sed -n 's/^REMOTE_HOSTNAME: //p' | head -n 1)
    SERVER_OS=$(printf '%s\n' "$RESULT" | sed -n 's/^SERVER_OS: //p' | head -n 1)
    UPDATE_COUNT=$(printf '%s\n' "$RESULT" | sed -n 's/^UPDATE_COUNT: //p' | head -n 1)

    {
        echo "Server hostname: ${REMOTE_HOSTNAME:-Unknown}"
        echo "Server OS: ${SERVER_OS:-Unknown}"
        echo "Number of updates available: ${UPDATE_COUNT:-Unknown}"
        echo
        
        if [[ "${UPDATE_COUNT:-0}" -gt 0 ]]; then
            printf "%-30s %-25s %-25s\n" "Package name" "Current version" "Target version"
            printf '%s\n' "--------------------------------------------------------------------------------"
            printf '%s\n' "$RESULT" | sed -n '/^PACKAGE_DETAILS_BEGIN$/,/^PACKAGE_DETAILS_END$/p' | sed '1d;$d'
        else
            echo "System is up to date."
        fi

        echo
        echo "Status: SUCCESS"
        echo; echo
    } >> "$REPORT_FILE"

done < "$SERVER_FILE"

echo "============================================================"
echo "Multi-OS Report generated: $REPORT_FILE"
