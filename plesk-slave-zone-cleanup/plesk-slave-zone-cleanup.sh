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
#   plesk-slave-zone-cleanup [yes/no] [dryrun]
#       Find broken zones in the log, whatever their primary (auto mode)
#   plesk-slave-zone-cleanup <IP-ADDRESS> [yes/no] [dryrun]
#       Same, but only zones for this primary
#   plesk-slave-zone-cleanup <ZONE> [ZONE...] [yes/no] [dryrun] [force]
#       Remove specific zone(s) directly
#
#   <IP-ADDRESS> Only look for zones from this primary DNS server (Plesk)
#   <ZONE>       Zone name(s), e.g. example.com. The primary is read from
#                'rndc showzone' and checked live before removal.
#   yes/no       Also delete the zone file (yes = rndc delzone -clean)
#   dryrun       Only show what would be done
#   force        Zone mode only: remove even if the primary still serves the zone
#
# Options can be given in any order after the IP/zones.
#
# Non-interactive: when there is no terminal (cron, ssh host cmd, pipes) the script never
# asks anything. If yes/no is not given, zone files are deleted (yes). The "primary may be
# down" safety check skips those zones instead of asking. Every removal is logged to syslog with the
# tag plesk-slave-zone-cleanup.
#
# Exit codes: 0 = OK (or nothing to do), 1 = error or a removal failed,
#             2 = zones held back by the "primary may be down" safety check.
#
# Run as a regular sudo user (e.g. ubuntu); running as root also works.
# MIT license.

set -uo pipefail

# cron runs with PATH=/usr/bin:/bin, but rndc and named-checkconf live in /usr/sbin
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Run a command as root: directly if we already are root, otherwise via sudo
as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -- "$@"; fi
}

# True when someone can answer questions
interactive() { [ -t 0 ] && [ -t 1 ]; }

TAG="plesk-slave-zone-cleanup"
log_sys() { logger -t "$TAG" -- "$*" 2>/dev/null || true; }

