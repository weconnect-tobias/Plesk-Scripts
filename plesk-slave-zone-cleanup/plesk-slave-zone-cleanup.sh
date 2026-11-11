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
# Options can be given in any order.
#
# Install, schedule and update (needs sudo):
#   plesk-slave-zone-cleanup install [--interval 1h] [--keep-files|--delete-files]
#                                    [--auto-update|--no-auto-update] [--ref main]
#       Installs missing packages (dig, logger) on Debian/Ubuntu, RHEL/Fedora, SUSE,
#       Arch and Alpine, copies the script to /usr/local/sbin and schedules it with a
#       systemd timer (or cron). Run again to change settings.
#   plesk-slave-zone-cleanup update      Update from GitHub (only if the download is valid)
#   plesk-slave-zone-cleanup status      Settings, next run and last runs
#   plesk-slave-zone-cleanup uninstall   Remove schedule, settings and script
#   plesk-slave-zone-cleanup version
#
#   One-line install: wget -qO- <raw URL> | sudo bash -s install
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

# ---------------------------------------------------------------------------
# Installation, updates and scheduling
# ---------------------------------------------------------------------------

VERSION="1.0.0"
REPO_RAW="${PSZC_REPO_RAW:-https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts}"   # override only for testing
SCRIPT_PATH="/usr/local/sbin/plesk-slave-zone-cleanup"
CONF_FILE="/etc/plesk-slave-zone-cleanup.conf"
UNIT_DIR="/etc/systemd/system"
CRON_FILE="/etc/cron.d/plesk-slave-zone-cleanup"
MARKER="plesk-slave-zone-cleanup"        # must appear in a downloaded file before we install it

die()  { echo "Error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

# Re-run ourselves as root for management commands
need_root() {
    [ "$(id -u)" -eq 0 ] && return
    if [ -f "$0" ] && command -v sudo >/dev/null 2>&1; then
        exec sudo -- bash "$0" "$@"
    fi
    die "run this as root or with sudo"
}

# Which init system do we schedule with?
has_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

# Package manager and the package that provides dig on this distro
pkg_manager() {
    local pm
    for pm in apt-get dnf yum zypper pacman apk; do
        command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return; }
    done
}
dig_package() {
    case "$1" in
        apt-get)
            # Ubuntu 20.04+/Debian 11+: bind9-dnsutils; older: dnsutils
            if apt-cache show bind9-dnsutils >/dev/null 2>&1; then echo bind9-dnsutils; else echo dnsutils; fi ;;
        dnf|yum|zypper) echo bind-utils ;;
        pacman)         echo bind ;;
        apk)            echo bind-tools ;;
    esac
}
pkg_install() {
    local pm="$1"; shift
    info "Installing $* with $pm"
    case "$pm" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
        dnf)     dnf install -y -q "$@" ;;
        yum)     yum install -y -q "$@" ;;
        zypper)  zypper --non-interactive --quiet install "$@" ;;
        pacman)  pacman -S --noconfirm --needed "$@" ;;
        apk)     apk add --quiet "$@" ;;
        *)       return 1 ;;
    esac
}

# Download a URL to a file with wget or curl, whichever exists
download() {
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    else
        return 127
    fi
}

# Check that a file is a sane copy of this script
valid_script() {
    [ -s "$1" ] && head -n1 "$1" | grep -q '^#!/bin/bash' && grep -q "$MARKER" "$1" && bash -n "$1" 2>/dev/null
}

# Copy a file into place atomically (never leaves a half-written script)
put_script() {
    local tmp
    tmp="$(mktemp "$(dirname "$SCRIPT_PATH")/.${MARKER}.XXXXXX")" || return 1
    cat "$1" > "$tmp" && chmod 755 "$tmp" && chown root:root "$tmp" && mv -f "$tmp" "$SCRIPT_PATH" || { rm -f "$tmp"; return 1; }
    command -v restorecon >/dev/null 2>&1 && restorecon "$SCRIPT_PATH" 2>/dev/null
    return 0
}

