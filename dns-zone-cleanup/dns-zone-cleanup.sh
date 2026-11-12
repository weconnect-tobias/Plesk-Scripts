#!/bin/bash
#
# dns-zone-cleanup - removes stale secondary (slave) zones from a BIND nameserver.
#
# Install it once on every secondary nameserver and forget about it. It works with any
# primary (Plesk, cPanel, another BIND, ...), on new and old BIND versions, with zones added
# by rndc addzone as well as zones written into named.conf.
#
# A secondary zone is stale when:
#   1. RETRY    - the primary no longer answers for it ("refresh: retry limit ... exceeded")
#   2. DISABLED - the primary answers but no longer has it ("unexpected rcode (REFUSED)",
#                 "non-authoritative answer"), e.g. DNS switched off for the domain
#   3. MOVED    - the domain is no longer delegated to this server (its NS records at the
#                 TLD point elsewhere), for 7 days in a row - even if the old primary still
#                 serves it. Checked once a day.
#   4. UNREG    - the domain no longer exists at the TLD (NXDOMAIN), for 7 days in a row
#
# 1 and 2 come from named's log and are checked live against every primary of the zone
# before anything is removed. Zones this server is primary for are never touched.
#
# Usage:
#   dns-zone-cleanup [delete|keep|archive] [dryrun] [verbose]
#       Find stale zones (log + delegation check) and remove them
#   dns-zone-cleanup <IP-ADDRESS> [delete|keep|archive] [dryrun]
#       Only zones from this primary, from the log
#   dns-zone-cleanup <ZONE> [ZONE...] [delete|keep|archive] [dryrun] [force]
#       Remove specific zone(s) directly
#   dns-zone-cleanup delegation [ZONE...]
#       Show the delegation check for all (or the given) secondary zones, change nothing
#
#   delete|yes   Delete the zone file of a removed zone (default, see --delete-files)
#   keep|no      Keep the zone file
#   archive      Move the zone file to /var/backups/dns-zone-cleanup/<time>/zones/
#   dryrun       Only show what would be done
#   verbose      Also list log zones that are already gone
#   force        Zone mode only: remove even if the primary still serves the zone
#
# How a zone is removed:
#   - added with rndc addzone: rndc delzone
#   - defined in named.conf or an included file: the zone statement is commented out with
#     "# " (backup first), named-checkconf must pass (else everything is rolled back), then
#     BIND is reloaded. Set --conf-zones skip to only report such zones instead.
#   - anything that can't be done safely is reported as "remove by hand"
#   Works without rndc showzone/zonestatus (old BIND) and even without a working rndc
#   (then only zones in config files, reloaded via systemd/init).
#
# Install, schedule and update (needs sudo):
#   dns-zone-cleanup install [--interval 1h] [--delete-files|--keep-files|--archive-files]
#                            [--conf-zones comment|skip] [--delegation on|report|off]
#                            [--delegation-days 7] [--own-ips "ip ip"] [--exclude "zone *.zone"]
#                            [--auto-update|--no-auto-update] [--ref main]
#       Installs missing packages (dig, logger) on Debian/Ubuntu, RHEL/Fedora, SUSE,
#       Arch and Alpine, copies the script to /usr/local/sbin and schedules it with a
#       systemd timer (or cron). Run again to change settings. Takes over an existing
#       plesk-slave-zone-cleanup installation (the old name of this script).
#       Mail report: [--report-email a@example.com[,b@example.com]] [--report-time 07:00]
#                    [--report-always|--report-changes] [--no-report] [--mail-from addr]
#                    [--smtp smtps://smtp.example.com:465 --smtp-user user] [--no-smtp]
#                    [--no-smtp-auth] [--smtp-tls require|try|off]   (relay without login)
#       Primary zones: [--primary-zones report|comment]  (comment = remove unambiguous
#                    stale primary zones after --delegation-days; zone files are archived)
#       Without --smtp the local sendmail is used. The SMTP password is asked for (or taken
#       from SMTP_PASSWORD=...) and stored in /etc/dns-zone-cleanup.conf (root only).
#   dns-zone-cleanup report      Mail what happened since the last report (nothing happened =
#                                no mail, unless --always / --report-always)
#       --test   send a test mail     --print   show the report instead of sending it
#   dns-zone-cleanup check       Show the installed version and the one on GitHub
#   dns-zone-cleanup update      Install the version on GitHub if it is newer (and valid)
#       --ref main (default) = the main branch; updates when VERSION in the script is raised
#       --ref latest = newest GitHub release of this script (tag dns-zone-cleanup-vX.Y.Z)
#       --ref v1.2.0 = that release only
#   dns-zone-cleanup status      Settings, next run and last runs
#   dns-zone-cleanup uninstall   Remove schedule, settings and script
#   dns-zone-cleanup version
#   dns-zone-cleanup help        The full manual (also: man dns-zone-cleanup after install)
#
#   One-line install: wget -qO- <raw URL> | sudo bash -s install
#
# Non-interactive: when there is no terminal (cron, ssh host cmd, pipes) the script never
# asks anything. Every removal is logged to /var/log/dns-zone-cleanup.log and syslog.
#
# Exit codes: 0 = OK (or nothing to do), 1 = error or a removal failed,
#             2 = zones held back by a safety check.
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

TAG="dns-zone-cleanup"
EVENT_LOG="/var/log/dns-zone-cleanup.log"   # events for the daily mail report

# Log an event to syslog/journal and to our own event log.
# Types: REMOVED FAILED HELD MANUAL PENDING STALEPRIMARY BEHIND UPDATED INSTALLED ERROR
log_event() {
    local type="$1"; shift
    logger -t "$TAG" -- "$type: $*" 2>/dev/null || true
    printf '%s %s %s %s\n' "$(date +%s)" "$(date '+%F %T')" "$type" "$*" \
        | as_root tee -a "$EVENT_LOG" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Installation, updates and scheduling
# ---------------------------------------------------------------------------

VERSION="1.2.2"
REPO_RAW="${PSZC_REPO_RAW:-https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts}"   # override only for testing
REPO_API="${PSZC_REPO_API:-https://api.github.com/repos/weconnect-tobias/Plesk-Scripts}"
TAG_PREFIX="dns-zone-cleanup-v"   # releases of this script are tagged dns-zone-cleanup-v1.2.3
SCRIPT_PATH="/usr/local/sbin/dns-zone-cleanup"
CONF_FILE="/etc/dns-zone-cleanup.conf"
UNIT_DIR="/etc/systemd/system"
CRON_FILE="/etc/cron.d/dns-zone-cleanup"
MARKER="dns-zone-cleanup"        # must appear in a downloaded file before we install it

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

# --ref values: "latest" (newest release of this script), a version ("v1.2.0" / "1.2.0",
# turned into the tag dns-zone-cleanup-v1.2.0), a full tag, or a branch ("main").
normalize_ref() {
    case "$1" in
        "")                                echo "main" ;;
        latest)                            echo "latest" ;;
        v[0-9]*.[0-9]*.[0-9]*)             echo "${TAG_PREFIX}${1#v}" ;;
        [0-9]*.[0-9]*.[0-9]*)              echo "${TAG_PREFIX}$1" ;;
        *)                                 echo "$1" ;;
    esac
}

# Version compare: true if $1 is newer than $2 (numeric x.y.z)
version_gt() {
    local IFS=. i a=() b=()
    read -r -a a <<<"${1%%[^0-9.]*}"; read -r -a b <<<"${2%%[^0-9.]*}"
    for i in 0 1 2; do
        [ "$((10#${a[i]:-0}))" -gt "$((10#${b[i]:-0}))" ] && return 0
        [ "$((10#${a[i]:-0}))" -lt "$((10#${b[i]:-0}))" ] && return 1
    done
    return 1
}

# Newest published release of this script on GitHub (tag name), empty if none.
# Drafts are not visible without a token; tags with a suffix (e.g. -rc1) are ignored.
latest_release_tag() {
    local json tag best="" bestv="0.0.0" v
    json="$(mktemp)"
    download "$REPO_API/releases?per_page=100" "$json" || { rm -f "$json"; return 1; }
    while read -r tag; do
        v="${tag#"$TAG_PREFIX"}"
        [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        version_gt "$v" "$bestv" && { best="$tag"; bestv="$v"; }
    done < <(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' "$json" | sed -E 's/.*"([^"]+)"$/\1/' | grep "^$TAG_PREFIX")
    rm -f "$json"
    echo "$best"
}

# Turn REF into something we can download from. Prints the git ref; returns 1 on failure.
resolve_ref() {
    local ref; ref="$(normalize_ref "$1")"
    if [ "$ref" == "latest" ]; then
        ref="$(latest_release_tag)" || { warn "could not ask GitHub for releases"; return 1; }
        if [ -z "$ref" ]; then
            warn "no release of $MARKER on GitHub yet - using the main branch"
            ref="main"
        fi
    fi
    echo "$ref"
}

script_version() { sed -nE 's/^VERSION="([^"]+)".*/\1/p' "$1" | head -n1; }

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