usage() {
    echo "Usage: $(basename "$0") [IP-ADDRESS] [yes/no] [dryrun]"
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
        -h|--help|help) usage ;;
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
# No IP and no zones: auto mode, look at every primary in the log
AUTO=""
[ -z "$TARGET_IP" ] && [ ${#MANUAL_ZONES[@]} -eq 0 ] && AUTO="auto"
if [ -n "$FORCE" ] && [ ${#MANUAL_ZONES[@]} -eq 0 ]; then
    echo "Error: 'force' can only be used together with zone names."
    exit 1
fi

# Delete zone files?
if [[ "$DELETE_FILES" == "yes" || "$DELETE_FILES" == "y" ]]; then
    DELETE_FLAG="-clean"
elif [[ "$DELETE_FILES" == "no" || "$DELETE_FILES" == "n" ]]; then
    DELETE_FLAG=""
elif [ -n "$DRYRUN" ] || ! interactive; then
    # Dry run or no terminal: don't ask, use the default
    DELETE_FLAG="-clean"
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
    if ! command -v "$cmd" >/dev/null 2>&1 && ! as_root sh -c "command -v $cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' not found (dig is in the bind9-dnsutils / dnsutils package)."
        exit 1
    fi
done


# Read the log (incl. rotated .1) - using sudo if the user lacks read access
read_log() {
    local f
    for f in "$LOGFILE.1" "$LOGFILE"; do
        if [ -r "$f" ]; then cat "$f"
        elif as_root test -f "$f"; then as_root cat "$f"
        fi
    done
}

# Escape dots in the IP and require #port after it, so 192.0.2.10 does not match 192.0.2.100
if [ -n "$TARGET_IP" ]; then
    IP_RE="${TARGET_IP//./\\.}#[0-9]+"
else
    IP_RE="[0-9a-fA-F.:]+#[0-9]+"        # auto mode: any primary
fi
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

# Read ALL primary IPs of a zone from 'rndc showzone', space separated (works for zones
# added with rndc addzone, which is how Plesk Slave DNS Manager adds them).
# The zone's current config is the truth - log lines can be old or refer to another server.
primaries_from_showzone() {
    as_root rndc showzone "$1" 2>/dev/null \
        | grep -oE '(primaries|masters)[^{]*\{[^}]*\}' \
        | sed -E 's/^[^{]*\{//; s/port [0-9]+//g' \
        | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]*:[0-9a-fA-F:]+' \
        | sort -u | tr '\n' ' ' | sed 's/ $//'
}

if [ ${#MANUAL_ZONES[@]} -gt 0 ]; then
    for z in "${MANUAL_ZONES[@]}"; do
        REASON["$z"]="MANUAL"
    done
else
    if ! as_root test -f "$LOGFILE"; then
        echo "Error: Log file $LOGFILE does not exist!"
        exit 1
    fi

    if [ -n "$AUTO" ]; then
        echo "Searching for zones failing to refresh from any primary in $LOGFILE..."
    else
        echo "Searching for zones with primary $TARGET_IP in $LOGFILE..."
    fi
    LOGDATA="$(read_log)"

    mapfile -t RETRY_ZONES    < <(printf '%s\n' "$LOGDATA" | extract_zones "$RETRY_RE")
    mapfile -t DISABLED_ZONES < <(printf '%s\n' "$LOGDATA" | extract_zones "$DISABLED_RE")

    # Validate domain names and merge (a zone may appear in both lists)
    for z in "${RETRY_ZONES[@]}"; do
        is_domain "$z" && REASON["$z"]="RETRY"
    done
    for z in "${DISABLED_ZONES[@]}"; do
        is_domain "$z" && REASON["$z"]="DISABLED"
    done

    if [ ${#REASON[@]} -eq 0 ]; then
        echo "No zones with problems${TARGET_IP:+ against $TARGET_IP} found."
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

# Check a zone against ALL its primaries and combine the answers:
#   ACTIVE   = at least one primary serves the zone -> it is alive somewhere, leave it
#   GONE     = every primary says it doesn't have the zone
#   TIMEOUT  = no primary answers
#   MIXED    = some say GONE, some don't answer -> can't be sure, leave it
#   OTHER(x) = an unexpected answer from at least one primary -> leave it
#   UNKNOWN  = no primary known
check_all_primaries() {
    local zone="$1" ip res gone=0 timeout=0 other=""
    shift
    [ $# -eq 0 ] && { echo "UNKNOWN"; return; }
    for ip in "$@"; do
        res="$(check_primary "$zone" "$ip")"
        case "$res" in
            ACTIVE)  echo "ACTIVE"; return ;;
            GONE)    gone=$((gone + 1)) ;;
            TIMEOUT) timeout=$((timeout + 1)) ;;
            *)       other="$res" ;;
        esac
    done
    if [ -n "$other" ]; then echo "$other"
    elif [ "$timeout" -eq 0 ]; then echo "GONE"
    elif [ "$gone" -eq 0 ]; then echo "TIMEOUT"
    else echo "MIXED"
    fi
}

# Does the zone still exist on this slave?
zone_exists_locally() {
    as_root rndc zonestatus "$1" >/dev/null 2>&1
}

TO_REMOVE=()
SKIPPED=()
declare -A LIVE=()

echo
printf "%-40s %-9s %-10s %s\n" "ZONE" "SOURCE" "PRIMARY" "ACTION"
printf "%-40s %-9s %-10s %s\n" "----" "------" "-------" "------"
for ZONE in $(printf '%s\n' "${!REASON[@]}" | sort); do
    why="${REASON[$ZONE]}"
    if ! zone_exists_locally "$ZONE"; then
        printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "-" "skip (no longer exists locally)"
        continue
    fi
    # The zone's configured primaries decide, not the log
    PRIMARY["$ZONE"]="$(primaries_from_showzone "$ZONE")"
    if [ -n "$TARGET_IP" ]; then
        if [ -z "${PRIMARY[$ZONE]}" ]; then
            PRIMARY["$ZONE"]="$TARGET_IP"   # config not readable: fall back to the log's primary
        elif [[ " ${PRIMARY[$ZONE]} " != *" $TARGET_IP "* ]]; then
            printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "-" "skip (zone now uses primary ${PRIMARY[$ZONE]}, not $TARGET_IP)"
            SKIPPED+=("$ZONE")
            continue
        fi
    elif [ -n "$AUTO" ] && [ -z "${PRIMARY[$ZONE]}" ]; then
        printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "UNKNOWN" "skip (primary not found in zone config)"
        SKIPPED+=("$ZONE")
        continue
    fi
    # shellcheck disable=SC2086  # word-split the space separated primaries on purpose
    live="$(check_all_primaries "$ZONE" ${PRIMARY[$ZONE]})"
    action="REMOVE"
    case "$live" in
        ACTIVE)
            if [ "$why" == "MANUAL" ] && [ -n "$FORCE" ]; then
                action="REMOVE"
            elif [ "$why" == "MANUAL" ]; then
                action="skip (still served by a primary: ${PRIMARY[$ZONE]}, add 'force')"
            else
                action="skip (active on primary again)"
            fi ;;
        MIXED)
            action="skip (some primaries say gone, others don't answer)" ;;
        UNKNOWN)
            # Zone given by name but primary could not be read - the user asked explicitly
            action="REMOVE" ;;
        TIMEOUT)
            # A timeout is only enough for RETRY zones (original behaviour).
            # A DISABLED or named zone that suddenly times out suggests a network problem.
            if [ "$why" == "DISABLED" ] || { [ "$why" == "MANUAL" ] && [ -z "$FORCE" ]; }; then
                action="skip (primary not answering right now)"
            fi ;;
        OTHER*)
            if [ "$why" == "MANUAL" ] && [ -n "$FORCE" ]; then
                action="REMOVE"
            else
                action="skip (unexpected answer, check manually)"
            fi ;;
    esac
    printf "%-40s %-9s %-10s %s\n" "$ZONE" "$why" "$live" "$action"
    LIVE["$ZONE"]="$live"
    if [ "$action" == "REMOVE" ]; then TO_REMOVE+=("$ZONE"); else SKIPPED+=("$ZONE"); fi