load_conf() {
    REF="main"; INTERVAL="1h"; FILES="yes"; AUTO_UPDATE="no"
    # shellcheck disable=SC1090
    [ -f "$CONF_FILE" ] && . "$CONF_FILE"
}
save_conf() {
    cat > "$CONF_FILE" <<CONF
# plesk-slave-zone-cleanup settings - written by '$MARKER install'.
# Change them by running install again, e.g.: $MARKER install --interval 30min
REF="$REF"
INTERVAL="$INTERVAL"
FILES="$FILES"
AUTO_UPDATE="$AUTO_UPDATE"
CONF
    chmod 644 "$CONF_FILE"
}

# "1h", "30min", "15m" -> minutes (for cron)
interval_minutes() {
    case "$1" in
        *min) echo "${1%min}" ;;
        *m)   echo "${1%m}" ;;
        *h)   echo $(( ${1%h} * 60 )) ;;
        *)    echo "" ;;
    esac
}
cron_spec() {
    local m; m="$(interval_minutes "$1")"
    if [ "$m" -lt 60 ]; then echo "*/$m * * * *"
    else echo "$(( RANDOM % 60 )) */$(( m / 60 )) * * *"
    fi
}

remove_schedules() {
    if has_systemd; then
        systemctl disable --now "$MARKER.timer" "$MARKER-update.timer" >/dev/null 2>&1
        rm -f "$UNIT_DIR/$MARKER.service" "$UNIT_DIR/$MARKER.timer" \
              "$UNIT_DIR/$MARKER-update.service" "$UNIT_DIR/$MARKER-update.timer"
        systemctl daemon-reload
    fi
    rm -f "$CRON_FILE"
    # Alpine/BusyBox crond: entries live in root's crontab between markers
    if [ -f /etc/crontabs/root ] && grep -q "# BEGIN $MARKER" /etc/crontabs/root; then
        sed -i "/# BEGIN $MARKER/,/# END $MARKER/d" /etc/crontabs/root
    fi
}

write_schedules() {
    local run_cmd="$SCRIPT_PATH $FILES"
    local upd_cmd="$SCRIPT_PATH update --quiet"
    if has_systemd; then
        cat > "$UNIT_DIR/$MARKER.service" <<UNIT
[Unit]
Description=Remove stale Plesk slave zones from BIND
After=network-online.target named.service bind9.service named-chroot.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$run_cmd
# 2 = zones held back by the "primary may be down" safety check, not a failure
SuccessExitStatus=2
Nice=10
UNIT
        cat > "$UNIT_DIR/$MARKER.timer" <<UNIT
[Unit]
Description=Run $MARKER every $INTERVAL

[Timer]
OnBootSec=10min
OnUnitActiveSec=$INTERVAL
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        if [ "$AUTO_UPDATE" == "yes" ]; then
            cat > "$UNIT_DIR/$MARKER-update.service" <<UNIT
[Unit]
Description=Update $MARKER from GitHub ($REF)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$upd_cmd
UNIT
            cat > "$UNIT_DIR/$MARKER-update.timer" <<UNIT
[Unit]
Description=Daily update of $MARKER

[Timer]
OnCalendar=*-*-* 04:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
        fi
        command -v restorecon >/dev/null 2>&1 && restorecon "$UNIT_DIR"/"$MARKER"* 2>/dev/null
        systemctl daemon-reload
        systemctl enable --now "$MARKER.timer" >/dev/null || die "could not enable $MARKER.timer"
        if [ "$AUTO_UPDATE" == "yes" ]; then
            systemctl enable --now "$MARKER-update.timer" >/dev/null || die "could not enable $MARKER-update.timer"
        fi
        info "Scheduled with systemd timer(s)"
    elif [ -d /etc/cron.d ] && ! command -v apk >/dev/null 2>&1; then
        {
            echo "# Installed by '$MARKER install' - change with '$MARKER install ...', not by hand"
            echo "SHELL=/bin/bash"
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "$(cron_spec "$INTERVAL") root $run_cmd >/dev/null 2>&1"
            [ "$AUTO_UPDATE" == "yes" ] && echo "$(( RANDOM % 60 )) 4 * * * root $upd_cmd >/dev/null 2>&1"
        } > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        info "Scheduled with cron ($CRON_FILE)"
    elif [ -d /etc/crontabs ]; then
        {
            echo "# BEGIN $MARKER"
            echo "$(cron_spec "$INTERVAL") $run_cmd >/dev/null 2>&1"
            [ "$AUTO_UPDATE" == "yes" ] && echo "$(( RANDOM % 60 )) 4 * * * $upd_cmd >/dev/null 2>&1"
            echo "# END $MARKER"
        } >> /etc/crontabs/root
        info "Scheduled in /etc/crontabs/root (BusyBox crond)"
        command -v rc-service >/dev/null 2>&1 && ! rc-service crond status >/dev/null 2>&1 && \
            warn "crond is not running: rc-update add crond && rc-service crond start"
    else
        die "found neither systemd nor cron - schedule '$run_cmd' yourself"
    fi
}