CONF_KEYS="REF INTERVAL FILES CONF_ZONES DELEGATION DELEGATION_DAYS OWN_IPS EXCLUDE_ZONES AUTO_UPDATE REPORT_EMAIL REPORT_TIME REPORT_ALWAYS MAIL_FROM SMTP_URL SMTP_TLS SMTP_USER SMTP_PASS PRIMARY_ZONES"
load_conf() {
    REF="main"; INTERVAL="1h"; FILES="delete"; CONF_ZONES="comment"; AUTO_UPDATE="no"
    DELEGATION="on"; DELEGATION_DAYS="7"; OWN_IPS=""; EXCLUDE_ZONES=""
    REPORT_EMAIL=""; REPORT_TIME="07:00"; REPORT_ALWAYS="no"
    MAIL_FROM=""; SMTP_URL=""; SMTP_TLS="require"; SMTP_USER=""; SMTP_PASS=""; PRIMARY_ZONES="report"
    # The file holds the SMTP password and is only readable by root
    if [ -f "$CONF_FILE" ]; then
        if [ -r "$CONF_FILE" ]; then
            # shellcheck disable=SC1090
            . "$CONF_FILE"
        else
            # shellcheck disable=SC1090
            . <(as_root cat "$CONF_FILE")
        fi
    fi
    case "$FILES" in yes) FILES="delete" ;; no) FILES="keep" ;; delete|keep|archive) ;; *) FILES="delete" ;; esac
    case "$CONF_ZONES" in comment|skip) ;; *) CONF_ZONES="comment" ;; esac
    case "$DELEGATION" in on|report|off) ;; *) DELEGATION="on" ;; esac
    [[ "$DELEGATION_DAYS" =~ ^[0-9]+$ ]] && [ "$DELEGATION_DAYS" -ge 1 ] || DELEGATION_DAYS=7
    case "$SMTP_TLS" in require|try|off) ;; *) SMTP_TLS="require" ;; esac
    case "$PRIMARY_ZONES" in report|comment) ;; *) PRIMARY_ZONES="report" ;; esac
}
save_conf() {
    local k
    umask 077
    {
        echo "# dns-zone-cleanup settings - written by '$MARKER install'."
        echo "# Change them by running install again, e.g.: $MARKER install --interval 30min"
        for k in $CONF_KEYS; do printf '%s=%q\n' "$k" "${!k}"; done
    } > "$CONF_FILE"
    chmod 600 "$CONF_FILE"
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
        systemctl disable --now "$MARKER.timer" "$MARKER-update.timer" "$MARKER-report.timer" >/dev/null 2>&1
        rm -f "$UNIT_DIR/$MARKER.service" "$UNIT_DIR/$MARKER.timer" \
              "$UNIT_DIR/$MARKER-update.service" "$UNIT_DIR/$MARKER-update.timer" \
              "$UNIT_DIR/$MARKER-report.service" "$UNIT_DIR/$MARKER-report.timer"
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
    local rep_cmd="$SCRIPT_PATH report"
    local rep_h="${REPORT_TIME%%:*}" rep_m="${REPORT_TIME##*:}"
    if has_systemd; then
        cat > "$UNIT_DIR/$MARKER.service" <<UNIT
[Unit]
Description=Remove stale secondary zones from BIND
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
        if [ -n "$REPORT_EMAIL" ]; then
            cat > "$UNIT_DIR/$MARKER-report.service" <<UNIT
[Unit]
Description=Daily mail report from $MARKER
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$rep_cmd
UNIT
            cat > "$UNIT_DIR/$MARKER-report.timer" <<UNIT
[Unit]
Description=Daily mail report from $MARKER

[Timer]
OnCalendar=*-*-* $REPORT_TIME:00
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
        if [ -n "$REPORT_EMAIL" ]; then
            systemctl enable --now "$MARKER-report.timer" >/dev/null || die "could not enable $MARKER-report.timer"
        fi
        info "Scheduled with systemd timer(s)"
    elif [ -d /etc/cron.d ] && ! command -v apk >/dev/null 2>&1; then
        {
            echo "# Installed by '$MARKER install' - change with '$MARKER install ...', not by hand"
            echo "SHELL=/bin/bash"
            echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            echo "$(cron_spec "$INTERVAL") root $run_cmd >/dev/null 2>&1"
            [ "$AUTO_UPDATE" == "yes" ] && echo "$(( RANDOM % 60 )) 4 * * * root $upd_cmd >/dev/null 2>&1"
            [ -n "$REPORT_EMAIL" ] && echo "$((10#$rep_m)) $((10#$rep_h)) * * * root $rep_cmd >/dev/null 2>&1"
        } > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        info "Scheduled with cron ($CRON_FILE)"
    elif [ -d /etc/crontabs ]; then
        {
            echo "# BEGIN $MARKER"
            echo "$(cron_spec "$INTERVAL") $run_cmd >/dev/null 2>&1"
            [ "$AUTO_UPDATE" == "yes" ] && echo "$(( RANDOM % 60 )) 4 * * * $upd_cmd >/dev/null 2>&1"
            [ -n "$REPORT_EMAIL" ] && echo "$((10#$rep_m)) $((10#$rep_h)) * * * $rep_cmd >/dev/null 2>&1"
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

# This script used to be called plesk-slave-zone-cleanup. Take over such an installation:
# settings, event log and report state move over, the old schedule is removed and the old
# command name becomes a link to this one.
LEGACY="plesk-slave-zone-cleanup"
LEGACY_FOUND=""
migrate_legacy() {
    if [ ! -f "/etc/$LEGACY.conf" ] && [ ! -f "$UNIT_DIR/$LEGACY.timer" ] && [ ! -f "/etc/cron.d/$LEGACY" ] \
       && ! grep -qs "# BEGIN $LEGACY" /etc/crontabs/root; then
        return 0
    fi
    LEGACY_FOUND=1
    info "Taking over the existing $LEGACY installation (the old name of this script)"
    if [ -f "/etc/$LEGACY.conf" ]; then
        if [ ! -f "$CONF_FILE" ]; then
            ( umask 077; cp -p "/etc/$LEGACY.conf" "$CONF_FILE" )
            # Release tags of the old name don't exist for the new one
            sed -i -E "s/^REF=.*$LEGACY-v.*/REF=main/" "$CONF_FILE"
        fi
        rm -f "/etc/$LEGACY.conf"
    fi
    if has_systemd; then
        systemctl disable --now "$LEGACY.timer" "$LEGACY-update.timer" "$LEGACY-report.timer" >/dev/null 2>&1
        rm -f "$UNIT_DIR/$LEGACY".service "$UNIT_DIR/$LEGACY".timer \
              "$UNIT_DIR/$LEGACY"-update.service "$UNIT_DIR/$LEGACY"-update.timer \
              "$UNIT_DIR/$LEGACY"-report.service "$UNIT_DIR/$LEGACY"-report.timer
        systemctl daemon-reload
    fi
    rm -f "/etc/cron.d/$LEGACY"
    [ -f /etc/crontabs/root ] && sed -i "/# BEGIN $LEGACY/,/# END $LEGACY/d" /etc/crontabs/root
    if [ -f "/var/log/$LEGACY.log" ]; then
        cat "/var/log/$LEGACY.log" >> "$EVENT_LOG" && rm -f "/var/log/$LEGACY.log"
    fi
    if [ -d "/var/lib/$LEGACY" ] && [ ! -d "$STATE_DIR" ]; then
        mv "/var/lib/$LEGACY" "$STATE_DIR"
    fi
    rm -f "/run/$LEGACY.lock"
}

cmd_install() {
    local new_ref="" new_interval="" new_files="" new_auto="" src=""
    local opt_deleg="" opt_ddays="" opt_own="" opt_excl="" opt_conf="" opt_email="" opt_rtime="" opt_ralways="" opt_from="" opt_smtp="" opt_suser="" opt_stls="" opt_pz=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval)       new_interval="${2:-}"; shift ;;
            --interval=*)     new_interval="${1#*=}" ;;
            --ref)            new_ref="${2:-}"; shift ;;
            --ref=*)          new_ref="${1#*=}" ;;
            --keep-files)     new_files="keep" ;;
            --delete-files)   new_files="delete" ;;
            --archive-files)  new_files="archive" ;;
            --delegation)     opt_deleg="${2:-}"; shift ;;
            --delegation=*)   opt_deleg="${1#*=}" ;;
            --delegation-days) opt_ddays="${2:-}"; shift ;;
            --delegation-days=*) opt_ddays="${1#*=}" ;;
            --own-ips)        opt_own="${2:-}"; shift ;;
            --own-ips=*)      opt_own="${1#*=}" ;;
            --exclude)        opt_excl="${2:-}"; shift ;;
            --exclude=*)      opt_excl="${1#*=}" ;;
            --no-exclude)     opt_excl="-" ;;
            --conf-zones)     opt_conf="${2:-}"; shift ;;
            --conf-zones=*)   opt_conf="${1#*=}" ;;
            --auto-update)    new_auto="yes" ;;
            --no-auto-update) new_auto="no" ;;
            --report-email)   opt_email="${2:-}"; shift ;;
            --report-email=*) opt_email="${1#*=}" ;;
            --report-time)    opt_rtime="${2:-}"; shift ;;
            --report-time=*)  opt_rtime="${1#*=}" ;;
            --report-always)  opt_ralways="yes" ;;
            --report-changes) opt_ralways="no" ;;
            --no-report)      opt_email="-" ;;
            --mail-from)      opt_from="${2:-}"; shift ;;
            --mail-from=*)    opt_from="${1#*=}" ;;
            --smtp)           opt_smtp="${2:-}"; shift ;;
            --smtp=*)         opt_smtp="${1#*=}" ;;
            --smtp-user)      opt_suser="${2:-}"; shift ;;
            --smtp-user=*)    opt_suser="${1#*=}" ;;
            --no-smtp)        opt_smtp="-" ;;
            --no-smtp-auth)   opt_suser="-" ;;
            --smtp-tls)       opt_stls="${2:-}"; shift ;;
            --smtp-tls=*)     opt_stls="${1#*=}" ;;
            --primary-zones)  opt_pz="${2:-}"; shift ;;
            --primary-zones=*) opt_pz="${1#*=}" ;;
            *) die "unknown install option: $1" ;;
        esac
        shift
    done
    migrate_legacy
    load_conf     # keep earlier settings unless overridden
    REF="${new_ref:-$REF}"; INTERVAL="${new_interval:-$INTERVAL}"
    FILES="${new_files:-$FILES}"; AUTO_UPDATE="${new_auto:-$AUTO_UPDATE}"
    if [ -n "$opt_deleg" ]; then
        case "$opt_deleg" in on|report|off) DELEGATION="$opt_deleg" ;; *) die "--delegation must be on, report or off" ;; esac
    fi
    if [ -n "$opt_ddays" ]; then
        [[ "$opt_ddays" =~ ^[0-9]+$ ]] && [ "$opt_ddays" -ge 1 ] || die "--delegation-days must be a number of days (1 or more)"
        DELEGATION_DAYS="$opt_ddays"
    fi
    if [ -n "$opt_own" ]; then
        [ "$opt_own" == "-" ] && opt_own=""
        for e in ${opt_own//,/ }; do
            [[ "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$e" == *:*:* ]] || die "invalid address in --own-ips: $e"
        done
        OWN_IPS="${opt_own//,/ }"
    fi
    if [ -n "$opt_excl" ]; then
        [ "$opt_excl" == "-" ] && opt_excl=""
        for e in ${opt_excl//,/ }; do
            [[ "$e" =~ ^[A-Za-z0-9.*?_-]+$ ]] || die "invalid pattern in --exclude: $e"
        done
        EXCLUDE_ZONES="${opt_excl//,/ }"
    fi
    if [ -n "$opt_conf" ]; then
        case "$opt_conf" in comment|skip) CONF_ZONES="$opt_conf" ;; *) die "--conf-zones must be comment or skip" ;; esac
    fi
    [ -n "$opt_email" ]   && REPORT_EMAIL="$opt_email"
    [ "$REPORT_EMAIL" == "-" ] && REPORT_EMAIL=""
    [ -n "$opt_rtime" ]   && REPORT_TIME="$opt_rtime"
    [ -n "$opt_ralways" ] && REPORT_ALWAYS="$opt_ralways"
    [ -n "$opt_from" ]    && MAIL_FROM="$opt_from"
    if [ "$opt_smtp" == "-" ]; then SMTP_URL=""; SMTP_USER=""; SMTP_PASS=""
    elif [ -n "$opt_smtp" ]; then SMTP_URL="$opt_smtp"
    fi
    if [ "$opt_suser" == "-" ]; then
        SMTP_USER=""; SMTP_PASS=""            # relay that allows this server by IP, no login
    elif [ -n "$opt_suser" ]; then
        [ "$opt_suser" != "$SMTP_USER" ] && SMTP_PASS=""
        SMTP_USER="$opt_suser"
    fi
    if [ -n "$opt_stls" ]; then
        case "$opt_stls" in require|try|off) SMTP_TLS="$opt_stls" ;; *) die "--smtp-tls must be require, try or off" ;; esac
    fi
    if [ -n "$opt_pz" ]; then
        case "$opt_pz" in report|comment) PRIMARY_ZONES="$opt_pz" ;; *) die "--primary-zones must be report or comment" ;; esac
    fi

    # Mail settings
    local email_re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' e
    if [ -n "$REPORT_EMAIL" ]; then
        for e in ${REPORT_EMAIL//,/ }; do
            [[ "$e" =~ $email_re ]] || die "invalid --report-email address '$e'"
        done
        [[ "$REPORT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "invalid --report-time '$REPORT_TIME' (use HH:MM)"
        if [ -z "$MAIL_FROM" ]; then
            # Most SMTP servers want From = the login; otherwise use the host's FQDN,
            # or the report address's domain when the host has no domain name
            local fqdn first="${REPORT_EMAIL%%,*}"
            fqdn="$(hostname -f 2>/dev/null || hostname)"
            if [[ "$SMTP_USER" =~ $email_re ]]; then MAIL_FROM="$SMTP_USER"
            elif [[ "$fqdn" == *.* ]]; then MAIL_FROM="$MARKER@$fqdn"
            else MAIL_FROM="$MARKER@${first#*@}"
            fi
        fi
        [[ "$MAIL_FROM" =~ $email_re ]] || die "invalid --mail-from address '$MAIL_FROM'"
        if [ -n "$SMTP_URL" ]; then
            [[ "$SMTP_URL" =~ ^smtps?://[A-Za-z0-9.-]+(:[0-9]+)?/?$ ]] \
                || die "invalid --smtp '$SMTP_URL' (use smtps://host:465, smtp://host:587 or smtp://host:25)"
            [[ "$SMTP_URL" == smtps://* ]] && [ "$SMTP_TLS" == "off" ] && die "--smtp-tls off can't be used with smtps:// (use smtp://)"
            if [ -n "$SMTP_USER" ] && [ "$SMTP_TLS" == "off" ]; then
                die "won't send an SMTP password without encryption - use --smtp-tls require/try, or --no-smtp-auth for a relay that allows this server by IP"
            fi
            if [ -n "$SMTP_USER" ] && [ -z "$SMTP_PASS" ]; then
                if [ -n "${SMTP_PASSWORD:-}" ]; then
                    SMTP_PASS="$SMTP_PASSWORD"
                elif interactive; then
                    read -r -s -p "SMTP password for $SMTP_USER: " SMTP_PASS; echo
                elif { : </dev/tty; } 2>/dev/null; then
                    # Installed through a pipe (wget ... | sudo bash -s install): ask on the terminal
                    printf 'SMTP password for %s: ' "$SMTP_USER" >/dev/tty
                    read -r -s SMTP_PASS </dev/tty; echo >/dev/tty
                else
                    die "SMTP password needed: run interactively or set SMTP_PASSWORD=..."
                fi
                [ -n "$SMTP_PASS" ] || die "no SMTP password given"
            fi
        elif ! command -v sendmail >/dev/null 2>&1 && [ ! -x /usr/sbin/sendmail ]; then
            die "no local mail server (sendmail) found - give an SMTP server: --smtp smtps://smtp.example.com:465 --smtp-user user@example.com"
        fi
    fi

    REF="$(normalize_ref "$REF")"
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
    if [ -n "$REPORT_EMAIL" ] && [ -n "$SMTP_URL" ] && ! command -v curl >/dev/null 2>&1; then
        missing+=(curl)    # curl speaks SMTP, so no mail server is needed
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
        local gitref; gitref="$(resolve_ref "$REF")" || die "could not find what to download for --ref $REF"
        src="$(mktemp)"
        download "$REPO_RAW/$gitref/$MARKER/$MARKER.sh" "$src" || { rm -f "$src"; die "download of $gitref failed (needs wget or curl)"; }
        valid_script "$src" || { rm -f "$src"; die "downloaded file is not a valid $MARKER script"; }
        put_script "$src" || { rm -f "$src"; die "could not write $SCRIPT_PATH"; }
        rm -f "$src"
    fi
    info "Installed $SCRIPT_PATH"
    if install_man; then info "Installed the manual page: man $MARKER (or: $MARKER help)"; fi
    if [ -n "$LEGACY_FOUND" ]; then
        ln -sfn "$SCRIPT_PATH" "/usr/local/sbin/$LEGACY"
        info "The old command $LEGACY now runs $MARKER (old backups stay in /var/backups/$LEGACY)"
    fi

    # 3. Sanity checks against BIND
    if rndc status >/dev/null 2>&1; then
        info "rndc can talk to BIND"
    else
        warn "'rndc status' failed - check rndc.key / controls in named.conf. Runs will fail until this works."
    fi
    local cfg=""
    command -v named-checkconf >/dev/null 2>&1 && cfg="$(named-checkconf -p 2>/dev/null)"
    if [ -n "$cfg" ] && ! grep -qE 'allow-new-zones[[:space:]]+(yes|true)' <<<"$cfg"; then
        info "allow-new-zones is off: zones in named.conf files are handled with --conf-zones ($CONF_ZONES)"
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
    [ -n "$LEGACY_FOUND" ] && log_event INSTALLED "took over the $LEGACY installation"
    log_event INSTALLED "$VERSION (interval $INTERVAL, zone files $FILES, conf zones $CONF_ZONES, auto-update $AUTO_UPDATE, ref $REF, report ${REPORT_EMAIL:-off})"

    echo
    info "Done. Runs every $INTERVAL, zone files: $FILES, zones in named.conf: $CONF_ZONES, delegation check: $DELEGATION ($DELEGATION_DAYS days), auto-update: $AUTO_UPDATE$( [ "$AUTO_UPDATE" == yes ] && echo " (from '$REF')" )"
    echo "    See what the next run would do:  $MARKER dryrun"
    echo "    Status and last runs:            $MARKER status"
    if [ -n "$REPORT_EMAIL" ]; then
        echo "    Mail report to $REPORT_EMAIL daily at $REPORT_TIME ($( [ "$REPORT_ALWAYS" == yes ] && echo "every day" || echo "only when something happened" ))"
        echo "    Send a test mail now:            sudo $MARKER report --test"
    fi
    exit 0
}

# update [--check] [--force] [--quiet]
#   Asks GitHub which version is available for the configured --ref and installs it
#   only if it is newer than the installed one (--force: also same/older version).
cmd_update() {
    local quiet="" check="" force="" new gitref newver
    while [ $# -gt 0 ]; do
        case "$1" in
            --quiet) quiet=1 ;;
            --check) check=1 ;;
            --force) force=1 ;;
            *) die "unknown update option: $1 (use --check, --force or --quiet)" ;;
        esac
        shift
    done
    load_conf
    gitref="$(resolve_ref "$REF")" || { log_event ERROR "update: could not reach GitHub"; die "could not reach GitHub"; }

    new="$(mktemp)"
    if ! download "$REPO_RAW/$gitref/$MARKER/$MARKER.sh" "$new"; then
        rm -f "$new"; log_event ERROR "update failed: download of $gitref failed"; die "download of $gitref failed"
    fi
    if ! valid_script "$new"; then
        rm -f "$new"; log_event ERROR "update refused: file from $gitref is not valid"
        die "downloaded file is not a valid $MARKER script - keeping the current one"
    fi
    newver="$(script_version "$new")"

    if [ -n "$check" ]; then
        rm -f "$new"
        echo "Installed: $VERSION"
        echo "GitHub:    ${newver:-?} ($gitref, from --ref $REF)"
        if version_gt "$newver" "$VERSION"; then
            echo "An update is available: sudo $MARKER update"
            exit 10
        fi
        if [ "$newver" == "$VERSION" ]; then echo "Up to date."
        else echo "The installed version is newer than the one on GitHub."
        fi
        exit 0
    fi

    if ! version_gt "$newver" "$VERSION" && [ -z "$force" ]; then
        rm -f "$new"
        if [ "$newver" == "$VERSION" ]; then
            [ -n "$quiet" ] || info "Already up to date ($VERSION, $gitref)"
        else
            [ -n "$quiet" ] || info "GitHub has $newver ($gitref), installed is $VERSION - not downgrading (use --force)"
        fi
        exit 0
    fi
    if [ -n "$force" ] && cmp -s "$new" "$SCRIPT_PATH"; then
        rm -f "$new"; [ -n "$quiet" ] || info "Installed file is identical to $gitref"; exit 0
    fi

    put_script "$new" || { rm -f "$new"; die "could not write $SCRIPT_PATH"; }
    rm -f "$new"
    log_event UPDATED "$VERSION -> ${newver:-?} ($gitref)"
    info "Updated $VERSION -> ${newver:-?} ($gitref)"
    # Rewrite the schedule with the new version, in case the unit layout changed
    "$SCRIPT_PATH" install >/dev/null || warn "re-running install after update failed"
    exit 0
}

STATE_DIR="/var/lib/dns-zone-cleanup"

# Send a mail: $1 = subject, body on stdin. Uses SMTP via curl if configured, else sendmail.
send_mail() {
    local subject="$1" msg rc e rcpts=()
    msg="$(mktemp)"
    {
        echo "From: $MAIL_FROM"
        echo "To: $REPORT_EMAIL"
        echo "Subject: $subject"
        echo "Date: $(LC_ALL=C date -R)"
        echo "Message-ID: <$(date +%s).$$.$RANDOM@$(hostname -f 2>/dev/null || hostname)>"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        echo "Auto-Submitted: auto-generated"
        echo
        cat
    } > "$msg"
    if [ -n "$SMTP_URL" ]; then
        for e in ${REPORT_EMAIL//,/ }; do rcpts+=(--mail-rcpt "$e"); done
        # Credentials go in through stdin so they never show up in ps.
        # curl config strings: escape backslashes first, then double quotes.
        local cred="$SMTP_USER:$SMTP_PASS"
        cred="${cred//\\/\\\\}"; cred="${cred//\"/\\\"}"
        local tls=()
        case "$SMTP_TLS" in
            require) tls=(--ssl-reqd) ;;   # STARTTLS on smtp://, TLS on smtps:// - or fail
            try)     tls=(--ssl) ;;        # STARTTLS if the server offers it
            off)     tls=() ;;             # plain SMTP (internal relay on port 25)
        esac
        {
            if [ -n "$SMTP_USER" ]; then printf 'user = "%s"\n' "$cred"; fi
        } | curl -sS "${tls[@]}" --crlf --connect-timeout 20 --max-time 60 -K - \
                --url "$SMTP_URL" --mail-from "$MAIL_FROM" "${rcpts[@]}" -T "$msg"
        rc=$?
    else
        local sm; sm="$(command -v sendmail || echo /usr/sbin/sendmail)"
        "$sm" -oi -t < "$msg"
        rc=$?
    fi
    rm -f "$msg"
    return $rc
}

# ---------------------------------------------------------------------------
# Text helpers for messages and the report
# ---------------------------------------------------------------------------

# "ns1.example.se ns2.example.se ns3.example.se" -> "ns1-ns3.example.se"; otherwise "a, b, c"
ns_short() {
    tr ' ' '\n' <<<"$*" | grep -v '^$' | sort -V | awk '
        { names[++n] = $0
          if (match($0, /^[a-z-]*[0-9]+\./)) {
              head = substr($0, 1, RLENGTH - 1); rest = substr($0, RLENGTH + 1)
              p = head; sub(/[0-9]+$/, "", p); d = substr(head, length(p) + 1)
              key = p "|" rest
              if (n == 1) { k = key; lo = d + 0; hi = d + 0; ok = 1; pre = p; suf = rest }
              else if (key != k || d + 0 != hi + 1) ok = 0
              else hi = d + 0
          } else ok = 0 }
        END {
            if (n >= 3 && ok) { print pre lo "-" pre hi "." suf; exit }
            for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? ", " : ""), names[i]; print ""
        }'
}