done
echo

if [ ${#TO_REMOVE[@]} -eq 0 ]; then
    echo "No zones to remove."
    exit 0
fi

# Safety check, per primary: if 10+ zones of the same primary are only being removed
# because it times out, that primary is probably down - don't wipe its zones.
SAFETY_HELD=0
declare -A TIMEOUT_BY_PRIMARY=()
for ZONE in "${TO_REMOVE[@]}"; do
    [ "${LIVE[$ZONE]}" == "TIMEOUT" ] || continue
    k="${PRIMARY[$ZONE]:-unknown}"
    TIMEOUT_BY_PRIMARY["$k"]=$(( ${TIMEOUT_BY_PRIMARY["$k"]:-0} + 1 ))
done
for k in "${!TIMEOUT_BY_PRIMARY[@]}"; do
    n="${TIMEOUT_BY_PRIMARY[$k]}"
    [ "$n" -ge 10 ] || continue
    echo "WARNING: $n zones where primary $k does not answer at all. Is it down?"
    if [[ "$DRYRUN" == "dryrun" ]]; then
        echo "  (a real run would ask before removing them, or hold them back without a terminal)"
        continue
    fi
    keep=0
    if interactive; then
        read -r -p "Type 'YES' to remove these $n zones anyway: " confirm
        [ "$confirm" == "YES" ] && keep=1
    fi
    if [ "$keep" -eq 0 ]; then
        echo "  Holding back the $n zones of primary $k."
        log_sys "held back $n zones: primary $k timing out - may be down"
        NEW=()
        for ZONE in "${TO_REMOVE[@]}"; do
            if [ "${LIVE[$ZONE]}" == "TIMEOUT" ] && [ "${PRIMARY[$ZONE]:-unknown}" == "$k" ]; then
                SKIPPED+=("$ZONE")
            else
                NEW+=("$ZONE")
            fi
        done
        TO_REMOVE=("${NEW[@]}")
        SAFETY_HELD=$((SAFETY_HELD + n))
    fi
done
if [ ${#TO_REMOVE[@]} -eq 0 ]; then
    echo "No zones to remove."
    [ "$SAFETY_HELD" -gt 0 ] && exit 2
    exit 0
fi

if [[ "$DRYRUN" == "dryrun" ]]; then
    echo "DRY-RUN MODE ENABLED! No changes will be made."
    for ZONE in "${TO_REMOVE[@]}"; do
        echo "[DRY-RUN] Would run: rndc delzone $DELETE_FLAG $ZONE"
    done
    echo "Dry-run complete. ${#TO_REMOVE[@]} zone(s) would be removed, ${#SKIPPED[@]} skipped."
    exit 0
fi

# Zone file paths for a zone (zone file + journal), as absolute paths
BIND_DIR=""
bind_directory() {
    if [ -z "$BIND_DIR" ]; then
        BIND_DIR="$(as_root named-checkconf -p 2>/dev/null | sed -nE 's/^[[:space:]]*directory[[:space:]]+"([^"]+)".*/\1/p' | head -n1)"
        [ -z "$BIND_DIR" ] && BIND_DIR="/var/cache/bind"
    fi
    echo "$BIND_DIR"
}
zone_files() {
    local f
    f="$(as_root rndc showzone "$1" 2>/dev/null | sed -nE 's/.*[[:space:]]file[[:space:]]+"([^"]+)".*/\1/p' | head -n1)"
    [ -z "$f" ] && return
    [[ "$f" != /* ]] && f="$(bind_directory)/$f"
    echo "$f"
    echo "$f.jnl"
}

REMOVED=0
FAILED=0
for ZONE in "${TO_REMOVE[@]}"; do
    echo "Removing zone: $ZONE (${REASON[$ZONE]}) with rndc delzone $DELETE_FLAG"
    mapfile -t FILES < <(zone_files "$ZONE")

    # shellcheck disable=SC2086  # DELETE_FLAG is either empty or -clean
    if ! as_root rndc delzone $DELETE_FLAG "$ZONE"; then
        echo "  ERROR: rndc delzone failed for $ZONE"
        log_sys "FAILED to remove zone $ZONE (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Verify the zone is gone from BIND (delzone can take a moment)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        zone_exists_locally "$ZONE" || break
        sleep 0.5
    done
    if zone_exists_locally "$ZONE"; then
        echo "  ERROR: $ZONE is still loaded in BIND"
        log_sys "FAILED: zone $ZONE still loaded after rndc delzone"
        FAILED=$((FAILED + 1))
        continue
    fi

    # With -clean BIND deletes the files when the zone is unloaded. Make sure they are gone.
    if [ -n "$DELETE_FLAG" ]; then
        for f in "${FILES[@]}"; do
            for _ in 1 2 3 4 5 6; do as_root test -e "$f" || break; sleep 0.5; done
            if as_root test -e "$f"; then
                as_root rm -f -- "$f" && echo "  Deleted leftover file $f"
            fi
        done
        echo "  OK: zone removed and zone files deleted"
        log_sys "removed zone $ZONE and its files (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
    else
        echo "  OK: zone removed, zone files kept${FILES[0]:+ (${FILES[0]})}"
        log_sys "removed zone $ZONE, files kept (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
    fi
    REMOVED=$((REMOVED + 1))
done

# rndc delzone takes effect immediately; no rndc reload needed.
echo "Cleanup completed! Removed: $REMOVED, failed: $FAILED, skipped: ${#SKIPPED[@]}."
[ "$FAILED" -gt 0 ] && exit 1
[ "$SAFETY_HELD" -gt 0 ] && exit 2
exit 0