# Where named logs on this host (used by the main run and shown by install/status)
log_source() {
    if [ -n "${LOGFILE:-}" ]; then echo "$LOGFILE"; return; fi
    local f
    for f in /var/log/syslog /var/log/messages; do
        as_root test -s "$f" && { echo "$f"; return; }
    done
    command -v journalctl >/dev/null 2>&1 && { echo "journal"; return; }
    echo ""
}

cmd_install() {
    local new_ref="" new_interval="" new_files="" new_auto="" src=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval)       new_interval="${2:-}"; shift ;;
            --interval=*)     new_interval="${1#*=}" ;;
            --ref)            new_ref="${2:-}"; shift ;;
            --ref=*)          new_ref="${1#*=}" ;;
            --keep-files)     new_files="no" ;;
            --delete-files)   new_files="yes" ;;
            --auto-update)    new_auto="yes" ;;
            --no-auto-update) new_auto="no" ;;
            *) die "unknown install option: $1" ;;
        esac
        shift
    done
    load_conf     # keep earlier settings unless overridden
    REF="${new_ref:-$REF}"; INTERVAL="${new_interval:-$INTERVAL}"
    FILES="${new_files:-$FILES}"; AUTO_UPDATE="${new_auto:-$AUTO_UPDATE}"

    [[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "invalid --ref '$REF'"
    local mins; mins="$(interval_minutes "$INTERVAL")"
    [[ "$mins" =~ ^[0-9]+$ ]] && [ "$mins" -ge 5 ] && [ "$mins" -le 1440 ] \
        || die "invalid --interval '$INTERVAL' (use e.g. 15min, 30min, 1h, 6h; 5min-24h)"
    if [ "$mins" -ge 60 ] && [ $(( mins % 60 )) -ne 0 ]; then
        die "--interval over an hour must be whole hours (e.g. 2h)"
    fi
    INTERVAL="$( [ "$mins" -ge 60 ] && echo "$(( mins / 60 ))h" || echo "${mins}min" )"

    info "$MARKER $VERSION - installing on $( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || uname -s)"

    # 1. Dependencies
    local pm missing=()
    pm="$(pkg_manager)"
    command -v bash >/dev/null 2>&1 || die "bash is required"
    command -v rndc >/dev/null 2>&1 || die "rndc not found - is BIND installed? This script runs on the secondary nameservers."
    command -v dig  >/dev/null 2>&1 || missing+=("$(dig_package "$pm")")
    command -v logger >/dev/null 2>&1 || case "$pm" in
        apt-get) missing+=(bsdutils) ;; apk) missing+=(util-linux-misc) ;; *) missing+=(util-linux) ;; esac
    if [ "$AUTO_UPDATE" == "yes" ] && ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        missing+=(wget)
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        [ -n "$pm" ] || die "missing ${missing[*]} and no known package manager found - install them by hand"
        pkg_install "$pm" "${missing[@]}" || die "could not install ${missing[*]}"
    fi
    command -v dig >/dev/null 2>&1 || die "dig is still missing after installing $(dig_package "$pm")"
    info "Dependencies OK (rndc, dig, logger)"

    # 2. The script itself
    if [ -f "$0" ] && valid_script "$0"; then
        if [ "$(readlink -f "$0")" != "$(readlink -f "$SCRIPT_PATH" 2>/dev/null)" ]; then
            put_script "$0" || die "could not write $SCRIPT_PATH"
        fi
    else
        # Running from a pipe (wget -qO- ... | sudo bash -s install): fetch a copy
        src="$(mktemp)"
        download "$REPO_RAW/$REF/$MARKER/$MARKER.sh" "$src" || { rm -f "$src"; die "download failed (needs wget or curl)"; }
        valid_script "$src" || { rm -f "$src"; die "downloaded file is not a valid $MARKER script"; }
        put_script "$src" || { rm -f "$src"; die "could not write $SCRIPT_PATH"; }
        rm -f "$src"
    fi
    info "Installed $SCRIPT_PATH"

    # 3. Sanity checks against BIND
    if rndc status >/dev/null 2>&1; then
        info "rndc can talk to BIND"
    else
        warn "'rndc status' failed - check rndc.key / controls in named.conf. Runs will fail until this works."
    fi
    if command -v named-checkconf >/dev/null 2>&1 && \
       ! named-checkconf -p 2>/dev/null | grep -qE 'allow-new-zones[[:space:]]+(yes|true)'; then
        warn "allow-new-zones is not enabled - rndc delzone only works for zones added with rndc addzone"
    fi
    local src_log; src_log="$(log_source)"
    case "$src_log" in
        "")      warn "no syslog file and no journalctl found - auto mode will find nothing (set LOGFILE=...)" ;;
        journal) info "Reading named's log from the systemd journal" ;;
        *)       info "Reading named's log from $src_log" ;;
    esac

    # 4. Schedule
    save_conf
    remove_schedules
    write_schedules
    log_sys "installed $VERSION (interval $INTERVAL, files $FILES, auto-update $AUTO_UPDATE, ref $REF)"

    echo
    info "Done. Runs every $INTERVAL, zone files: $( [ "$FILES" == yes ] && echo deleted || echo kept ), auto-update: $AUTO_UPDATE$( [ "$AUTO_UPDATE" == yes ] && echo " (from '$REF')" )"
    echo "    See what the next run would do:  $MARKER dryrun"
    echo "    Status and last runs:            $MARKER status"
    exit 0
}