# Wrap text $2 to width $3 (default 76), first line prefixed with $1, the rest indented to match
wrap() {
    awk -v pre="$1" -v w="${3:-76}" -v t="$2" 'BEGIN {
        ind = sprintf("%" length(pre) "s", ""); n = split(t, a, " "); line = pre; empty = 1
        for (i = 1; i <= n; i++) {
            if (!empty && length(line " " a[i]) > w) { print line; line = ind a[i] }
            else { line = line (empty ? "" : " ") a[i]; empty = 0 }
        }
        print line }'
}

reason_text() {
    case "$1" in
        RETRY)    echo "its primary no longer answers for it" ;;
        DISABLED) echo "its primary no longer has it" ;;
        MOVED)    echo "the domain is no longer delegated to this server" ;;
        UNREG)    echo "the domain no longer exists" ;;
        MANUAL)   echo "removed on request" ;;
        PMOVED)   echo "the domain has moved to another primary" ;;
        PUNREG)   echo "the domain no longer exists" ;;
        *)        echo "$1" ;;
    esac
}

# What to do about a stale primary zone. $2 = "file:line" of its zone statement (or empty)
primary_todo() {
    if command -v plesk >/dev/null 2>&1; then
        echo "Switch DNS off for it in Plesk: plesk bin dns --off $1"
    elif [ -n "${2:-}" ] && [ "$2" != "-" ]; then
        echo "Remove or comment out the zone in ${2%:*} (line ${2##*:}), then run: named-checkconf && rndc reconfig"
    else
        echo "Remove the zone from this server's BIND config, then run: named-checkconf && rndc reconfig"
    fi
}

# Explanation of a primary zone's status. $1 status, $2 delegated NS, $3 detail (my_m|my_s|th_ns|th_m|th_s)
primary_what() {
    local st="$1" ns my_m my_s th_ns th_m th_s
    ns="$(ns_short "$2")"
    IFS='|' read -r my_m my_s th_ns th_m th_s <<<"${3:-}"
    case "$st" in
        UNREG)
            echo "The domain does not exist any more (expired or deleted)." ;;
        MOVED)
            if [ -n "$th_s" ] && [ "$th_m" != "$my_m" ]; then
                echo "Moved to another primary. The domain uses ${ns:-other nameservers}, and they serve a version from $th_m (serial $th_s). The copy here ($my_m, serial $my_s) is not used."
            elif [ -n "$th_s" ]; then
                echo "Probably moved. The domain uses ${ns:-other nameservers}, and they serve a newer version (serial $th_s) than this server (serial $my_s)."
            else
                echo "Moved. The domain uses ${ns:-other nameservers}. ${3:-}"
            fi ;;
        ELSEWHERE)
            echo "The domain uses ${ns:-other nameservers}, which this server's zone does not list. Their version of the zone could not be read, so it is not certain that the zone moved." ;;
        BEHIND)
            echo "The secondaries (${ns:-?}) have an older version (serial $th_s) than this server (serial $my_s). They don't get updates from here: check zone transfers and NOTIFY to them." ;;
    esac
}

