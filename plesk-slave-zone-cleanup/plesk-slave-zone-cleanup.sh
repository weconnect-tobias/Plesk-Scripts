#!/bin/bash
#
# plesk-slave-zone-cleanup - Removes slave zones from BIND when the primary no longer serves them.
#
# Finds two kinds of zones in the log:
#   1. RETRY    - "refresh: retry limit for primary <IP>#53 exceeded"
#                 (the primary does not answer for the zone at all)
#   2. DISABLED - "refresh: unexpected rcode (REFUSED|NOTAUTH) from primary <IP>#53"
#                 "refresh: non-authoritative answer from primary <IP>#53"
#                 (the primary answers but no longer has the zone, e.g. DNS
#                  disabled for the domain in Plesk)
#
# Before anything is removed, each zone is checked live against the primary with dig.
# If the primary answers authoritatively again (zone re-enabled), it is skipped.
#
# Usage:
#   plesk-slave-zone-cleanup <IP-ADDRESS> [yes/no] [dryrun]
#       Find zones in the log for this primary
#   plesk-slave-zone-cleanup <ZONE> [ZONE...] [yes/no] [dryrun] [force]
#       Remove specific zone(s) directly
#
#   <IP-ADDRESS> Primary DNS server (Plesk) to look for in the log
#   <ZONE>       Zone name(s), e.g. example.com. The primary is read from
#                'rndc showzone' and checked live before removal.
#   yes/no       Also delete the zone file (yes = rndc delzone -clean)
#   dryrun       Only show what would be done
#   force        Zone mode only: remove even if the primary still serves the zone
#
# Options can be given in any order after the IP/zones.
#
# Run as a regular sudo user (e.g. ubuntu), not as root.
# MIT license.

set -uo pipefail

usage() {
    echo "Usage: $(basename "$0") <IP-ADDRESS> [yes/no] [dryrun]"
    echo "       $(basename "$0") <ZONE> [ZONE...] [yes/no] [dryrun] [force]"
    exit 1
}

LOGFILE="${LOGFILE:-/var/log/syslog}"   # Override with: LOGFILE=/var/log/named.log plesk-slave-zone-cleanup ...
TARGET_IP=""
MANUAL_ZONES=()
DELETE_FILES=""
DRYRUN=""
FORCE=""

is_ip()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]+$ ]]; }
is_domain() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}\.?$ ]]; }

for arg in "$@"; do
    a="${arg,,}"
    case "$a" in
        yes|y|no|n) DELETE_FILES="$a" ;;
        dryrun)     DRYRUN="dryrun" ;;
        force)      FORCE="force" ;;
        *)
            if is_ip "$a"; then
                [ -n "$TARGET_IP" ] && { echo "Error: only one IP address can be given."; exit 1; }
                TARGET_IP="$a"
            elif is_domain "$a"; then
                MANUAL_ZONES+=("${a%.}")
            else
                echo "Error: '$arg' is not an IP address, a zone name or a known option."
                usage
            fi ;;
    esac
done