cmd_update() {
    local quiet="" new
    [ "${1:-}" == "--quiet" ] && quiet=1
    load_conf
    new="$(mktemp)"
    if ! download "$REPO_RAW/$REF/$MARKER/$MARKER.sh" "$new"; then
        rm -f "$new"; log_sys "update failed: download from $REF failed"; die "download failed"
    fi
    if ! valid_script "$new"; then
        rm -f "$new"; log_sys "update refused: downloaded file is not valid"; die "downloaded file is not a valid $MARKER script - keeping the current one"
    fi
    if cmp -s "$new" "$SCRIPT_PATH"; then
        rm -f "$new"; [ -n "$quiet" ] || info "Already up to date ($VERSION)"; exit 0
    fi
    local newver; newver="$(sed -nE 's/^VERSION="([^"]+)".*/\1/p' "$new" | head -n1)"
    put_script "$new" || { rm -f "$new"; die "could not write $SCRIPT_PATH"; }
    rm -f "$new"
    log_sys "updated $VERSION -> ${newver:-?} from $REF"
    info "Updated $VERSION -> ${newver:-?}"
    # Rewrite the schedule with the new version, in case the unit layout changed
    "$SCRIPT_PATH" install >/dev/null || warn "re-running install after update failed"
    exit 0
}

cmd_uninstall() {
    remove_schedules
    rm -f "$CONF_FILE" "$SCRIPT_PATH"
    log_sys "uninstalled"
    info "Removed schedule, $CONF_FILE and $SCRIPT_PATH. BIND and its zones are untouched."
    exit 0
}

cmd_status() {
    load_conf
    echo "$MARKER $VERSION"
    if [ -f "$CONF_FILE" ]; then
        echo "Settings: every $INTERVAL, files $FILES, auto-update $AUTO_UPDATE (ref $REF)"
    else
        echo "Not installed as a scheduled job (run: sudo $MARKER install)"
    fi
    echo "Log source: $(log_source)"
    if has_systemd && [ -f "$UNIT_DIR/$MARKER.timer" ]; then
        echo
        systemctl list-timers --all "$MARKER.timer" "$MARKER-update.timer" --no-pager 2>/dev/null
        echo
        echo "Last runs:"
        as_root journalctl -u "$MARKER.service" -u "$MARKER-update.service" -n 20 --no-pager -o short 2>/dev/null
    elif [ -f "$CRON_FILE" ] || grep -qs "# BEGIN $MARKER" /etc/crontabs/root; then
        echo; echo "cron:"; cat "$CRON_FILE" 2>/dev/null || sed -n "/# BEGIN $MARKER/,/# END $MARKER/p" /etc/crontabs/root
        echo; echo "Recent removals (syslog):"
        { as_root grep -h "$TAG" /var/log/syslog /var/log/messages 2>/dev/null || true; } | tail -n 20
    fi
    exit 0
}

case "${1:-}" in
    install)   need_root "$@"; shift; cmd_install "$@" ;;
    update)    need_root "$@"; shift; cmd_update "$@" ;;
    uninstall) need_root "$@"; shift; cmd_uninstall "$@" ;;
    status)    shift; cmd_status "$@" ;;
    version|--version) echo "$MARKER $VERSION"; exit 0 ;;