cmd_report() {
    local mode="send" always="" host now last events subject parts=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --test)   mode="test" ;;
            --print)  mode="print" ;;
            --always) always=1 ;;
            *) die "unknown report option: $1 (use --test, --print or --always)" ;;
        esac
        shift
    done
    load_conf
    [ "$REPORT_ALWAYS" == "yes" ] && always=1
    [ "$mode" == "print" ] || [ -n "$REPORT_EMAIL" ] \
        || die "no report address set: sudo $MARKER install --report-email you@example.com"
    host="$(hostname -f 2>/dev/null || hostname)"

    if [ "$mode" == "test" ]; then
        printf '%s\n' "This is a test mail from $MARKER $VERSION on $host." "" \
            "Daily reports go to: $REPORT_EMAIL at $REPORT_TIME" \
            "Sent via: ${SMTP_URL:-local sendmail}${SMTP_URL:+ (TLS: $SMTP_TLS, login: ${SMTP_USER:-none})}" \
            | send_mail "[$host] $MARKER: test mail" || die "sending failed - check the SMTP settings (relay without encryption? try --smtp-tls try)"
        info "Test mail sent to $REPORT_EMAIL"
        exit 0
    fi

    # State: "<lines already reported> <time of last report>"
    mkdir -p "$STATE_DIR"
    local done_lines total state
    now="$(date +%s)"
    state="$(cat "$STATE_DIR/last-report" 2>/dev/null)"
    done_lines="${state%% *}"; last="${state##* }"
    [[ "$done_lines" =~ ^[0-9]+$ ]] || done_lines=0
    [[ "$last" =~ ^[0-9]+$ ]] && [ "$last" -gt 0 ] || last=$(( now - 86400 ))
    total="$( { wc -l < "$EVENT_LOG"; } 2>/dev/null || echo 0)"
    [ "$done_lines" -gt "$total" ] && done_lines=0          # log was trimmed or replaced
    events="$(tail -n +"$(( done_lines + 1 ))" "$EVENT_LOG" 2>/dev/null)"

    if [ -z "$events" ] && [ -z "$always" ] && [ "$mode" == "send" ]; then
        echo "$total $now" > "$STATE_DIR/last-report"
        exit 0      # nothing happened, no mail
    fi

    # Current state: stale primary zones (still served here) and secondaries waiting for removal
    local -a P_ATT=() P_BEH=() WAIT=()
    local z st since ns notified strict detail where days
    if [ -s "$STATE_DIR/primary-delegation.tsv" ]; then
        # Most certain first: moved to another primary, gone, probably moved, unclear
        while IFS=$'\t' read -r _ z st since ns notified strict detail where; do
            # Skip zones that were removed in the meantime
            dig +norec +time=2 +tries=1 SOA "$z." @127.0.0.1 2>/dev/null | grep -qE 'flags:[^;]* aa' || continue
            # Fields stay "-" when empty: IFS=tab would skip empty fields
            if [ "$st" == "BEHIND" ]; then P_BEH+=("$z"$'\t'"$st"$'\t'"$since"$'\t'"${ns:--}"$'\t'"${detail:--}"$'\t'"${where:--}")
            else P_ATT+=("$z"$'\t'"$st"$'\t'"$since"$'\t'"${ns:--}"$'\t'"${detail:--}"$'\t'"${where:--}")
            fi
        done < <(awk -F'\t' '{ p = ($2 == "MOVED" && $6 == "1") ? 1 : ($2 == "UNREG") ? 2 : ($2 == "MOVED") ? 3 : 4
                               print p "\t" $0 }' "$STATE_DIR/primary-delegation.tsv" | sort -t$'\t' -k1,1n -k2,2)
    fi
    if [ "$DELEGATION" == "on" ] && [ -s "$STATE_DIR/delegation.tsv" ]; then
        while IFS=$'\t' read -r z st since ns; do
            [[ "$since" =~ ^[0-9]+$ ]] || continue
            days=$(( (since + DELEGATION_DAYS * 86400 - now + 86399) / 86400 ))
            [ "$days" -lt 1 ] && days=1
            # Skip zones that are already gone
            dig +norec +time=2 +tries=1 SOA "$z." @127.0.0.1 2>/dev/null | grep -qE 'flags:[^;]* aa' || continue
            WAIT+=("$z"$'\t'"$st"$'\t'"$since"$'\t'"${ns:--}"$'\t'"$days")
        done < <(sort "$STATE_DIR/delegation.tsv")
    fi

    count() { grep " $1 " <<<"$events" | awk '{print $5}' | sed 's/[:,]$//' | sort -u | grep -c .; }
    local n_rem n_fail n_held n_man n_err n_upd n_inst
    n_rem=$(grep -c ' REMOVED ' <<<"$events"); n_fail=$(count FAILED); n_held=$(grep -c ' HELD ' <<<"$events")
    n_man=$(count MANUAL); n_err=$(grep -c ' ERROR ' <<<"$events")
    n_upd=$(grep -c ' UPDATED ' <<<"$events"); n_inst=$(grep -c ' INSTALLED ' <<<"$events")

    [ "$n_fail" -gt 0 ]      && parts+=("$n_fail failed")
    [ "$n_man" -gt 0 ]       && parts+=("$n_man to remove by hand")
    [ ${#P_ATT[@]} -gt 0 ]   && parts+=("${#P_ATT[@]} unused primary zone(s)")
    [ ${#P_BEH[@]} -gt 0 ]   && parts+=("${#P_BEH[@]} out of sync")
    [ "$n_held" -gt 0 ]      && parts+=("held back")
    [ "$n_err" -gt 0 ]       && parts+=("errors")
    [ "$n_rem" -gt 0 ]       && parts+=("$n_rem removed")
    [ ${#WAIT[@]} -gt 0 ]    && parts+=("${#WAIT[@]} waiting")
    [ ${#parts[@]} -eq 0 ] && { [ $((n_upd + n_inst)) -gt 0 ] && parts+=("updated") || parts+=("all OK"); }
    subject="[$host] DNS zone cleanup: $(IFS=,; echo "${parts[*]}" | sed 's/,/, /g')"

    # Event lines of a type, newest message per subject, repeated ones counted
    lines_of() {
        grep " $1 " <<<"$events" | awk '{
            t = $2 " " substr($3, 1, 5); $1 = $2 = $3 = $4 = ""; sub(/^ +/, "")
            if (!($0 in n)) order[++k] = $0
            n[$0]++; lastt[$0] = t
        } END { for (i = 1; i <= k; i++) { m = order[i]
                    print lastt[m] "\t" m (n[m] > 1 ? "  (" n[m] " times)" : "") } }'
    }
    rule() { printf '%s\n' "────────────────────────────────────────────────────────────────────────────"; }
    heading() { echo; echo "$1"; rule; }

    body() {
        local l t m z st since ns detail where days

        echo "DNS zone cleanup report for $host"
        echo "$(date -d "@$last" '+%Y-%m-%d %H:%M' 2>/dev/null) to $(date -d "@$now" '+%Y-%m-%d %H:%M' 2>/dev/null) (server time)"

        # Summary
        heading "SUMMARY"
        local any=""
        [ "$n_fail" -gt 0 ]    && { echo "  ! $n_fail zone removal(s) failed"; any=1; }
        [ "$n_man" -gt 0 ]     && { echo "  ! $n_man stale zone(s) must be removed by hand"; any=1; }
        [ ${#P_ATT[@]} -gt 0 ] && { echo "  ! ${#P_ATT[@]} zone(s) this server is primary for are no longer in use"; any=1; }
        [ ${#P_BEH[@]} -gt 0 ] && { echo "  ! ${#P_BEH[@]} zone(s) are out of sync on the secondaries"; any=1; }
        [ "$n_held" -gt 0 ]    && { echo "  ! Zones were held back because a primary did not answer"; any=1; }
        [ "$n_err" -gt 0 ]     && { echo "  ! $n_err error(s)"; any=1; }
        [ -z "$any" ]          && echo "  Nothing needs your attention."
        [ "$n_rem" -gt 0 ]     && echo "    $n_rem stale zone(s) removed"
        [ ${#WAIT[@]} -gt 0 ]  && echo "    ${#WAIT[@]} zone(s) waiting to be removed (no longer delegated here)"
        [ "$n_upd" -gt 0 ]     && echo "    Script updated to $VERSION"

        # Needs attention
        if [ "$n_fail" -gt 0 ]; then
            heading "FAILED REMOVALS"
            while IFS=$'\t' read -r t m; do wrap "  $t  " "$m"; done < <(lines_of FAILED)
        fi
        if [ "$n_man" -gt 0 ]; then
            heading "REMOVE BY HAND"
            echo "  No primary serves these zones any more, but the script could not remove"
            echo "  them safely itself."
            echo
            while IFS=$'\t' read -r t m; do wrap "  " "$m"; done < <(lines_of MANUAL)
        fi
        if [ ${#P_ATT[@]} -gt 0 ]; then
            heading "PRIMARY ZONES NO LONGER IN USE"
            echo "  This server is still primary for these zones, but the domains don't use it"
            echo "  any more. Nothing has been changed. Remove them when you have checked them."
            for l in "${P_ATT[@]}"; do
                IFS=$'\t' read -r z st since ns detail where <<<"$l"
                [ "$ns" == "-" ] && ns=""; [ "$detail" == "-" ] && detail=""; [ "$where" == "-" ] && where=""
                echo
                echo "  $z"
                wrap "    What:    " "$(primary_what "$st" "$ns" "$detail")"
                echo "    Since:   $(date -d "@$since" +%F 2>/dev/null)"
                wrap "    To do:   " "$(primary_todo "$z" "$where")"
            done
        fi
        if [ ${#P_BEH[@]} -gt 0 ]; then
            heading "OUT OF SYNC ON THE SECONDARIES"
            for l in "${P_BEH[@]}"; do
                IFS=$'\t' read -r z st since ns detail where <<<"$l"
                [ "$ns" == "-" ] && ns=""; [ "$detail" == "-" ] && detail=""
                echo
                echo "  $z"
                wrap "    What:    " "$(primary_what "$st" "$ns" "$detail")"
                echo "    Since:   $(date -d "@$since" +%F 2>/dev/null)"
            done
        fi
        if [ "$n_held" -gt 0 ]; then
            heading "HELD BACK"
            while IFS=$'\t' read -r t m; do wrap "  $t  " "$m"; done < <(lines_of HELD)
        fi
        if [ "$n_err" -gt 0 ]; then
            heading "ERRORS"
            while IFS=$'\t' read -r t m; do wrap "  $t  " "$m"; done < <(lines_of ERROR)
        fi

        # For information
        if [ "$n_rem" -gt 0 ]; then
            heading "REMOVED ZONES"
            while IFS=$'\t' read -r t m; do wrap "  $t  " "$m"; done < <(lines_of REMOVED)
        fi
        if [ ${#WAIT[@]} -gt 0 ]; then
            heading "WAITING TO BE REMOVED"
            echo "  These domains are no longer delegated to this server. Their zones are"
            echo "  removed when that has been the case for $DELEGATION_DAYS days in a row."
            echo
            for l in "${WAIT[@]}"; do
                IFS=$'\t' read -r z st since ns days <<<"$l"; [ "$ns" == "-" ] && ns=""
                if [ "$st" == "UNREG" ]; then m="domain no longer exists"; else m="uses $(ns_short "$ns")"; fi
                printf '  %-34s %s, removed in %s day(s)\n' "$z" "$m" "$days"
            done
        fi
        if [ $((n_upd + n_inst)) -gt 0 ]; then
            heading "SCRIPT"
            if [ "$n_upd" -gt 0 ]; then
                echo "  Updated: $(grep ' UPDATED ' <<<"$events" | head -n1 | awk '{print $5}') -> $VERSION"
            fi
            [ "$n_inst" -gt 0 ] && echo "  Installed or settings changed ($n_inst time(s))"
        fi

        heading "SETTINGS"
        echo "  Runs every $INTERVAL. Zone files of removed zones: $FILES."
        echo "  Delegation check: $DELEGATION ($DELEGATION_DAYS days). Zones in named.conf: $CONF_ZONES."
        echo "  Primary zones: $PRIMARY_ZONES. Auto-update: $AUTO_UPDATE."
        echo
        echo "  More on $host: dns-zone-cleanup status | dns-zone-cleanup delegation"
        echo "  Full log: $EVENT_LOG"
        echo "  $MARKER $VERSION"
    }

    if [ "$mode" == "print" ]; then
        echo "Subject: $subject"; echo; body
        exit 0
    fi
    if body | send_mail "$subject"; then
        echo "$total $now" > "$STATE_DIR/last-report"
        info "Report sent to $REPORT_EMAIL"
    else
        logger -t "$TAG" -- "ERROR: sending the daily report failed" 2>/dev/null
        die "sending the report failed - events are kept for the next report"
    fi

    # Keep the event log small
    if [ "$total" -gt 10000 ]; then
        tail -n 5000 "$EVENT_LOG" > "$EVENT_LOG.tmp" && mv -f "$EVENT_LOG.tmp" "$EVENT_LOG" \
            && echo "$(wc -l < "$EVENT_LOG") $now" > "$STATE_DIR/last-report"
    fi
    exit 0
}

cmd_uninstall() {
    remove_schedules
    rm -f "$CONF_FILE" "$SCRIPT_PATH"
    [ -L "/usr/local/sbin/$LEGACY" ] && rm -f "/usr/local/sbin/$LEGACY"
    rm -f "$MAN_FILE"; command -v mandb >/dev/null 2>&1 && mandb -q >/dev/null 2>&1
    rm -rf "$STATE_DIR"     # the event log in /var/log is kept
    logger -t "$TAG" -- "uninstalled" 2>/dev/null || true
    info "Removed schedule, $CONF_FILE and $SCRIPT_PATH. BIND and its zones are untouched."
    exit 0
}

cmd_status() {
    load_conf
    echo "$MARKER $VERSION"
    if [ -f "$CONF_FILE" ]; then
        echo "Settings: every $INTERVAL, zone files $FILES, zones in named.conf $CONF_ZONES, auto-update $AUTO_UPDATE (ref $REF)"
        echo "Delegation check: $DELEGATION after $DELEGATION_DAYS days${OWN_IPS:+, own IPs $OWN_IPS}${EXCLUDE_ZONES:+, excluded: $EXCLUDE_ZONES}"
        if as_root test -s "$STATE_DIR/delegation.tsv"; then
            echo "  Waiting (not delegated here):"
            as_root cat "$STATE_DIR/delegation.tsv" | while IFS=$'\t' read -r z st since ns; do
                echo "    $z  $st since $(date -d "@$since" +%F 2>/dev/null)  ${ns}"
            done
        fi
        if [ -n "$REPORT_EMAIL" ]; then
            echo "Report:   to $REPORT_EMAIL at $REPORT_TIME, $( [ "$REPORT_ALWAYS" == yes ] && echo "every day" || echo "only on changes" ), via ${SMTP_URL:-local sendmail}${SMTP_URL:+ (TLS $SMTP_TLS, login ${SMTP_USER:-none})}"
        else
            echo "Report:   off (enable: sudo $MARKER install --report-email you@example.com)"
        fi
    else
        echo "Not installed as a scheduled job (run: sudo $MARKER install)"
    fi
    echo "Log source: $(log_source)"
    if has_systemd && [ -f "$UNIT_DIR/$MARKER.timer" ]; then
        echo
        systemctl list-timers --all "$MARKER.timer" "$MARKER-update.timer" "$MARKER-report.timer" --no-pager 2>/dev/null
        echo
        echo "Last runs:"
        as_root journalctl -u "$MARKER.service" -u "$MARKER-update.service" -u "$MARKER-report.service" -n 20 --no-pager -o short 2>/dev/null
    elif [ -f "$CRON_FILE" ] || grep -qs "# BEGIN $MARKER" /etc/crontabs/root; then
        echo; echo "cron:"; cat "$CRON_FILE" 2>/dev/null || sed -n "/# BEGIN $MARKER/,/# END $MARKER/p" /etc/crontabs/root 2>/dev/null
    fi
    echo; echo "Recent events ($EVENT_LOG):"
    { as_root cut -d' ' -f2- "$EVENT_LOG" 2>/dev/null || echo "  none yet"; } | tail -n 15
    exit 0
}


# ---------------------------------------------------------------------------
# Manual page (installed to /usr/local/share/man/man8 by "install", shown by "help")
# ---------------------------------------------------------------------------

MAN_FILE="/usr/local/share/man/man8/dns-zone-cleanup.8"

man_page() {
cat <<'MANEOF'
.TH DNS-ZONE-CLEANUP 8 "2026-11-11" "dns-zone-cleanup VERSION_PLACEHOLDER" "System Administration"
.SH NAME
dns-zone-cleanup \- remove stale secondary zones from BIND nameservers
.SH SYNOPSIS
.B dns-zone-cleanup
.RI [ delete | keep | archive ]
.RB [ dryrun ]
.RB [ verbose ]
.br
.B dns-zone-cleanup
.I IP-ADDRESS
.RI [ delete | keep | archive ]
.RB [ dryrun ]
.br
.B dns-zone-cleanup
.I ZONE
.RI [ ZONE ...]
.RI [ delete | keep | archive ]
.RB [ dryrun ]
.RB [ force ]
.br
.B dns-zone-cleanup delegation
.RI [ ZONE ...]
.RB [ verbose ]
.br
.B dns-zone-cleanup
.BR install " [" \fIOPTIONS\fR "] | " update " | " check " | " status " | " report " | " uninstall " | " help " | " version
.SH DESCRIPTION
.B dns-zone-cleanup
is installed once on every secondary nameserver and then runs by itself. It finds
secondary (slave) zones that are no longer needed and removes them. It works with any
primary (Plesk, cPanel, another BIND server), on new and old BIND versions, and with zones
added by
.B rndc addzone
as well as zones written into
.BR named.conf .
.PP
On a primary (master) server it changes nothing by default. It checks the zones the
server is primary for and reports the ones whose domain has moved or expired.
.PP
Run it as a regular user with sudo. It uses sudo where it needs to. Running as root also works.
.SH WHAT IS STALE
.TP
.B RETRY
The primary no longer answers for the zone. Found in named's log:
"refresh: retry limit for primary ... exceeded".
.TP
.B DISABLED
The primary answers but no longer has the zone, for example after DNS was switched off for
the domain. Found in the log: "unexpected rcode (REFUSED)", "(NOTAUTH)",
"non-authoritative answer".
.TP
.B MOVED
The domain's NS records at the TLD point to other nameservers only. Checked once a day.
The zone is removed after it has been like that for 7 days in a row.
.TP
.B UNREG
The domain no longer exists at the TLD (NXDOMAIN). Same 7-day rule.
.PP
RETRY and DISABLED zones are checked live against every primary in the zone's current
config before anything is removed. A zone that any primary still serves is kept.
Zones this server is primary for are never touched by these checks.
.SH HOW A ZONE IS REMOVED
.TP
.B Added with rndc addzone
.B rndc delzone
(for example zones from Plesk Slave DNS Manager).
.TP
.B Defined in named.conf or an included file
The zone statement is commented out with "# ". The file is backed up first,
.B named-checkconf
must pass (otherwise every change is rolled back), then BIND is reloaded.
.TP
.B Cannot be done safely
Reported as "remove by hand", in the output and in the mail report.
.PP
The zone file is deleted, kept or archived, see
.BR delete ", " keep ", " archive .
.SH RUN OPTIONS
.TP
.BR delete " | " yes
Delete the zone file and journal of a removed zone (default).
.TP
.BR keep " | " no
Leave the zone file where it is.
.TP
.B archive
Move the zone file to /var/backups/dns-zone-cleanup/\fITIME\fR/zones/.
.TP
.B dryrun
Show what would be done and how, change nothing.
.TP
.B verbose
Also list zones from the log that are already gone, and OK zones in
.BR delegation .
.TP
.B force
With zone names only: remove the zone even if a primary still serves it. Primary zones are
never removed, not even with force.
.TP
.I IP-ADDRESS
Only look at log entries for this primary.
.TP
.I ZONE
Remove these zones (after the live check) instead of searching the log.
.SH COMMANDS
.TP
.B delegation
Show the delegation check for all secondary and primary zones, change nothing. Lists
only zones that are not OK; add
.B verbose
for all.
.TP
.B install
Install missing packages (dig, logger), copy the script to /usr/local/sbin, install this
manual page and schedule the cleanup with a systemd timer (or cron). Run it again to
change settings; settings you don't mention are kept. Takes over an existing
plesk-slave-zone-cleanup installation (the old name of this script).
.TP
.B check
Show the installed version and the version on GitHub. Exit status 10 when an update is
available.
.TP
.BR update " [" --force "]"
Install the version on GitHub if it is newer and the download is a valid copy of this
script.
.TP
.B status
Settings, next runs, last runs, zones waiting to be removed, latest events.
.TP
.BR report " [" --test | --print | --always "]"
Mail what happened since the last report. --test sends a test mail, --print shows the
report instead of sending it, --always sends even when nothing happened.
.TP
.B uninstall
Remove the schedule, settings, script and this manual page. BIND and its zones are
untouched.
.TP
.B help
Show this manual page.
.SH INSTALL OPTIONS
.TP
.BI --interval " TIME"
How often to run: 5min to 24h, default 1h.
.TP
.BR --delete-files " | " --keep-files " | " --archive-files
What to do with zone files of removed zones (default: delete).
.TP
.BR --conf-zones " comment | skip"
Zones in named.conf: comment them out (default), or only report them.
.TP
.BR --delegation " on | report | off"
Delegation check: remove MOVED/UNREG zones (default), only report them, or skip the check.
Use report or off on hidden secondaries that are not in the NS records.
.TP
.BI --delegation-days " N"
Days a zone must stay MOVED/UNREG before it is removed (default 7).
.TP
.BI --own-ips " \(dqIP IP\(dq"
This server's addresses, if they can't be seen on the interfaces (NAT).
.TP
.BI --exclude " \(dqZONE PATTERN\(dq"
Zones that are never touched, shell patterns allowed (*.example.se).
.BR --no-exclude " clears the list."
.TP
.BR --primary-zones " report | comment"
On a primary: only report stale primary zones (default), or also comment out unambiguous
ones (UNREG, or MOVED to another primary) after --delegation-days. Their zone files are
always archived. Nothing is removed on Plesk servers.
.TP
.BR --auto-update " | " --no-auto-update
Update daily around 04:00.
.TP
.BI --ref " main | latest | vX.Y.Z"
Where updates come from: the main branch (default, follows VERSION in the script), the
newest GitHub release of this script, or one fixed release.
.SH MAIL REPORT
.TP
.BI --report-email " ADDRESS[,ADDRESS]"
Send a daily report when something happened. --no-report turns it off.
.TP
.BI --report-time " HH:MM"
When to send it (default 07:00, server time).
.TP
.BR --report-always " | " --report-changes
Mail every day, or only when something happened (default).
.TP
.BI --smtp " URL"
smtps://host:465, smtp://host:587 or smtp://host:25. Without --smtp the local sendmail is used.
.BR --no-smtp " goes back to sendmail."
.TP
.BI --smtp-user " USER"
Log in. The password is asked for (or taken from SMTP_PASSWORD) and stored in
/etc/dns-zone-cleanup.conf, readable by root only.
.TP
.B --no-smtp-auth
Don't log in: a relay that allows this server by IP address.
.TP
.BR --smtp-tls " require | try | off"
Encryption: required (default), STARTTLS if offered, or none. A password is never sent
without encryption.
.TP
.BI --mail-from " ADDRESS"
Sender. Default: the SMTP login, otherwise dns-zone-cleanup@\fIHOST\fR.
.SH SAFETY
.IP \(bu 2
If 10 or more zones of one primary would be removed only because it times out, they are
held back: the primary may simply be down. Interactively you are asked first.
.IP \(bu 2
If more than half of the zones look "not delegated here", the script assumes its own
addresses are wrong and removes nothing (see --own-ips).
.IP \(bu 2
Only registered domains are checked by the delegation check, not sub-zones, *.arpa or
private names like .local.
.IP \(bu 2
Config files are backed up before they are changed and restored if named-checkconf fails.
.IP \(bu 2
Only one run at a time. Without a terminal (cron, ssh) nothing is ever asked.
.SH FILES
.TP
.I /usr/local/sbin/dns-zone-cleanup
The script.
.TP
.I /etc/dns-zone-cleanup.conf
Settings, written by install (root only).
.TP
.I /var/log/dns-zone-cleanup.log
Every removal, failure and report event. Also in syslog with the tag dns-zone-cleanup.
.TP
.I /var/lib/dns-zone-cleanup/
State: delegation check results, last report.
.TP
.I /var/backups/dns-zone-cleanup/TIME/
Backups of changed config files (config/) and archived zone files (zones/).
.SH ENVIRONMENT
.TP
.B LOGFILE
Read this log instead of /var/log/syslog, /var/log/messages or the journal.
.TP
.B NAMED_CONF
Use this named.conf (found automatically, also in a chroot).
.TP
.B SMTP_PASSWORD
SMTP password for a scripted install.
.SH EXIT STATUS
.TP
.B 0
OK, or nothing to do.
.TP
.B 1
Error, or a removal failed.
.TP
.B 2
Zones held back by a safety check.
.SH EXAMPLES
.TP
Install with a daily mail report:
.nf
wget -qO- https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/dns-zone-cleanup/dns-zone-cleanup.sh \\
  | sudo bash -s install --report-email ops@example.com \\
    --smtp smtps://smtp.example.com:465 --smtp-user noreply@example.com
.fi
.TP
See what the next run would do:
.B dns-zone-cleanup dryrun
.TP
Remove one zone on every secondary:
.nf
for ns in ns1 ns2 ns3; do ssh $ns dns-zone-cleanup example.se delete; done
.fi
.TP
Relay without login:
.nf
sudo dns-zone-cleanup install --report-email ops@example.com \\
  --smtp smtp://relay.example.com:25 --no-smtp-auth --smtp-tls try --mail-from dns@example.com
.fi
.SH SEE ALSO
.BR named (8),
.BR rndc (8),
.BR named-checkconf (8),
.BR dig (1)
.PP
https://github.com/weconnect-tobias/Plesk-Scripts/tree/main/dns-zone-cleanup
.SH LICENSE
MIT.
MANEOF
}

# The page with the right version in it
man_text() { man_page | sed "s/VERSION_PLACEHOLDER/$VERSION/"; }

# Is "man" usable? (minimized Ubuntu replaces it with a stub that only prints a notice)
man_works() {
    command -v man >/dev/null 2>&1 || return 1
    ! grep -qs "minimized" "$(command -v man)"
}

# Turn the troff page into plain text, for systems without a working man:
# text is collected into paragraphs and wrapped, .nf/.fi blocks are kept as they are.
man_plain() {
    man_text | awk -v W="${COLUMNS:-80}" '
        function clean(s) { gsub(/\\f[BIRP]/, "", s); gsub(/\\-/, "-", s); gsub(/\\\(bu/, "*", s)
                            gsub(/\\\(dq/, "\"", s); gsub(/\\\\/, "\\", s); return s }
        # Arguments of a font macro; alternating macros (.BR etc.) join them without spaces
        function args(line, alt,   out, n, a, i, rest, q) {
            out = ""; rest = line
            while (length(rest) > 0) {
                sub(/^ +/, "", rest); if (rest == "") break
                if (substr(rest, 1, 1) == "\"") { q = index(substr(rest, 2), "\""); a = substr(rest, 2, q - 1); rest = substr(rest, q + 2) }
                else { n = index(rest, " "); if (n == 0) { a = rest; rest = "" } else { a = substr(rest, 1, n - 1); rest = substr(rest, n + 1) } }
                out = out (alt || out == "" ? "" : " ") a
            }
            return out
        }
        function add(t) { t = clean(t); if (t == "") return; buf = (buf == "" ? t : buf " " t) }
        function flush(   n, w, i, line, pre) {
            if (buf == "") return
            n = split(buf, w, " "); line = ""; pre = sprintf("%" ind "s", "")
            for (i = 1; i <= n; i++) {
                if (length(pre line " " w[i]) > W && line != "") { print pre line; line = w[i] }
                else line = (line == "" ? w[i] : line " " w[i])
            }
            if (line != "") print pre line
            buf = ""
        }
        BEGIN { ind = 7 }
        /^\.TH/ { next }
        /^\.SH/ { flush(); sub(/^\.SH +/, ""); gsub(/"/, ""); print ""; print $0; ind = 7; next }
        /^\.(PP|LP|P)( |$)/ { flush(); print ""; ind = 7; next }
        /^\.br/ { flush(); next }
        /^\.TP/ { flush(); print ""; tag = 1; next }
        /^\.IP/ { flush(); print ""; ind = 7; buf = "*"; ind2 = 9; next }
        /^\.nf/ { flush(); nf = 1; next }
        /^\.fi/ { nf = 0; next }
        nf { print sprintf("%" (ind + 2) "s", "") clean($0); next }
        /^\.(BR|RB|IR|RI|BI|IB) / { m = substr($0, 2, 2); t = args(substr($0, 5), 1) }
        /^\.(B|I) / { t = args(substr($0, 4), 0) }
        /^\.[A-Z]/ { add(t); t = ""; if (tag) { ind = 2; flush(); ind = 11; tag = 0 } next }
        { add($0); if (tag) { ind = 2; flush(); ind = 11; tag = 0 } }
        END { flush() }
    ' | cat -s
}

cmd_help() {
    if man_works; then
        man -l <(man_text) 2>/dev/null && return
    fi
    if [ -t 1 ] && command -v less >/dev/null 2>&1; then man_plain | less -R; else man_plain; fi
}

install_man() {
    mkdir -p "$(dirname "$MAN_FILE")" || return 1
    man_text > "$MAN_FILE.tmp" && chmod 644 "$MAN_FILE.tmp" && mv -f "$MAN_FILE.tmp" "$MAN_FILE" || return 1
    command -v mandb >/dev/null 2>&1 && mandb -q "$(dirname "$(dirname "$MAN_FILE")")" >/dev/null 2>&1
    command -v makewhatis >/dev/null 2>&1 && makewhatis "$(dirname "$(dirname "$MAN_FILE")")" >/dev/null 2>&1
    return 0
}

case "${1:-}" in
    help|--help|-h|man) cmd_help; exit 0 ;;
    install)   need_root "$@"; shift; cmd_install "$@" ;;
    update)    need_root "$@"; shift; cmd_update "$@" ;;
    check)     shift; cmd_update --check "$@" ;;
    uninstall) need_root "$@"; shift; cmd_uninstall "$@" ;;
    status)    shift; cmd_status "$@" ;;
    report)    need_root "$@"; shift; cmd_report "$@" ;;
    version|--version) echo "$MARKER $VERSION"; exit 0 ;;
esac

# Only one cleanup run at a time
if [ "$(id -u)" -eq 0 ] && command -v flock >/dev/null 2>&1; then
    if { exec 9>"/run/$MARKER.lock"; } 2>/dev/null; then
        flock -n 9 || { echo "Another run is in progress."; exit 0; }
    fi
fi

usage() {
    echo "Usage: $(basename "$0") [IP-ADDRESS] [delete|keep|archive] [dryrun] [verbose]"
    echo "       $(basename "$0") <ZONE> [ZONE...] [delete|keep|archive] [dryrun] [force]"
    echo "       $(basename "$0") install [--interval 1h] [--delete-files|--keep-files|--archive-files]"
    echo "               [--conf-zones comment|skip] [--auto-update] [--ref main|latest|v1.0.0]"
    echo "               [--report-email a@b.se] [--report-time 07:00] [--report-always]"
    echo "               [--smtp smtps://host:465 --smtp-user user | --no-smtp-auth] [--smtp-tls require|try|off]"
    echo "               [--mail-from addr] [--primary-zones report|comment]"
    echo "       $(basename "$0") report [--test|--print|--always]"
    echo "       $(basename "$0") check | update [--force] | status | uninstall | version"
    echo "       (yes = delete, no = keep)"
    echo
    echo "Everything explained: $(basename "$0") help   (or: man $MARKER)"
    exit 1
}

load_conf                 # FILES and CONF_ZONES defaults come from the settings file
LOGFILE="$(log_source)"   # syslog/messages file or "journal"; override with LOGFILE=/path ...
TARGET_IP=""
MANUAL_ZONES=()
FILE_ACTION=""
DRYRUN=""
FORCE=""
VERBOSE=""
DELEG_SHOW=""

is_ip()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]+$ ]]; }
row() { printf "%-40s %-9s %-10s %s\n" "$@"; }
is_domain() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}\.?$ ]]; }

for arg in "$@"; do
    a="${arg,,}"
    case "$a" in
        yes|y|delete) FILE_ACTION="delete" ;;
        no|n|keep)    FILE_ACTION="keep" ;;
        archive)      FILE_ACTION="archive" ;;
        dryrun)       DRYRUN="dryrun" ;;
        force)        FORCE="force" ;;
        verbose|-v)   VERBOSE=1 ;;
        delegation)   DELEG_SHOW=1 ;;
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

# What to do with the zone file of a removed zone?
if [ -z "$FILE_ACTION" ]; then
    if [ -n "$DRYRUN" ] || [ -n "$DELEG_SHOW" ] || ! interactive; then
        FILE_ACTION="$FILES"          # from the settings file (default: delete)
    else
        read -r -p "Zone files of removed zones: delete, keep or archive? [default: $FILES]: " ans
        case "${ans,,}" in
            "")              FILE_ACTION="$FILES" ;;
            y|yes|delete)    FILE_ACTION="delete" ;;
            n|no|keep)       FILE_ACTION="keep" ;;
            archive)         FILE_ACTION="archive" ;;
            *) echo "Error: answer delete, keep or archive."; exit 1 ;;
        esac
    fi