if [ -n "$TARGET_IP" ] && [ ${#MANUAL_ZONES[@]} -gt 0 ]; then
    echo "Error: give either a primary IP address or zone name(s), not both."
    exit 1
fi
[ -z "$TARGET_IP" ] && [ ${#MANUAL_ZONES[@]} -eq 0 ] && usage
if [ -n "$FORCE" ] && [ -n "$TARGET_IP" ]; then
    echo "Error: 'force' can only be used together with zone names."
    exit 1
fi

# Delete zone files?
if [[ "$DELETE_FILES" == "yes" || "$DELETE_FILES" == "y" ]]; then
    DELETE_FLAG="-clean"
elif [[ "$DELETE_FILES" == "no" || "$DELETE_FILES" == "n" ]]; then
    DELETE_FLAG=""
else
    read -r -p "Do you want to delete the zone files as well? (yes/no) [default: yes]: " DELETE_FILES
    DELETE_FILES="${DELETE_FILES,,}"
    if [[ -z "$DELETE_FILES" || "$DELETE_FILES" == "yes" || "$DELETE_FILES" == "y" ]]; then
        DELETE_FLAG="-clean"
    else
        DELETE_FLAG=""
    fi
fi

for cmd in rndc dig; do
    if ! command -v "$cmd" >/dev/null 2>&1 && ! sudo sh -c "command -v $cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' not found (dig is in the bind9-dnsutils / dnsutils package)."
        exit 1
    fi
done


# Read the log (incl. rotated .1) - using sudo if the user lacks read access
read_log() {
    local f
    for f in "$LOGFILE.1" "$LOGFILE"; do
        if [ -r "$f" ]; then cat "$f"
        elif sudo test -f "$f"; then sudo cat "$f"
        fi
    done
}

# Escape dots in the IP and require #port after it, so 192.0.2.10 does not match 192.0.2.100
IP_RE="${TARGET_IP//./\\.}#[0-9]+"
# BIND 9.18+ logs "primary", older versions "master"
SRC_RE="(primary|master) $IP_RE"

RETRY_RE="refresh: retry limit for $SRC_RE exceeded"
DISABLED_RE="refresh: (unexpected rcode \((REFUSED|NOTAUTH)\) from $SRC_RE|non-authoritative answer from $SRC_RE)"

extract_zones() {
    # Extracts "example.com" from "zone example.com/IN: ..." (also handles views: "zone example.com/IN/view:")
    grep -E "$1" | sed -nE 's/.*zone ([^/ ]+)\/IN.*/\1/p' | tr 'A-Z' 'a-z' | sort -u
}

declare -A REASON=()     # zone -> RETRY / DISABLED / MANUAL
declare -A PRIMARY=()    # zone -> primary IP to check against

# Read the first primary IP from 'rndc showzone' (works for zones added with rndc addzone,
# which is how Plesk Slave DNS Manager adds them)
primary_from_showzone() {
    sudo rndc showzone "$1" 2>/dev/null \
        | grep -oE '(primaries|masters)[^{]*\{[^}]*\}' \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]*:[0-9a-fA-F:]+' \
        | head -n1
}

if [ ${#MANUAL_ZONES[@]} -gt 0 ]; then
    for z in "${MANUAL_ZONES[@]}"; do
        REASON["$z"]="MANUAL"
        PRIMARY["$z"]="$(primary_from_showzone "$z")"
    done
else
    if ! sudo test -f "$LOGFILE"; then
        echo "Error: Log file $LOGFILE does not exist!"
        exit 1
    fi

    echo "Searching for zones with primary $TARGET_IP in $LOGFILE..."
    LOGDATA="$(read_log)"

    mapfile -t RETRY_ZONES    < <(printf '%s\n' "$LOGDATA" | extract_zones "$RETRY_RE")
    mapfile -t DISABLED_ZONES < <(printf '%s\n' "$LOGDATA" | extract_zones "$DISABLED_RE")

    # Validate domain names and merge (a zone may appear in both lists)
    for z in "${RETRY_ZONES[@]}"; do
        is_domain "$z" && { REASON["$z"]="RETRY"; PRIMARY["$z"]="$TARGET_IP"; }
    done
    for z in "${DISABLED_ZONES[@]}"; do
        is_domain "$z" && { REASON["$z"]="DISABLED"; PRIMARY["$z"]="$TARGET_IP"; }
    done

    if [ ${#REASON[@]} -eq 0 ]; then
        echo "No zones with problems against $TARGET_IP found."
        exit 0
    fi
fi

# Live check against the primary:
#   ACTIVE  = primary answers authoritatively -> zone is alive, leave it
#   GONE    = primary answers REFUSED/NOTAUTH/NXDOMAIN or without the aa flag
#   TIMEOUT = no answer
#   OTHER   = e.g. SERVFAIL (zone exists but is broken on the primary) -> leave it
check_primary() {
    local out status flags
    [ -z "$2" ] && { echo "UNKNOWN"; return; }
    out="$(dig +norec +time=3 +tries=2 @"$2" "$1" SOA 2>/dev/null)"
    if [ -z "$out" ] || grep -q "connection timed out\|no servers could be reached" <<<"$out"; then
        echo "TIMEOUT"; return
    fi
    status="$(sed -nE 's/.*status: ([A-Z]+).*/\1/p' <<<"$out" | head -n1)"
    flags="$(sed -nE 's/.*;; flags: ([^;]*);.*/\1/p' <<<"$out" | head -n1)"
    case "$status" in
        NOERROR)
            if [[ " $flags " == *" aa "* ]]; then echo "ACTIVE"; else echo "GONE"; fi ;;
        REFUSED|NOTAUTH|NXDOMAIN) echo "GONE" ;;
        *) echo "OTHER($status)" ;;
    esac
}

# Does the zone still exist on this slave?
zone_exists_locally() {
    sudo rndc zonestatus "$1" >/dev/null 2>&1
}

TO_REMOVE=()
SKIPPED=()

echo
printf "%-40s %-9s %-10s %s\n" "ZONE" "SOURCE" "PRIMARY" "ACTION"
printf "%-40s %-9s %-10s %s\n" "----" "------" "-------" "------"
for ZONE in $(printf '%s\n' "${!REASON[@]}" | sort); do
    why="${REASON[$ZONE]}"
    if ! zone_exists_locally "$ZONE"; then
        printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "-" "skip (no longer exists locally)"
        continue
    fi
    live="$(check_primary "$ZONE" "${PRIMARY[$ZONE]}")"
    action="REMOVE"
    case "$live" in
        ACTIVE)
            if [ "$why" == "MANUAL" ] && [ -n "$FORCE" ]; then
                action="REMOVE"
            elif [ "$why" == "MANUAL" ]; then
                action="skip (still served by primary ${PRIMARY[$ZONE]}, add 'force')"
            else
                action="skip (active on primary again)"
            fi ;;
        UNKNOWN)
            # Zone given by name but primary could not be read - the user asked explicitly
            action="REMOVE" ;;
        TIMEOUT)
            # A timeout is only enough for RETRY zones (original behaviour).
            # A DISABLED zone that suddenly times out suggests a network problem.
            [ "$why" == "DISABLED" ] && action="skip (primary not answering right now)" ;;
        OTHER*)
            if [ "$why" == "MANUAL" ] && [ -n "$FORCE" ]; then
                action="REMOVE"
            else
                action="skip (unexpected answer, check manually)"
            fi ;;
    esac
    printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "$live" "$action"
    if [ "$action" == "REMOVE" ]; then TO_REMOVE+=("$ZONE"); else SKIPPED+=("$ZONE"); fi
