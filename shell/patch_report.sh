#!/bin/bash

# Configuration
SERVER_FILE="servers.txt"
REPORT_FILE="apt_update_report.txt"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

# Check server list
if [[ ! -f "$SERVER_FILE" ]]; then
    echo "ERROR: $SERVER_FILE not found."
    exit 1
fi

# Initialize report
{
    echo "APT UPDATE REPORT"
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

    # Connect to remote server and collect APT information
    RESULT=$(ssh $SSH_OPTS "$SERVER" 'bash -s' <<'REMOTE'
set -u

# Check whether this is a Debian/Ubuntu system
if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: APT is not available on this server."
    exit 1
fi

# Get server information
HOSTNAME_VALUE=$(hostname -f 2>/dev/null || hostname)

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_VALUE="${PRETTY_NAME:-Unknown}"
else
    OS_VALUE="Unknown"
fi

echo "REMOTE_HOSTNAME: $HOSTNAME_VALUE"
echo "SERVER_OS: $OS_VALUE"

# Refresh package metadata
if ! sudo -n apt-get update -qq 2>/dev/null; then
    echo "ERROR: APT metadata refresh failed or passwordless sudo is unavailable."
    exit 0
fi

# Get upgradeable packages
UPDATES=$(apt list --upgradable 2>/dev/null | tail -n +2)

if [[ -n "$UPDATES" ]]; then
    COUNT=$(printf '%s\n' "$UPDATES" | grep -c .)
else
    COUNT=0
fi

echo "UPDATE_COUNT: $COUNT"
echo "PACKAGE_DETAILS_BEGIN"

if [[ -n "$UPDATES" ]]; then
    # Fixed Awk to correctly extract package names, current, and target versions
    printf '%s\n' "$UPDATES" |
    awk '
    {
        split($1, pkg_arr, "/");
        package = pkg_arr[1];
        target = $2;
        
        current = "Unknown";
        for (i=1; i<=NF; i++) {
            if ($i == "from:") {
                current = $(i+1);
                sub(/\]/, "", current); # Strip trailing bracket
                break;
            }
        }
        printf "%-30s %-25s %-25s\n", package, current, target
    }'
fi

echo "PACKAGE_DETAILS_END"
REMOTE
)

    SSH_STATUS=$?

    # Handle explicit connection or protocol level errors
    if [[ $SSH_STATUS -ne 0 ]] || [[ -z "$RESULT" ]]; then
        {
            echo "Status: FAILED"
            echo "Reason: SSH connection failed or remote command returned no output."
            echo
            echo
        } >> "$REPORT_FILE"

        echo "WARNING: Failed to collect data from $SERVER"
        continue
    fi

    # Handle internal script errors captured from stdout
    if printf '%s\n' "$RESULT" | grep -q '^ERROR:'; then
        {
            echo "Status: ERROR"
            printf '%s\n' "$RESULT" | grep '^ERROR:'
            echo
            echo
        } >> "$REPORT_FILE"
        
        echo "WARNING: Script execution error on $SERVER"
        continue
    fi

    # Extract metadata
    REMOTE_HOSTNAME=$(printf '%s\n' "$RESULT" | sed -n 's/^REMOTE_HOSTNAME: //p' | head -n 1)
    SERVER_OS=$(printf '%s\n' "$RESULT" | sed -n 's/^SERVER_OS: //p' | head -n 1)
    UPDATE_COUNT=$(printf '%s\n' "$RESULT" | sed -n 's/^UPDATE_COUNT: //p' | head -n 1)

    {
        echo "Server hostname: ${REMOTE_HOSTNAME:-Unknown}"
        echo "Server OS: ${SERVER_OS:-Unknown}"
        echo "Number of updates available: ${UPDATE_COUNT:-Unknown}"
        echo
        printf "%-30s %-25s %-25s\n" "Package name" "Current version" "Target version"
        printf '%s\n' "--------------------------------------------------------------------------------"

        # Extract package details safely
        printf '%s\n' "$RESULT" |
            sed -n '/^PACKAGE_DETAILS_BEGIN$/,/^PACKAGE_DETAILS_END$/p' |
            sed '1d;$d'

        echo
        echo "Status: SUCCESS"
        echo
        echo
    } >> "$REPORT_FILE"

done < "$SERVER_FILE"

echo "============================================================"
echo "Report generated: $REPORT_FILE"