esac

# Only one cleanup run at a time
if [ "$(id -u)" -eq 0 ] && command -v flock >/dev/null 2>&1; then
    if { exec 9>"/run/$MARKER.lock"; } 2>/dev/null; then
        flock -n 9 || { echo "Another run is in progress."; exit 0; }
    fi
fi

usage() {
    echo "Usage: $(basename "$0") [IP-ADDRESS] [yes/no] [dryrun]"
    echo "       $(basename "$0") <ZONE> [ZONE...] [yes/no] [dryrun] [force]"
    echo "       $(basename "$0") install [--interval 1h] [--keep-files] [--auto-update] [--ref main]"
    echo "       $(basename "$0") update | status | uninstall | version"
    exit 1
}

LOGFILE="$(log_source)"   # syslog/messages file or "journal"; override with LOGFILE=/path ...
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
        echo "Error: '$cmd' not found. Run: sudo $MARKER install (installs what is missing)"
        exit 1
    fi
done


# Read the log: syslog/messages file (incl. the newest rotated copy) or the systemd journal.
# Uses sudo if the user lacks read access.
read_log() {
    local f rotated
    if [ "$LOGFILE" == "journal" ]; then
        # named logs with the syslog identifier "named" on every distro
        as_root journalctl --since "-2 days" --no-pager -o cat -t named 2>/dev/null
        return
    fi
    # Debian: syslog.1, RHEL: messages-YYYYMMDD (compressed copies are skipped)
    rotated="$(as_root sh -c "ls -1t '$LOGFILE'.1 '$LOGFILE'-[0-9]* 2>/dev/null | grep -v '\\.gz$' | head -n1")"
    for f in $rotated "$LOGFILE"; do
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
    if [ -z "$LOGFILE" ]; then
        echo "Error: no syslog file (/var/log/syslog, /var/log/messages) and no journalctl. Set LOGFILE=/path."
        exit 1
    elif [ "$LOGFILE" != "journal" ] && ! as_root test -f "$LOGFILE"; then
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