fi
case "$CONF_ZONES" in comment|skip) ;; *) CONF_ZONES="comment" ;; esac

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# What does this BIND support?
# ---------------------------------------------------------------------------

command -v dig >/dev/null 2>&1 || { echo "Error: 'dig' not found. Run: sudo $MARKER install (installs what is missing)"; exit 1; }

# rndc usable? (binary present, key readable, named answering)
RNDC_OK=""
if command -v rndc >/dev/null 2>&1 && as_root rndc status >/dev/null 2>&1; then
    RNDC_OK=1
fi

# Main config file
NAMED_CONF="${NAMED_CONF:-}"
if [ -z "$NAMED_CONF" ]; then
    for f in /etc/bind/named.conf /etc/named.conf /etc/namedb/named.conf /usr/local/etc/namedb/named.conf \
             /var/named/run-root/etc/named.conf /var/named/chroot/etc/named.conf; do
        as_root test -f "$f" && { NAMED_CONF="$f"; break; }
    done
fi

# BIND in a chroot (RHEL named-chroot, Plesk run-root): paths in its config are inside the chroot
CHROOT=""
case "$NAMED_CONF" in */chroot/etc/*|*/run-root/etc/*) CHROOT="${NAMED_CONF%/etc/*}" ;; esac
in_root() { if [ -n "$CHROOT" ] && [[ "$1" == /* ]] && [[ "$1" != "$CHROOT"/* ]]; then echo "$CHROOT$1"; else echo "$1"; fi; }
checkconf() {
    if [ -n "$CHROOT" ]; then as_root named-checkconf -t "$CHROOT" "${NAMED_CONF#"$CHROOT"}"
    else as_root named-checkconf "$NAMED_CONF"
    fi
}

if [ -z "$RNDC_OK" ]; then
    if [ -z "$NAMED_CONF" ]; then
        echo "Error: rndc does not work and no named.conf was found - nothing can be done on this server."
        exit 1
    fi
    echo "Note: rndc is not usable here. Only zones defined in named.conf files can be removed (BIND is reloaded via systemd/init)."
fi

# Which rndc commands does this BIND know? (showzone: 9.11+, zonestatus: 9.10+)
# Probed once with a name that can't exist; old versions answer "unknown command".
declare -A RNDC_HAS=()
for c in showzone zonestatus; do
    RNDC_HAS[$c]=no
    if [ -n "$RNDC_OK" ]; then
        probe="$(as_root rndc "$c" "$MARKER.invalid" 2>&1)"
        grep -qiE "unknown command|syntax error|unexpected token" <<<"$probe" || RNDC_HAS[$c]=yes
    fi
done
rndc_has() { [ "${RNDC_HAS[$1]:-no}" == "yes" ]; }

# ---------------------------------------------------------------------------
# Zone definitions in config files (for old BIND and zones in named.conf)
# ---------------------------------------------------------------------------

BIND_DIR=""
bind_directory() {
    if [ -z "$BIND_DIR" ]; then
        [ -z "$CHROOT" ] && BIND_DIR="$(as_root named-checkconf -p 2>/dev/null | sed -nE 's/(^|.*[{;[:space:]])directory[[:space:]]+"([^"]+)".*/\2/p' | head -n1)"
        if [ -z "$BIND_DIR" ] && [ -n "$NAMED_CONF" ]; then
            BIND_DIR="$(conf_files | while read -r f; do as_root cat "$f"; done 2>/dev/null \
                | sed -nE 's/(^|.*[{;[:space:]])directory[[:space:]]+"([^"]+)".*/\2/p' | head -n1)"
        fi
        [ -n "$BIND_DIR" ] && BIND_DIR="$(in_root "$BIND_DIR")"
        if [ -z "$BIND_DIR" ]; then
            for d in /var/cache/bind /var/named /var/lib/bind /etc/namedb; do
                as_root test -d "$d" && { BIND_DIR="$d"; break; }
            done
        fi
    fi
    echo "${BIND_DIR:-/var/cache/bind}"
}

# named.conf and every file it includes (recursively, with globs)
CONF_FILES_DONE=""
conf_files() {
    if [ -z "$CONF_FILES_DONE" ]; then
        local queue=("$NAMED_CONF") seen=" " f inc base
        : > "$TMPD/conf_files"
        while [ ${#queue[@]} -gt 0 ]; do
            f="${queue[0]}"; queue=("${queue[@]:1}")
            [[ "$seen" == *" $f "* ]] && continue
            seen+="$f "
            as_root test -f "$f" || continue
            echo "$f" >> "$TMPD/conf_files"
            base="$(dirname "$f")"
            while read -r inc; do
                if [[ "$inc" != /* ]]; then inc="$base/$inc"; else inc="$(in_root "$inc")"; fi
                # shellcheck disable=SC2086  # glob expansion wanted (BIND 9.18+ allows globs)
                for g in $inc; do queue+=("$g"); done
            done < <(as_root cat "$f" | sed -E 's://.*$::; s:#.*$::' \
                     | grep -oE '^[[:space:]]*include[[:space:]]+"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/')
        done
        CONF_FILES_DONE=1
    fi
    [ -n "$NAMED_CONF" ] && cat "$TMPD/conf_files"
}

# Find zone statements. Prints: name <TAB> file <TAB> first line <TAB> last line <TAB> clean <TAB> src
#   clean = 1 when the statement has its own lines (nothing else before/after it), so it can
#   safely be commented out. src = conf (a config file) or nzf (added with rndc addzone).
ZONE_AWK='
function strip(s) { sub(/\/\/.*/, "", s); sub(/#.*/, "", s); return s }
{
    line = $0
    if (incom) { p = index(line, "*/"); if (!p) next; line = substr(line, p + 2); incom = 0 }
    while ((p = index(line, "/*")) > 0) {
        q = index(substr(line, p + 2), "*/")
        if (q) line = substr(line, 1, p - 1) " " substr(line, p + q + 3)
        else { line = substr(line, 1, p - 1); incom = 1 }
    }
    line = strip(line)
    if (!inz) {
        if (!match(line, /(^|[[:space:];{])zone[[:space:]]+"?[A-Za-z0-9._-]+"?/)) next
        pre = substr(line, 1, RSTART - 1); m = substr(line, RSTART, RLENGTH)
        clean = (pre ~ /^[[:space:]]*$/ && m !~ /^[;{]/)
        name = m; sub(/^.*zone[[:space:]]+"?/, "", name); sub(/"$/, "", name); sub(/\.$/, "", name)
        inz = 1; start = NR; depth = 0; opened = 0; ztype = ""
        line = substr(line, RSTART + RLENGTH)
    }
    if (ztype == "" && match(line, /(^|[[:space:];{])type[[:space:]]+[a-z-]+/)) {
        ztype = substr(line, RSTART, RLENGTH); sub(/.*type[[:space:]]+/, "", ztype)
    }
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") { depth++; opened = 1 }
        else if (c == "}") depth--
        else if (c == ";" && opened && depth == 0) {
            if (substr(line, i + 1) !~ /^[[:space:]]*$/) clean = 0
            print tolower(name) "\t" F "\t" start "\t" NR "\t" clean "\t" SRC "\t" ztype
            inz = 0; break
        }
    }
}'

ZONE_INDEX_DONE=""
zone_index() {
    if [ -z "$ZONE_INDEX_DONE" ]; then
        : > "$TMPD/zones.idx"
        local f
        while read -r f; do
            as_root cat "$f" | awk -v F="$f" -v SRC=conf "$ZONE_AWK" >> "$TMPD/zones.idx"
        done < <(conf_files)
        # Zones added with rndc addzone on BIND < 9.13 live in a text .nzf file
        for f in $(as_root sh -c "ls -1 '$(bind_directory)'/*.nzf 2>/dev/null"); do
            as_root cat "$f" | awk -v F="$f" -v SRC=nzf "$ZONE_AWK" >> "$TMPD/zones.idx"
        done
        # BIND 9.13+ keeps them in an LMDB .nzd file; named-nzd2nzf prints it as text
        if command -v named-nzd2nzf >/dev/null 2>&1; then
            for f in $(as_root sh -c "ls -1 '$(bind_directory)'/*.nzd 2>/dev/null"); do
                as_root named-nzd2nzf "$f" 2>/dev/null | awk -v F="$f" -v SRC=nzd "$ZONE_AWK" >> "$TMPD/zones.idx"
            done
        fi
        ZONE_INDEX_DONE=1
    fi
    cat "$TMPD/zones.idx"
}
zone_entry() { zone_index | awk -F'\t' -v z="$1" '$1 == z { print; exit }'; }

# The zone's config as text: from rndc showzone, or from the config/nzf file
zone_config_text() {
    local out e
    if rndc_has showzone "$1"; then
        out="$(as_root rndc showzone "$1" 2>/dev/null)"
        [ -n "$out" ] && { echo "$out"; return; }
    fi
    e="$(zone_entry "$1")"
    [ -z "$e" ] && return
    IFS=$'\t' read -r _ f s l _ _ <<<"$e"
    as_root sed -n "${s},${l}p" "$f"
}

ip_tokens() { grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|[0-9a-fA-F]*:[0-9a-fA-F]*:[0-9a-fA-F:]+'; }

# All primary IPs of a zone, space separated. Resolves named lists (masters NAME { ip; };).
primaries_of() {
    local txt list tok ips=""
    txt="$(zone_config_text "$1" | tr '\n' ' ' | sed -E 's://[^;]*::g')"
    list="$(grep -oE '(primaries|masters)[^{]*\{[^}]*\}' <<<"$txt" | sed -E 's/^[^{]*\{//; s/\}$//; s/port [0-9]+//g; s/key [^;]+//g')"
    for tok in $(tr ';' ' ' <<<"$list"); do
        if [[ "$tok" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$tok" == *:*:* ]]; then
            ips+="$tok "
        elif [[ "$tok" =~ ^\"?[A-Za-z0-9_.-]+\"?$ ]]; then
            tok="${tok//\"/}"
            ips+="$(conf_files | while read -r f; do as_root cat "$f"; done | tr '\n' ' ' \
                | grep -oE "(primaries|masters)[[:space:]]+\"?$tok\"?[^{]*\{[^}]*\}" | head -n1 \
                | sed -E 's/^[^{]*\{//; s/port [0-9]+//g' | ip_tokens | tr '\n' ' ')"
        fi
    done
    tr ' ' '\n' <<<"$ips" | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Zone type from its config: primary, secondary, ... ("master"/"slave" are normalized)
zone_type() {
    local t
    t="$(zone_config_text "$1" | tr '\n' ' ' | grep -oE '[[:space:];{]type[[:space:]]+[a-z-]+' | head -n1 | awk '{print $2}')"
    case "$t" in master) t="primary" ;; slave) t="secondary" ;; esac
    echo "$t"
}

# Zone file of a zone (absolute path), plus its journal
zone_files() {
    local f
    f="$(zone_config_text "$1" | tr '\n' ' ' | sed -nE 's/.*[[:space:];{]file[[:space:]]+"([^"]+)".*/\1/p')"
    [ -z "$f" ] && return
    [[ "$f" != /* ]] && f="$(bind_directory)/$f"
    echo "$f"
    echo "$f.jnl"
}

# Does BIND on this server still serve the zone?
zone_exists_locally() {
    local out rc
    if rndc_has zonestatus "$1"; then
        out="$(as_root rndc zonestatus "$1" 2>&1)"; rc=$?
        [ $rc -eq 0 ] && return 0
        grep -qiE "not found|no matching zone" <<<"$out" && return 1
    fi
    # Old BIND or no rndc: ask named itself
    out="$(dig +norec +time=2 +tries=1 @127.0.0.1 "$1" SOA 2>/dev/null)"
    if grep -q "status: NOERROR" <<<"$out"; then
        [[ " $(sed -nE 's/.*;; flags: ([^;]*);.*/\1/p' <<<"$out" | head -n1) " == *" aa "* ]] && return 0
        return 1
    fi
    grep -qE "status: (REFUSED|NOTAUTH|NXDOMAIN)" <<<"$out" && return 1
    # No answer from 127.0.0.1 (named listens elsewhere): trust the config
    [ -n "$(zone_entry "$1")" ]
}

# ---------------------------------------------------------------------------
# Delegation check: is the domain still delegated to this server?
#   DELEGATED = one of the domain's NS records at the TLD points to an IP of this server
#   NOTHERE   = the TLD delegates the domain to other nameservers only  -> MOVED
#   UNREG     = the TLD says the domain does not exist (NXDOMAIN)        -> UNREG
#   UNKNOWN   = lookup failed (timeout etc.) - changes nothing
#   SUBZONE   = not a registered domain (sub.example.com, *.arpa, private TLD) - not checked
# A zone is only removed after it has been NOTHERE/UNREG for DELEGATION_DAYS days in a row.
# ---------------------------------------------------------------------------

# Second-level public suffixes where domains are registered (example.co.uk). Everything else
# is checked only when its parent is a TLD.
PUBLIC_SUFFIX2=" co.uk org.uk me.uk ltd.uk plc.uk net.uk ac.uk gov.uk com.au net.au org.au
 co.nz net.nz org.nz com.br net.br co.za co.jp ne.jp or.jp com.cn net.cn com.tr com.mx com.ar
 co.in net.in org.in com.sg com.my co.kr co.id co.il com.ua co.at or.at com.pl net.pl org.pl "

declare -A OWN=()
own_ips_load() {
    local ip fq
    OWN=()
    # Addresses on this server's interfaces
    for ip in $( (ip -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1) || hostname -I 2>/dev/null); do
        OWN["$ip"]=1
    done
    # Behind NAT the public address is not on an interface: use what the host name resolves to
    fq="$(hostname -f 2>/dev/null)"
    if [[ "$fq" == *.* ]]; then
        for ip in $(dig +short +time=3 +tries=1 A "$fq" 2>/dev/null; dig +short +time=3 +tries=1 AAAA "$fq" 2>/dev/null); do
            is_ip "$ip" && OWN["$ip"]=1
        done
    fi
    # And whatever was configured (--own-ips)
    for ip in ${OWN_IPS//,/ }; do OWN["$ip"]=1; done
}

declare -A PARENT_NS=()     # parent zone -> its nameservers (cache)
parent_of() {               # prints "<parent> <ns> <ns> ..." or nothing (not checked)
    local z="$1" p ns
    case "$z" in *.arpa) return ;; esac
    p="${z#*.}"
    [ "$p" == "$z" ] && return
    if [[ "$p" == *.* ]]; then
        [[ "$PUBLIC_SUFFIX2" == *" $p "* ]] || return
    fi
    if [ -z "${PARENT_NS[$p]+x}" ]; then
        ns="$(dig +short +time=3 +tries=2 NS "$p." 2>/dev/null | grep -E '\.$' | head -n 4 | tr '\n' ' ')"
        PARENT_NS["$p"]="$ns"
    fi
    [ -n "${PARENT_NS[$p]}" ] && echo "$p ${PARENT_NS[$p]}"
}

# Sets DSTATUS and DNS_LIST for zone $1
delegation_status() {
    local z="$1" info pns out st names ips n ip
    DSTATUS="SUBZONE"; DNS_LIST=""
    info="$(parent_of "$z")"
    [ -z "$info" ] && return
    DSTATUS="UNKNOWN"
    for pns in ${info#* }; do
        out="$(dig +norec +time=3 +tries=1 +noall +comments +answer +authority +additional NS "$z." @"$pns" 2>/dev/null)"
        st="$(sed -nE 's/.*status: ([A-Z]+).*/\1/p' <<<"$out" | head -n1)"
        [ -n "$st" ] && break
    done
    case "$st" in
        NXDOMAIN) DSTATUS="UNREG"; return ;;
        NOERROR)  ;;
        *)        return ;;            # timeout, SERVFAIL, ... -> UNKNOWN
    esac
    names="$(awk -v z="$z." 'tolower($1) == tolower(z) && $4 == "NS" { print tolower($5) }' <<<"$out" | sort -u)"
    [ -z "$names" ] && return          # no delegation in the answer -> UNKNOWN
    DNS_LIST="$(tr '\n' ' ' <<<"$names" | sed 's/\.\( \|$\)/\1/g; s/ $//')"
    for n in $names; do
        # Glue from the referral, else resolve the name
        ips="$(awk -v n="$n" 'tolower($1) == n && ($4 == "A" || $4 == "AAAA") { print $5 }' <<<"$out")"
        [ -z "$ips" ] && ips="$(dig +short +time=3 +tries=1 A "$n" 2>/dev/null; dig +short +time=3 +tries=1 AAAA "$n" 2>/dev/null)"
        for ip in $ips; do
            [ -n "${OWN[$ip]:-}" ] && { DSTATUS="DELEGATED"; return; }
        done
    done
    DSTATUS="NOTHERE"
}

is_excluded() {
    local pat
    for pat in ${EXCLUDE_ZONES//,/ }; do
        # shellcheck disable=SC2053  # glob match on purpose
        [[ "$1" == $pat ]] && return 0
    done
    return 1
}

# All secondary zones on this server (from config files, .nzf and .nzd)
secondary_zones() {
    zone_index | awk -F'\t' '$7 == "slave" || $7 == "secondary" { print $1 }' | sort -u
}

DELEG_STATE="$STATE_DIR/delegation.tsv"     # zone <TAB> status <TAB> since <TAB> nameservers
declare -A DELEG_INFO=()

# Runs the check (once a day, or always with $1 = force) and adds zones that have been
# MOVED/UNREG for DELEGATION_DAYS days to REASON. With $1 = show it only prints a table.
delegation_scan() {
    local mode="${1:-}" now last zones=() z total=0 bad=0 since prev st ns days_left shown_hidden=0
    declare -A OLD_ST=() OLD_SINCE=() NEW=()
    [ "$DELEGATION" == "off" ] && [ "$mode" != "show" ] && return
    now="$(date +%s)"
    last="$(as_root cat "$STATE_DIR/delegation.last" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0

    # Previous results
    if as_root test -f "$DELEG_STATE"; then
        while IFS=$'\t' read -r z st since ns; do
            OLD_ST["$z"]="$st"; OLD_SINCE["$z"]="$since"; NEW["$z"]="$z"$'\t'"$st"$'\t'"$since"$'\t'"$ns"
        done < <(as_root cat "$DELEG_STATE")
    fi

    if [ "$mode" == "show" ] || [ $(( now - last )) -ge 72000 ]; then
        own_ips_load
        if [ ${#OWN[@]} -eq 0 ]; then
            echo "Delegation check skipped: could not find this server's IP addresses (set --own-ips)."
            return
        fi
        if [ ${#MANUAL_ZONES[@]} -gt 0 ]; then zones=("${MANUAL_ZONES[@]}")
        else mapfile -t zones < <(secondary_zones)
        fi
        if [ ${#zones[@]} -eq 0 ]; then
            if ! command -v named-nzd2nzf >/dev/null 2>&1 && \
               [ -n "$(as_root sh -c "ls -1 '$(bind_directory)'/*.nzd 2>/dev/null")" ]; then
                echo "Delegation check: zones added with rndc addzone are in an .nzd file, and named-nzd2nzf (part of BIND) is missing - can't list them."
            elif [ -z "$(primary_zones | head -n1)" ]; then
                echo "Delegation check: no secondary zones found in the config."
            fi
            return
        fi
        [ "$mode" == "show" ] && { echo; echo "Secondary zones:"; row "ZONE" "STATUS" "SINCE" "NAMESERVERS AT THE TLD"; row "----" "------" "-----" "----------------------"; }
        declare -A CURRENT=()
        for z in "${zones[@]}"; do CURRENT["$z"]=1; done
        if [ ${#MANUAL_ZONES[@]} -eq 0 ]; then
            for z in "${!NEW[@]}"; do [ -n "${CURRENT[$z]:-}" ] || unset 'NEW[$z]'; done   # zone gone from this server
        fi
        for z in "${zones[@]}"; do
            is_excluded "$z" && { unset 'NEW[$z]'; [ "$mode" == "show" ] && row "$z" "EXCLUDED" "-" "-"; continue; }
            delegation_status "$z"
            case "$DSTATUS" in
                NOTHERE|UNREG)
                    total=$((total + 1)); bad=$((bad + 1))
                    since="${OLD_SINCE[$z]:-}"
                    [ "${OLD_ST[$z]:-}" == "$DSTATUS" ] && [ -n "$since" ] || since="$now"
                    NEW["$z"]="$z"$'\t'"$DSTATUS"$'\t'"$since"$'\t'"$DNS_LIST" ;;
                DELEGATED)
                    total=$((total + 1)); unset 'NEW[$z]' ;;
                UNKNOWN) ;;                       # keep whatever we knew
                SUBZONE) unset 'NEW[$z]' ;;
            esac
            if [ "$mode" == "show" ]; then
                if [[ "$DSTATUS" == DELEGATED || "$DSTATUS" == SUBZONE ]] && [ -z "$VERBOSE" ]; then
                    shown_hidden=$((shown_hidden + 1)); continue
                fi
                since="-"; [[ "$DSTATUS" == NOTHERE || "$DSTATUS" == UNREG ]] && since="$(date -d "@$(cut -f3 <<<"${NEW[$z]}")" +%F 2>/dev/null)"
                row "$z" "$DSTATUS" "$since" "${DNS_LIST:--}"
            fi
        done
        [ "$mode" == "show" ] && [ "${shown_hidden:-0}" -gt 0 ] && echo "($shown_hidden zone(s) delegated here or not checked - add 'verbose' to list them)"
        echo "Own addresses used: ${!OWN[*]}"
        # Sanity check: if most zones look "not delegated here", our own addresses are
        # probably wrong (NAT, new IP) - don't trust the result
        if [ "$total" -ge 4 ] && [ $(( bad * 2 )) -gt "$total" ]; then
            echo "WARNING: $bad of $total zones look not delegated to this server. Are the own addresses right? Nothing is removed by the delegation check."
            [ "$mode" == "show" ] || [ -n "$DRYRUN" ] || log_event ERROR "delegation check: $bad of $total zones look not delegated here (own IPs: ${!OWN[*]}) - set --own-ips; nothing removed"
            return
        fi
        if [ "$mode" != "show" ] && [ -z "$DRYRUN" ]; then
            as_root mkdir -p "$STATE_DIR"
            printf '%s\n' "${NEW[@]}" | grep -v '^$' | as_root tee "$DELEG_STATE" >/dev/null
            echo "$now" | as_root tee "$STATE_DIR/delegation.last" >/dev/null
            # Tell the report once when a zone starts to look moved
            for z in "${!NEW[@]}"; do
                IFS=$'\t' read -r _ st since ns <<<"${NEW[$z]}"
                [ "$since" == "$now" ] && log_event PENDING "$z: $( [ "$st" == UNREG ] && echo "domain no longer exists at the TLD" || echo "delegated to ${ns:-other nameservers}, not this server") - removed after $DELEGATION_DAYS days if it stays like this"
            done
        fi
    fi
    [ "$mode" == "show" ] && return

    # Zones that have been gone long enough
    for z in "${!NEW[@]}"; do
        IFS=$'\t' read -r _ st since ns <<<"${NEW[$z]}"
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        is_excluded "$z" && continue
        days_left=$(( (since + DELEGATION_DAYS * 86400 - now + 86399) / 86400 ))
        if [ "$days_left" -le 0 ]; then
            [ -n "${REASON[$z]:-}" ] && continue
            if [ "$DELEGATION" == "on" ]; then
                REASON["$z"]="$( [ "$st" == UNREG ] && echo UNREG || echo MOVED)"
                DELEG_INFO["$z"]="$( [ "$st" == UNREG ] && echo "not registered" || echo "NS: ${ns:-?}") since $(date -d "@$since" +%F 2>/dev/null)"
            elif [ -z "$DRYRUN" ]; then
                log_event MANUAL "$z: $( [ "$st" == UNREG ] && echo "no longer exists at the TLD" || echo "delegated to ${ns:-other nameservers}") since $(date -d "@$since" +%F 2>/dev/null) (delegation check is set to report)"
            fi
        else
            PENDING_LIST+=("$z ($( [ "$st" == UNREG ] && echo "not registered" || echo "NS: ${ns:-?}"), $days_left day(s) left)")
        fi
    done
}

# ---------------------------------------------------------------------------
# Primary (master) zones: report-only check for domains that have left this server.
# A master is usually not listed in the domain's NS records itself (the secondaries are),
# so here the TLD's NS records are compared with the NS records in the zone itself:
#   OURS    = the TLD delegates to (some of) the zone's own nameservers -> fine
#   MOVED   = the TLD delegates to other nameservers only -> this server serves a stale copy
#   UNREG   = the domain no longer exists at the TLD
# Nothing is ever changed for primary zones. They are listed in the output and the report,
# with the command to switch them off (Plesk) after DELEGATION_DAYS days.
# ---------------------------------------------------------------------------

primary_zones() { zone_index | awk -F'\t' '$7 == "master" || $7 == "primary" { print $1 }' | sort -u; }

# NS names of a zone as this server serves it
zone_own_ns() {
    local out ip
    for ip in 127.0.0.1 ::1 ${!OWN[@]}; do
        out="$(dig +norec +time=2 +tries=1 +noall +answer NS "$1." @"$ip" 2>/dev/null)"
        [ -n "$out" ] && break
    done
    awk -v z="$1." 'tolower($1) == tolower(z) && $4 == "NS" { print tolower($5) }' <<<"$out" | sed 's/\.$//' | sort -u
}

name_ips() { local n; for n in "$@"; do dig +short +time=3 +tries=1 A "$n" 2>/dev/null; dig +short +time=3 +tries=1 AAAA "$n" 2>/dev/null; done | sort -u; }

# SOA of zone $1 as served authoritatively by server $2: prints "<mname> <serial>"
zone_soa() {
    local out
    out="$(dig +norec +time=3 +tries=1 +noall +comments +answer SOA "$1." @"$2" 2>/dev/null)"
    grep -qE 'flags:[^;]* aa' <<<"$out" || return
    awk -v z="$1." 'tolower($1) == tolower(z) && $4 == "SOA" { print tolower($5), $7; exit }' <<<"$out" | sed 's/\. / /'
}

# Sets PSTATUS, PDETAIL and PSTRICT for primary zone $1:
#   OURS      delegated to the zone's own nameservers, or they serve this server's version
#   MOVED     the delegated nameservers serve a version from another primary (other SOA name),
#             or a newer version -> this server has a stale copy
#   BEHIND    the delegated nameservers have the same primary in their SOA but an older serial
#             -> they don't get updates from this server (zone transfer / NOTIFY broken?)
#   ELSEWHERE delegated to other nameservers, but their SOA could not be read
#   UNREG     the domain no longer exists at the TLD
# PSTRICT=1 when the evidence is unambiguous (UNREG, or MOVED with another SOA name).
primary_status() {
    local z="$1" own tld_ips own_ips n mine theirs="" theirs_ns="" my_m my_s th_m th_s
    PDETAIL=""; PSTRICT=""
    delegation_status "$z"
    case "$DSTATUS" in
        SUBZONE|UNKNOWN) PSTATUS="$DSTATUS"; return ;;
        UNREG) PSTATUS="UNREG"; PSTRICT=1; PDETAIL=""; return ;;
    esac
    own="$(zone_own_ns "$z")"
    [ -z "$own" ] && { PSTATUS="UNKNOWN"; return; }
    for n in $DNS_LIST; do
        grep -qxF "$n" <<<"$own" && { PSTATUS="OURS"; return; }
    done
    # Different names can still be the same servers (vanity nameservers)
    # shellcheck disable=SC2086
    tld_ips="$(name_ips $DNS_LIST)"; own_ips="$(name_ips $own)"
    if [ -n "$tld_ips" ] && [ -n "$own_ips" ] && [ -n "$(comm -12 <(echo "$tld_ips") <(echo "$own_ips"))" ]; then
        PSTATUS="OURS"; return
    fi
    # Compare this server's version of the zone with what the delegated nameservers serve
    mine="$(zone_soa "$z" 127.0.0.1)"
    if [ -z "$mine" ]; then for n in "${!OWN[@]}"; do mine="$(zone_soa "$z" "$n")"; [ -n "$mine" ] && break; done; fi
    for n in $DNS_LIST; do
        theirs="$(zone_soa "$z" "$n")"
        [ -n "$theirs" ] && { theirs_ns="$n"; break; }
    done
    if [ -z "$mine" ] || [ -z "$theirs" ]; then
        PSTATUS="ELSEWHERE"; PDETAIL=""; return
    fi
    read -r my_m my_s <<<"$mine"; read -r th_m th_s <<<"$theirs"
    PDETAIL="$my_m|$my_s|$theirs_ns|$th_m|$th_s"      # machine format, see primary_what
    if [ "$th_s" == "$my_s" ]; then PSTATUS="OURS"; return; fi
    if [ "$th_m" != "$my_m" ]; then PSTATUS="MOVED"; PSTRICT=1; return; fi
    if [[ "$th_s" =~ ^[0-9]+$ && "$my_s" =~ ^[0-9]+$ ]] && [ "$th_s" -lt "$my_s" ]; then
        PSTATUS="BEHIND"; return
    fi
    PSTATUS="MOVED"
}

off_hint() {
    if command -v plesk >/dev/null 2>&1; then echo "plesk bin dns --off $1"
    else echo "remove the zone from this server's config"
    fi
}

# zone <TAB> status <TAB> since <TAB> ns <TAB> notified <TAB> strict <TAB> detail <TAB> where
PRIMARY_STATE="$STATE_DIR/primary-delegation.tsv"
STALE_PRIMARY_LIST=()

# Fields are never empty in the state file ("-" / 0), since read with IFS=tab would skip them
pfields() { [ "$ns" == "-" ] && ns=""; [ "$detail" == "-" ] && detail=""; [ "$where" == "-" ] && where=""; [ "$strict" == "1" ] || strict=""; }

save_primary_state() {
    local z
    as_root mkdir -p "$STATE_DIR"
    for z in "${!PNEW[@]}"; do printf '%s\t%s\n' "$z" "${PNEW[$z]}"; done | as_root tee "$PRIMARY_STATE.tmp" >/dev/null
    as_root mv -f "$PRIMARY_STATE.tmp" "$PRIMARY_STATE"
}

# Daily. With $1 = show it only prints a table.
declare -A PNEW=()
primary_scan() {
    local mode="${1:-}" now last zones=() z st since ns notified strict detail where total=0 bad=0 age what
    declare -A OLD=()
    PNEW=()
    [ "$DELEGATION" == "off" ] && [ "$mode" != "show" ] && return
    mapfile -t zones < <(primary_zones)
    [ ${#zones[@]} -eq 0 ] && return
    now="$(date +%s)"
    last="$(as_root cat "$STATE_DIR/primary-delegation.last" 2>/dev/null || echo 0)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if as_root test -f "$PRIMARY_STATE"; then
        while IFS=$'\t' read -r z st since ns notified strict detail where; do
            # Older versions wrote a free-text detail: drop it, it is refreshed at the next check
            [[ "$detail" == *"|"* ]] || detail="-"
            OLD["$z"]="$st"$'\t'"$since"$'\t'"$ns"$'\t'"${notified:-0}"$'\t'"${strict:-0}"$'\t'"$detail"$'\t'"${where:--}"; PNEW["$z"]="${OLD[$z]}"
        done < <(as_root cat "$PRIMARY_STATE")
    fi

    if [ "$mode" == "show" ] || [ $(( now - last )) -ge 72000 ]; then
        [ ${#OWN[@]} -eq 0 ] && own_ips_load
        declare -A CURRENT=()
        for z in "${zones[@]}"; do CURRENT["$z"]=1; done
        for z in "${!PNEW[@]}"; do [ -n "${CURRENT[$z]:-}" ] || unset 'PNEW[$z]'; done
        [ "$mode" == "show" ] && { echo; echo "Zones this server is primary for:"; row "ZONE" "STATUS" "SINCE" "DETAILS"; row "----" "------" "-----" "-------"; }
        local hidden=0
        for z in "${zones[@]}"; do
            if [ ${#MANUAL_ZONES[@]} -gt 0 ] && [[ " ${MANUAL_ZONES[*]} " != *" $z "* ]]; then continue; fi
            if is_excluded "$z"; then
                unset 'PNEW[$z]'
                [ "$mode" == "show" ] && { [ -n "$VERBOSE" ] && row "$z" "EXCLUDED" "-" "-" || hidden=$((hidden + 1)); }
                continue
            fi
            primary_status "$z"
            case "$PSTATUS" in
                MOVED|UNREG|BEHIND|ELSEWHERE)
                    total=$((total + 1)); [ "$PSTATUS" != "BEHIND" ] && bad=$((bad + 1))
                    IFS=$'\t' read -r st since ns notified strict detail where <<<"${OLD[$z]:-}"; pfields
                    if [ "$st" != "$PSTATUS" ] || [ -z "$since" ]; then since="$now"; notified=0; fi
                    where="$(zone_entry "$z" | awk -F'\t' '$6 == "conf" { print $2 ":" $3 }')"
                    PNEW["$z"]="$PSTATUS"$'\t'"$since"$'\t'"${DNS_LIST:--}"$'\t'"${notified:-0}"$'\t'"${PSTRICT:-0}"$'\t'"${PDETAIL:--}"$'\t'"${where:--}" ;;
                OURS)    total=$((total + 1)); unset 'PNEW[$z]' ;;
                SUBZONE) unset 'PNEW[$z]' ;;
                UNKNOWN) ;;
            esac
            if [ "$mode" == "show" ]; then
                if [[ "$PSTATUS" == OURS || "$PSTATUS" == SUBZONE ]] && [ -z "$VERBOSE" ]; then
                    hidden=$((hidden + 1)); continue
                fi
                since="-"; [ -n "${PNEW[$z]:-}" ] && since="$(date -d "@$(cut -f2 <<<"${PNEW[$z]}")" +%F 2>/dev/null)"
                row "$z" "$PSTATUS" "$since" "$(primary_what "$PSTATUS" "$DNS_LIST" "$PDETAIL" | cut -c1-120)"
            fi
        done
        [ "$mode" == "show" ] && [ "$hidden" -gt 0 ] && echo "($hidden zone(s) OK or not checked - add 'verbose' to list them)"
        if [ "$total" -ge 4 ] && [ $(( bad * 2 )) -gt "$total" ]; then
            echo "WARNING: $bad of $total primary zones look delegated elsewhere - that is unlikely, so nothing is reported. Check: $MARKER delegation verbose"
            [ "$mode" == "show" ] || [ -n "$DRYRUN" ] || log_event ERROR "primary zone check: $bad of $total zones look delegated elsewhere - ignored, check '$MARKER delegation verbose'"
            PNEW=(); return
        fi
        if [ "$mode" != "show" ] && [ -z "$DRYRUN" ]; then
            save_primary_state
            echo "$now" | as_root tee "$STATE_DIR/primary-delegation.last" >/dev/null
        fi
    fi
    [ "$mode" == "show" ] && return

    # Tell about each zone twice: when it is first seen, and when it has stayed like that for
    # DELEGATION_DAYS days. With --primary-zones comment, unambiguous cases are then removed.
    local changed=""
    for z in "${!PNEW[@]}"; do
        IFS=$'\t' read -r st since ns notified strict detail where <<<"${PNEW[$z]}"; pfields
        [[ "$since" =~ ^[0-9]+$ ]] || continue
        age=$(( (now - since) / 86400 ))
        what="$(primary_what "$st" "$ns" "$detail")"
        if [ "$st" == "BEHIND" ]; then
            STALE_PRIMARY_LIST+=("$z: $what")
        else
            STALE_PRIMARY_LIST+=("$z: $what To do: $(primary_todo "$z" "$where")")
        fi
        # Remove unambiguous cases after the waiting time, if asked to
        if [ "$PRIMARY_ZONES" == "comment" ] && [ -n "$strict" ] && [ "$age" -ge "$DELEGATION_DAYS" ] \
           && [ "$st" != "BEHIND" ] && ! command -v plesk >/dev/null 2>&1 && [ -z "${REASON[$z]:-}" ]; then
            REASON["$z"]="$( [ "$st" == UNREG ] && echo PUNREG || echo PMOVED)"
            DELEG_INFO["$z"]="$what Since $(date -d "@$since" +%F 2>/dev/null)."
        fi
        [ -n "$DRYRUN" ] && continue
        if [ "${notified:-0}" -lt 1 ]; then
            if [ "$st" == "BEHIND" ]; then log_event BEHIND "$z: $what"
            else log_event STALEPRIMARY "$z: no longer in use here. $what $(primary_todo "$z" "$where")"
            fi
            notified=1; changed=1
        elif [ "$notified" -lt 2 ] && [ "$age" -ge "$DELEGATION_DAYS" ]; then
            if [ "$st" == "BEHIND" ]; then log_event BEHIND "$z: still out of sync after $age days. $what"
            elif [ "$PRIMARY_ZONES" == "comment" ] && [ -n "$strict" ] && ! command -v plesk >/dev/null 2>&1; then :
            else log_event STALEPRIMARY "$z: still not in use after $age days. $what $(primary_todo "$z" "$where")"
            fi
            notified=2; changed=1
        fi
        PNEW["$z"]="$st"$'\t'"$since"$'\t'"${ns:--}"$'\t'"$notified"$'\t'"${strict:-0}"$'\t'"${detail:--}"$'\t'"${where:--}"
    done
    [ -n "$changed" ] && save_primary_state
    return 0
}

PENDING_LIST=()

if [ -n "$DELEG_SHOW" ]; then
    delegation_scan show
    primary_scan show
    exit 0
fi

# ---------------------------------------------------------------------------
# Find candidate zones
# ---------------------------------------------------------------------------

# Read the log: syslog/messages file (incl. the newest rotated copy) or the systemd journal.
# Streams everything (never loads the log into memory). Uses sudo if needed.
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
    grep -E "$1" "$2" | sed -nE 's/.*zone ([^/ ]+)\/IN.*/\1/p' | tr 'A-Z' 'a-z' | sort -u
}

declare -A REASON=()     # zone -> RETRY / DISABLED / MANUAL
declare -A PRIMARY=()    # zone -> primary IPs to check against

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
    # Keep only the refresh errors; the log itself can be gigabytes
    read_log | grep -E "refresh: (retry limit|unexpected rcode|non-authoritative answer)" > "$TMPD/log"

    mapfile -t RETRY_ZONES    < <(extract_zones "$RETRY_RE" "$TMPD/log")
    mapfile -t DISABLED_ZONES < <(extract_zones "$DISABLED_RE" "$TMPD/log")

    # Validate domain names and merge (a zone may appear in both lists)
    for z in "${RETRY_ZONES[@]}"; do
        is_domain "$z" && REASON["$z"]="RETRY"
    done
    for z in "${DISABLED_ZONES[@]}"; do
        is_domain "$z" && REASON["$z"]="DISABLED"
    done

fi

# Delegation check (auto mode only; once a day)
if [ -n "$AUTO" ]; then
    N_SECONDARY="$(zone_index | awk -F'\t' '$7 == "slave" || $7 == "secondary"' | cut -f1 | sort -u | grep -c .)"
    N_PRIMARY="$(primary_zones | grep -c .)"
    if [ "$N_SECONDARY" -gt 0 ] || [ "$N_PRIMARY" -eq 0 ]; then
        delegation_scan
    fi
    if [ ${#PENDING_LIST[@]} -gt 0 ]; then
        echo "Not delegated here, removed when the waiting time is over:"
        printf '  %s\n' "${PENDING_LIST[@]}"
    fi
    if [ "$N_PRIMARY" -gt 0 ]; then
        primary_scan
        if [ "$N_SECONDARY" -eq 0 ]; then
            echo "This server is primary for $N_PRIMARY zone(s) and has no secondary zones."
            echo "Secondary zones are what $MARKER cleans up; primary zones are only checked and reported, never changed."
        fi
        if [ ${#STALE_PRIMARY_LIST[@]} -gt 0 ]; then
            echo "Primary zones that look unused or out of sync (nothing changed):"
            for l in "${STALE_PRIMARY_LIST[@]}"; do wrap "  - " "$l" 100; done
        elif [ "$DELEGATION" != "off" ]; then
            echo "All primary zones checked so far are delegated to their own nameservers."
        fi
    fi
fi
if [ ${#REASON[@]} -eq 0 ]; then
    echo "No stale zones${TARGET_IP:+ for $TARGET_IP} found."
    exit 0
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

TO_REMOVE=()
SKIPPED=()
ALREADY_GONE=()
declare -A LIVE=()
declare -A ZACTION=()    # per-zone file action (primary zones: always archive, never delete)


echo
row "ZONE" "SOURCE" "PRIMARY" "ACTION"
row "----" "------" "-------" "------"
for ZONE in $(printf '%s\n' "${!REASON[@]}" | sort); do
    why="${REASON[$ZONE]}"
    if ! zone_exists_locally "$ZONE"; then
        ALREADY_GONE+=("$ZONE")
        [ -n "$VERBOSE" ] || [ "$why" == "MANUAL" ] && row "$ZONE" "$why" "-" "skip (no longer exists locally)"
        continue
    fi
    if is_excluded "$ZONE"; then
        row "$ZONE" "$why" "-" "skip (excluded)"
        SKIPPED+=("$ZONE"); continue
    fi
    # Stale primary zone, opted in with --primary-zones comment (checked daily for N days)
    if [ "$why" == "PMOVED" ] || [ "$why" == "PUNREG" ]; then
        row "$ZONE" "$why" "-" "REMOVE (${DELEG_INFO[$ZONE]:-})"
        LIVE["$ZONE"]="$why"; ZACTION["$ZONE"]="archive"; TO_REMOVE+=("$ZONE"); continue
    fi
    # Never touch zones this server is the primary for (or other non-secondary zones)
    ztype="$(zone_type "$ZONE")"
    if [ -n "$ztype" ] && [ "$ztype" != "secondary" ] && [ "$ztype" != "slave" ]; then
        row "$ZONE" "$why" "-" "skip (type $ztype on this server - not a secondary zone)"
        SKIPPED+=("$ZONE")
        continue
    fi
    # Not delegated here for long enough: the TLD is the truth, the old primary may still
    # serve the zone with outdated data
    if [ "$why" == "MOVED" ] || [ "$why" == "UNREG" ]; then
        PRIMARY["$ZONE"]="$(primaries_of "$ZONE")"
        row "$ZONE" "$why" "-" "REMOVE (${DELEG_INFO[$ZONE]:-})"
        LIVE["$ZONE"]="$why"; TO_REMOVE+=("$ZONE"); continue
    fi
    # The zone's configured primaries decide, not the log
    PRIMARY["$ZONE"]="$(primaries_of "$ZONE")"
    if [ -n "$TARGET_IP" ]; then
        if [ -z "${PRIMARY[$ZONE]}" ]; then
            PRIMARY["$ZONE"]="$TARGET_IP"   # config not readable: fall back to the log's primary
        elif [[ " ${PRIMARY[$ZONE]} " != *" $TARGET_IP "* ]]; then
            row "$ZONE" "$why" "-" "skip (zone now uses primary ${PRIMARY[$ZONE]}, not $TARGET_IP)"
            SKIPPED+=("$ZONE")
            continue
        fi
    elif [ -n "$AUTO" ] && [ -z "${PRIMARY[$ZONE]}" ]; then
        row "$ZONE" "$why" "UNKNOWN" "skip (primary not found in zone config)"
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
            # Zone given by name but its config could not be read: only with force
            [ -z "$FORCE" ] && action="skip (zone config not readable, add 'force')" ;;
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
    row "$ZONE" "$why" "$live" "$action"
    LIVE["$ZONE"]="$live"
    if [ "$action" == "REMOVE" ]; then TO_REMOVE+=("$ZONE"); else SKIPPED+=("$ZONE"); fi
done
if [ ${#ALREADY_GONE[@]} -gt 0 ] && [ -z "$VERBOSE" ] && [ -n "$AUTO$TARGET_IP" ]; then
    echo "(${#ALREADY_GONE[@]} zone(s) from the log are already removed - add 'verbose' to list them)"
fi
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
        log_event HELD "$n zones of primary $k held back: primary does not answer, may be down"
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

# ---------------------------------------------------------------------------
# Plan how each zone is removed
#   DYN    = added with rndc addzone (e.g. Plesk Slave DNS Manager): rndc delzone
#   CONF   = defined in a named.conf file: comment it out, check the config, reload BIND
#   MANUAL = can't be done safely here: reported, left alone
# ---------------------------------------------------------------------------

declare -A METHOD=() WHERE=() ZFILE=() ZHASFILE=()
for ZONE in "${TO_REMOVE[@]}"; do
    e="$(zone_entry "$ZONE")"
    ZFILE["$ZONE"]="$(zone_files "$ZONE" | head -n1)"
    ZHASFILE["$ZONE"]=""; [ -n "${ZFILE[$ZONE]}" ] && as_root test -e "${ZFILE[$ZONE]}" && ZHASFILE["$ZONE"]=1
    if [ -n "$e" ] && [ "$(cut -f6 <<<"$e")" == "conf" ]; then
        IFS=$'\t' read -r _ cf cs cl clean _ <<<"$e"
        WHERE["$ZONE"]="$cf:$cs-$cl"
        if [ "$CONF_ZONES" == "skip" ]; then
            METHOD["$ZONE"]="MANUAL"; WHERE["$ZONE"]+=" (conf-zones is set to skip)"
        elif [ "$clean" != "1" ]; then
            METHOD["$ZONE"]="MANUAL"; WHERE["$ZONE"]+=" (shares a line with other config)"
        else
            METHOD["$ZONE"]="CONF"
        fi
    elif [ -n "$RNDC_OK" ]; then
        METHOD["$ZONE"]="DYN"
    elif [ -n "$e" ]; then
        METHOD["$ZONE"]="MANUAL"; WHERE["$ZONE"]="added with rndc addzone ($(cut -f2 <<<"$e")), needs a working rndc"
    else
        METHOD["$ZONE"]="MANUAL"; WHERE["$ZONE"]="not found in any config file and rndc is not usable"
    fi
done

file_note() {
    local f="${ZFILE[$1]:-}" FILE_ACTION="${ZACTION[$1]:-$FILE_ACTION}"
    [ -z "$f" ] && { echo "zone file unknown"; return; }
    [ -z "${ZHASFILE[$1]:-}" ] && { echo "no zone file found ($f)"; return; }
    case "$FILE_ACTION" in
        delete)  echo "zone file deleted ($f)" ;;
        keep)    echo "zone file kept ($f)" ;;
        archive) echo "zone file archived ($f)" ;;
    esac
}

if [[ "$DRYRUN" == "dryrun" ]]; then
    echo "DRY-RUN MODE ENABLED! No changes will be made."
    for ZONE in "${TO_REMOVE[@]}"; do
        case "${METHOD[$ZONE]}" in
            DYN)    echo "[DRY-RUN] $ZONE: rndc delzone, $(file_note "$ZONE")" ;;
            CONF)   echo "[DRY-RUN] $ZONE: comment out ${WHERE[$ZONE]}, reload BIND, $(file_note "$ZONE")" ;;
            MANUAL) echo "[DRY-RUN] $ZONE: remove by hand - ${WHERE[$ZONE]}" ;;
        esac
    done
    echo "Dry-run complete. ${#TO_REMOVE[@]} zone(s) would be handled, ${#SKIPPED[@]} skipped."
    exit 0
fi

STAMP="$(date +%Y-%m-%d_%H%M%S)"
BACKUP_ROOT="/var/backups/$MARKER/$STAMP"

# After a zone is gone from BIND: delete, keep or archive its files
handle_files() {
    local zone="$1" f moved="" FILE_ACTION="${ZACTION[$1]:-$FILE_ACTION}"
    shift
    for f in "$@"; do
        case "$FILE_ACTION" in
            delete)
                for _ in 1 2 3 4 5 6; do as_root test -e "$f" || break; sleep 0.5; done
                as_root test -e "$f" && as_root rm -f -- "$f" ;;
            archive)
                if as_root test -e "$f"; then
                    as_root mkdir -p "$BACKUP_ROOT/zones" && as_root mv -f -- "$f" "$BACKUP_ROOT/zones/" && moved=1
                fi ;;
        esac
    done
    [ -n "$moved" ] && echo "  Zone file moved to $BACKUP_ROOT/zones/"
    return 0
}

wait_gone() {
    ZONE_INDEX_DONE=""      # config files / .nzf changed: read them again
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        zone_exists_locally "$1" || return 0
        sleep 0.5
    done
    ! zone_exists_locally "$1"
}

REMOVED=0
FAILED=0
MANUAL_COUNT=0

# 1) Zones added with rndc addzone
for ZONE in "${TO_REMOVE[@]}"; do
    [ "${METHOD[$ZONE]}" == "DYN" ] || continue
    mapfile -t PATHS < <(zone_files "$ZONE")
    echo "Removing zone: $ZONE (${REASON[$ZONE]}) with rndc delzone"
    out=""
    if [ "$FILE_ACTION" == "delete" ]; then
        out="$(as_root rndc delzone -clean "$ZONE" 2>&1)"; rc=$?
        if [ $rc -ne 0 ] && grep -qiE "unknown option|usage|syntax|unexpected token|extra input" <<<"$out"; then
            out="$(as_root rndc delzone "$ZONE" 2>&1)"; rc=$?    # BIND < 9.10 has no -clean
        fi
    else
        out="$(as_root rndc delzone "$ZONE" 2>&1)"; rc=$?
    fi
    [ -n "$out" ] && echo "  $out"
    if [ $rc -ne 0 ]; then
        echo "  ERROR: rndc delzone failed for $ZONE"
        log_event FAILED "$ZONE: rndc delzone failed: ${out:-no output} (${REASON[$ZONE]}${PRIMARY[$ZONE]:+, primary ${PRIMARY[$ZONE]}})"
        FAILED=$((FAILED + 1)); continue
    fi
    if ! wait_gone "$ZONE"; then
        echo "  ERROR: $ZONE is still loaded in BIND"
        log_event FAILED "$ZONE: still loaded in BIND after rndc delzone"
        FAILED=$((FAILED + 1)); continue
    fi
    handle_files "$ZONE" "${PATHS[@]}"
    echo "  OK: zone removed, $(file_note "$ZONE")"
    log_event REMOVED "$ZONE: $(reason_text "${REASON[$ZONE]}"). Removed with rndc delzone, $(file_note "$ZONE")."
    REMOVED=$((REMOVED + 1))
done

# 2) Zones defined in config files: back up, comment out, check, reload
CONF_LIST=()
for ZONE in "${TO_REMOVE[@]}"; do [ "${METHOD[$ZONE]}" == "CONF" ] && CONF_LIST+=("$ZONE"); done
if [ ${#CONF_LIST[@]} -gt 0 ]; then
    declare -A RANGES=()
    for ZONE in "${CONF_LIST[@]}"; do
        cf="${WHERE[$ZONE]%:*}"; r="${WHERE[$ZONE]##*:}"
        RANGES["$cf"]+="${r%-*}:${r#*-}:$ZONE:${REASON[$ZONE]} "
    done
    conf_ok=1
    for cf in "${!RANGES[@]}"; do
        as_root mkdir -p "$BACKUP_ROOT/config$(dirname "$cf")"
        as_root cp -p -- "$cf" "$BACKUP_ROOT/config$cf" || { conf_ok=""; break; }
        as_root cat "$cf" | awk -v R="${RANGES[$cf]}" -v D="$(date '+%F %H:%M')" -v M="$MARKER" '
            BEGIN { n = split(R, parts, " ")
                    why["RETRY"] = "its primary no longer answers for it"; why["DISABLED"] = "its primary no longer has it"
                    why["MOVED"] = "the domain is no longer delegated to this server"; why["UNREG"] = "the domain no longer exists"
                    why["MANUAL"] = "removed with " M
                    why["PMOVED"] = "the domain is served by another primary"; why["PUNREG"] = "the domain no longer exists"
                    for (i = 1; i <= n; i++) { split(parts[i], x, ":"); s[x[1]] = x[2]; z[x[1]] = x[3]; w[x[1]] = x[4] } }
            { if (NR in s) { e = s[NR]; zn = z[NR]
                  print "# [" M " " D "] zone " zn " removed: " why[w[NR]] ". To restore, remove the \"# \" in front of the lines below." }
              if (e && NR <= e) { print "# " $0; if (NR == e) e = 0 } else print }' > "$TMPD/new.conf"
        # Write in place so owner, group, permissions and SELinux labels stay the same
        as_root sh -c "cat '$TMPD/new.conf' > '$cf'" || { conf_ok=""; break; }
    done
    if [ -n "$conf_ok" ] && command -v named-checkconf >/dev/null 2>&1; then
        if ! out="$(checkconf 2>&1)"; then
            echo "  ERROR: named-checkconf failed after commenting out zones:"; echo "$out" | sed 's/^/    /'
            conf_ok=""
        fi
    fi
    if [ -z "$conf_ok" ]; then
        # Put every touched file back exactly as it was
        for cf in "${!RANGES[@]}"; do
            as_root test -f "$BACKUP_ROOT/config$cf" && as_root sh -c "cat '$BACKUP_ROOT/config$cf' > '$cf'"
        done
        for ZONE in "${CONF_LIST[@]}"; do
            echo "  ERROR: $ZONE not removed - the config change was rolled back"
            log_event FAILED "$ZONE: commenting out ${WHERE[$ZONE]} failed the config check, rolled back"
            FAILED=$((FAILED + 1))
        done
    else
        echo "Config changed (backup in $BACKUP_ROOT/config), reloading BIND..."
        reloaded=""
        if [ -n "$RNDC_OK" ] && as_root rndc reconfig >/dev/null 2>&1; then reloaded=1
        else
            for svc in named bind9 named-chroot; do
                if has_systemd && systemctl is-active --quiet "$svc" 2>/dev/null; then
                    as_root systemctl reload "$svc" && { reloaded=1; break; }
                fi
            done
            [ -z "$reloaded" ] && command -v rc-service >/dev/null 2>&1 && as_root rc-service named reload && reloaded=1
            [ -z "$reloaded" ] && command -v service >/dev/null 2>&1 && \
                { as_root service bind9 reload || as_root service named reload; } >/dev/null 2>&1 && reloaded=1
        fi
        if [ -z "$reloaded" ]; then
            echo "  WARNING: could not reload BIND - the zones disappear at the next restart"
            log_event ERROR "could not reload BIND after commenting out zones - reload it by hand"
        fi
        for ZONE in "${CONF_LIST[@]}"; do
            mapfile -t PATHS < <(f="${ZFILE[$ZONE]:-}"; [ -n "$f" ] && printf '%s\n' "$f" "$f.jnl")
            if [ -n "$reloaded" ] && ! wait_gone "$ZONE"; then
                echo "  ERROR: $ZONE is still loaded after the reload"
                log_event FAILED "$ZONE: commented out in ${WHERE[$ZONE]} but still loaded after reload"
                FAILED=$((FAILED + 1)); continue
            fi
            if [ -n "$reloaded" ]; then
                handle_files "$ZONE" "${PATHS[@]}"
                note="$(file_note "$ZONE")"
            else
                note="zone file left alone until BIND is reloaded"   # BIND still has the zone loaded
            fi
            echo "  OK: $ZONE commented out in ${WHERE[$ZONE]%:*}, $note"
            log_event REMOVED "$ZONE: $(reason_text "${REASON[$ZONE]}"). Commented out in ${WHERE[$ZONE]%:*} (backup made), $note."
            REMOVED=$((REMOVED + 1))
        done
    fi
fi

# 3) Zones that need a human
for ZONE in "${TO_REMOVE[@]}"; do
    [ "${METHOD[$ZONE]}" == "MANUAL" ] || continue
    echo "Remove by hand: $ZONE - ${WHERE[$ZONE]}"
    log_event MANUAL "$ZONE: $(reason_text "${REASON[$ZONE]}"), but it could not be removed safely here: ${WHERE[$ZONE]}"
    MANUAL_COUNT=$((MANUAL_COUNT + 1))
done

echo "Cleanup completed! Removed: $REMOVED, failed: $FAILED, by hand: $MANUAL_COUNT, skipped: ${#SKIPPED[@]}."
[ "$FAILED" -gt 0 ] && exit 1
[ "$SAFETY_HELD" -gt 0 ] && exit 2
exit 0