done
echo

if [ ${#TO_REMOVE[@]} -eq 0 ]; then
    echo "No zones to remove."
    exit 0
fi

# Safety check: if many zones are only being removed because the primary times out,
# the primary may simply be down - we don't want to wipe everything.
TIMEOUT_COUNT=0
for ZONE in "${TO_REMOVE[@]}"; do
    [ "${REASON[$ZONE]}" == "RETRY" ] && TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
done
if [ "$TIMEOUT_COUNT" -ge 10 ] && [ "$TIMEOUT_COUNT" -eq ${#TO_REMOVE[@]} ] && [[ "$DRYRUN" != "dryrun" ]]; then
    echo "WARNING: $TIMEOUT_COUNT zones where the primary does not answer at all. Is $TARGET_IP down?"
    read -r -p "Type 'YES' to remove them anyway: " confirm
    [ "$confirm" == "YES" ] || { echo "Aborting."; exit 1; }
fi

if [[ "$DRYRUN" == "dryrun" ]]; then
    echo "DRY-RUN MODE ENABLED! No changes will be made."
    for ZONE in "${TO_REMOVE[@]}"; do
        echo "[DRY-RUN] Would run: sudo rndc delzone $DELETE_FLAG $ZONE"
    done
    echo "Dry-run complete. ${#TO_REMOVE[@]} zone(s) would be removed, ${#SKIPPED[@]} skipped."
    exit 0
fi

REMOVED=0
FAILED=0
for ZONE in "${TO_REMOVE[@]}"; do
    echo "Removing zone: $ZONE (${REASON[$ZONE]}) with rndc delzone $DELETE_FLAG"
    # shellcheck disable=SC2086  # DELETE_FLAG is either empty or -clean
    if sudo rndc delzone $DELETE_FLAG "$ZONE"; then
        REMOVED=$((REMOVED + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

# rndc delzone takes effect immediately; no rndc reload needed.
echo "Cleanup completed! Removed: $REMOVED, failed: $FAILED, skipped: ${#SKIPPED[@]}."
