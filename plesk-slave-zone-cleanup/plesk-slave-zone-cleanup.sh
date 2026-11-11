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
#   plesk-slave-zone-cleanup [delete|keep|archive] [dryrun] [verbose]
#       Find broken zones in the log, whatever their primary (auto mode)
#   plesk-slave-zone-cleanup <IP-ADDRESS> [delete|keep|archive] [dryrun]
#       Same, but only zones for this primary
#   plesk-slave-zone-cleanup <ZONE> [ZONE...] [delete|keep|archive] [dryrun] [force]
#       Remove specific zone(s) directly
#
#   <IP-ADDRESS> Only look for zones from this primary DNS server (Plesk)
#   <ZONE>       Zone name(s), e.g. example.com. The primary is read from the zone's
#                config and checked live before removal.
#   delete|yes   Delete the zone file of a removed zone (default, see --delete-files)
#   keep|no      Keep the zone file
#   archive      Move the zone file to /var/backups/plesk-slave-zone-cleanup/<time>/zones/
#   dryrun       Only show what would be done
#   verbose      Also list log zones that are already gone
#   force        Zone mode only: remove even if the primary still serves the zone
#
# How a zone is removed:
#   - added with rndc addzone (Plesk Slave DNS Manager): rndc delzone
#   - defined in named.conf or an included file: the zone statement is commented out with
#     "# " (backup first), named-checkconf must pass (else everything is rolled back), then
#     BIND is reloaded. Set --conf-zones skip to only report such zones instead.
#   - anything that can't be done safely is reported as "remove by hand"
#   Works without rndc showzone/zonestatus (old BIND) and even without a working rndc
#   (then only zones in config files, reloaded via systemd/init).
#
# Options can be given in any order.
#
# Install, schedule and update (needs sudo):
#   plesk-slave-zone-cleanup install [--interval 1h] [--delete-files|--keep-files|--archive-files]
#                                    [--conf-zones comment|skip]
#                                    [--auto-update|--no-auto-update] [--ref main]
#       Installs missing packages (dig, logger) on Debian/Ubuntu, RHEL/Fedora, SUSE,
#       Arch and Alpine, copies the script to /usr/local/sbin and schedules it with a
#       systemd timer (or cron). Run again to change settings.
#       Mail report: [--report-email a@example.com[,b@example.com]] [--report-time 07:00]
#                    [--report-always|--report-changes] [--no-report] [--mail-from addr]
#                    [--smtp smtps://smtp.example.com:465 --smtp-user user] [--no-smtp]
#       Without --smtp the local sendmail is used. The SMTP password is asked for (or taken
#       from SMTP_PASSWORD=...) and stored in /etc/plesk-slave-zone-cleanup.conf (root only).
#   plesk-slave-zone-cleanup report      Mail what happened since the last report (nothing
#                                        happened = no mail, unless --always / --report-always)
#       --test   send a test mail     --print   show the report instead of sending it
#   plesk-slave-zone-cleanup check       Show the installed version and the one on GitHub
#   plesk-slave-zone-cleanup update      Install the version on GitHub if it is newer (and valid)
#       --ref main (default) = the main branch; updates when VERSION in the script is raised
#       --ref latest = newest GitHub release of this script (tag plesk-slave-zone-cleanup-vX.Y.Z)
#       --ref v1.2.0 = that release only
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
EVENT_LOG="/var/log/plesk-slave-zone-cleanup.log"   # events for the daily mail report

# Log an event to syslog/journal and to our own event log.
# Types: REMOVED FAILED HELD MANUAL UPDATED INSTALLED ERROR
log_event() {
    local type="$1"; shift
    logger -t "$TAG" -- "$type: $*" 2>/dev/null || true
    printf '%s %s %s %s\n' "$(date +%s)" "$(date '+%F %T')" "$type" "$*" \
        | as_root tee -a "$EVENT_LOG" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Installation, updates and scheduling
# ---------------------------------------------------------------------------

VERSION="1.1.0"
REPO_RAW="${PSZC_REPO_RAW:-https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts}"   # override only for testing
REPO_API="${PSZC_REPO_API:-https://api.github.com/repos/weconnect-tobias/Plesk-Scripts}"
TAG_PREFIX="plesk-slave-zone-cleanup-v"   # releases of this script are tagged plesk-slave-zone-cleanup-v1.2.3
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

# --ref values: "latest" (newest release of this script), a version ("v1.2.0" / "1.2.0",
# turned into the tag plesk-slave-zone-cleanup-v1.2.0), a full tag, or a branch ("main").
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

CONF_KEYS="REF INTERVAL FILES CONF_ZONES AUTO_UPDATE REPORT_EMAIL REPORT_TIME REPORT_ALWAYS MAIL_FROM SMTP_URL SMTP_USER SMTP_PASS"
load_conf() {
    REF="main"; INTERVAL="1h"; FILES="delete"; CONF_ZONES="comment"; AUTO_UPDATE="no"
    REPORT_EMAIL=""; REPORT_TIME="07:00"; REPORT_ALWAYS="no"
    MAIL_FROM=""; SMTP_URL=""; SMTP_USER=""; SMTP_PASS=""
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
}
save_conf() {
    local k
    umask 077
    {
        echo "# plesk-slave-zone-cleanup settings - written by '$MARKER install'."
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

cmd_install() {
    local new_ref="" new_interval="" new_files="" new_auto="" src=""
    local opt_conf="" opt_email="" opt_rtime="" opt_ralways="" opt_from="" opt_smtp="" opt_suser=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval)       new_interval="${2:-}"; shift ;;
            --interval=*)     new_interval="${1#*=}" ;;
            --ref)            new_ref="${2:-}"; shift ;;
            --ref=*)          new_ref="${1#*=}" ;;
            --keep-files)     new_files="keep" ;;
            --delete-files)   new_files="delete" ;;
            --archive-files)  new_files="archive" ;;
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
            *) die "unknown install option: $1" ;;
        esac
        shift
    done
    load_conf     # keep earlier settings unless overridden
    REF="${new_ref:-$REF}"; INTERVAL="${new_interval:-$INTERVAL}"
    FILES="${new_files:-$FILES}"; AUTO_UPDATE="${new_auto:-$AUTO_UPDATE}"
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
    if [ -n "$opt_suser" ]; then
        [ "$opt_suser" != "$SMTP_USER" ] && SMTP_PASS=""
        SMTP_USER="$opt_suser"
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
                || die "invalid --smtp '$SMTP_URL' (use smtps://host:465 or smtp://host:587)"
            if [ -n "$SMTP_USER" ] && [ -z "$SMTP_PASS" ]; then
                if [ -n "${SMTP_PASSWORD:-}" ]; then
                    SMTP_PASS="$SMTP_PASSWORD"
                elif interactive; then
                    read -r -s -p "SMTP password for $SMTP_USER: " SMTP_PASS; echo
                else
                    die "SMTP password needed: run interactively or set SMTP_PASSWORD=..."
                fi
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
    log_event INSTALLED "$VERSION (interval $INTERVAL, zone files $FILES, conf zones $CONF_ZONES, auto-update $AUTO_UPDATE, ref $REF, report ${REPORT_EMAIL:-off})"

    echo
    info "Done. Runs every $INTERVAL, zone files: $FILES, zones in named.conf: $CONF_ZONES, auto-update: $AUTO_UPDATE$( [ "$AUTO_UPDATE" == yes ] && echo " (from '$REF')" )"
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

STATE_DIR="/var/lib/plesk-slave-zone-cleanup"

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
        {
            [ -n "$SMTP_USER" ] && printf 'user = "%s"\n' "$cred"
        } | curl -sS --ssl-reqd --crlf --connect-timeout 20 --max-time 60 -K - \
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

cmd_report() {
    local mode="send" always="" host now last events n_rem n_fail n_held n_upd n_err n_inst n_man subject parts=()
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
            "Sent via: ${SMTP_URL:-local sendmail}" \
            | send_mail "[$host] $MARKER: test mail" || die "sending failed - check the SMTP settings"
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
    total="$(wc -l < "$EVENT_LOG" 2>/dev/null || echo 0)"
    [ "$done_lines" -gt "$total" ] && done_lines=0          # log was trimmed or replaced
    events="$(tail -n +"$(( done_lines + 1 ))" "$EVENT_LOG" 2>/dev/null)"

    n_rem=$(grep -c ' REMOVED ' <<<"$events"); n_fail=$(grep -c ' FAILED ' <<<"$events")
    n_held=$(grep -c ' HELD ' <<<"$events");   n_upd=$(grep -c ' UPDATED ' <<<"$events")
    n_err=$(grep -c ' ERROR ' <<<"$events");   n_inst=$(grep -c ' INSTALLED ' <<<"$events")
    n_man=$(grep ' MANUAL ' <<<"$events" | awk '{print $5}' | sort -u | grep -c .)
    [ -z "$events" ] && { n_rem=0; n_fail=0; n_held=0; n_upd=0; n_err=0; n_inst=0; n_man=0; }

    if [ -z "$events" ] && [ -z "$always" ] && [ "$mode" == "send" ]; then
        echo "$total $now" > "$STATE_DIR/last-report"
        exit 0      # nothing happened, no mail
    fi

    [ "$n_rem" -gt 0 ]  && parts+=("$n_rem removed")
    [ "$n_fail" -gt 0 ] && parts+=("$n_fail FAILED")
    [ "$n_held" -gt 0 ] && parts+=("held back")
    [ "$n_man" -gt 0 ]  && parts+=("$n_man to remove by hand")
    [ "$n_err" -gt 0 ]  && parts+=("errors")
    [ "$n_upd" -gt 0 ]  && parts+=("updated")
    [ "$n_inst" -gt 0 ] && parts+=("settings changed")
    [ ${#parts[@]} -eq 0 ] && parts+=("no changes")
    subject="[$host] $MARKER: $(IFS=,; echo "${parts[*]}" | sed 's/,/, /g')"

    section() {   # $1 = type, $2 = heading. Repeated messages are shown once with a count.
        local lines
        lines="$(grep " $1 " <<<"$events" | awk '{
                    t = $2 " " $3; $1 = $2 = $3 = $4 = ""; sub(/^ +/, "")
                    if (!($0 in n)) order[++k] = $0
                    n[$0]++; if (!($0 in first)) first[$0] = t; lastt[$0] = t
                 } END {
                    for (i = 1; i <= k; i++) { m = order[i]
                        if (n[m] == 1) print "  " lastt[m] "  " m
                        else print "  " first[m] " - " lastt[m] "  " m "  (" n[m] " times)" }
                 }')"
        [ -z "$lines" ] && return
        echo "$2"; echo "$lines"; echo
    }
    body() {
        echo "Report from $MARKER $VERSION on $host"
        echo "Period: $(date -d "@$last" '+%F %T' 2>/dev/null || echo "$last") - $(date -d "@$now" '+%F %T' 2>/dev/null || echo "$now")"
        echo
        if [ -z "$events" ]; then
            echo "Nothing happened. All zones the primaries no longer serve were already gone."
            echo
        fi
        section FAILED  "FAILED - needs attention:"
        section MANUAL  "Stale zones to remove by hand (no primary serves them):"
        section HELD    "Held back - a primary did not answer (is it down?):"
        section ERROR   "Errors:"
        section REMOVED "Removed zones:"
        section UPDATED "Script updated:"
        section INSTALLED "Installed / settings changed:"
        echo "Settings: every $INTERVAL, zone files $FILES, zones in named.conf $CONF_ZONES, auto-update $AUTO_UPDATE"
        echo "Full log: $EVENT_LOG on $host"
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
        if [ -n "$REPORT_EMAIL" ]; then
            echo "Report:   to $REPORT_EMAIL at $REPORT_TIME, $( [ "$REPORT_ALWAYS" == yes ] && echo "every day" || echo "only on changes" ), via ${SMTP_URL:-local sendmail}"
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

case "${1:-}" in
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
    echo "               [--smtp smtps://host:465 --smtp-user user] [--mail-from addr]"
    echo "       $(basename "$0") report [--test|--print|--always]"
    echo "       $(basename "$0") check | update [--force] | status | uninstall | version"
    echo "       (yes = delete, no = keep)"
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

is_ip()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" =~ ^[0-9a-fA-F]*:[0-9a-fA-F:]+$ ]]; }
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
    if [ -n "$DRYRUN" ] || ! interactive; then
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
    for f in /etc/bind/named.conf /etc/named.conf /etc/namedb/named.conf /usr/local/etc/namedb/named.conf; do
        as_root test -f "$f" && { NAMED_CONF="$f"; break; }
    done
fi

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
        BIND_DIR="$(as_root named-checkconf -p 2>/dev/null | sed -nE 's/^[[:space:]]*directory[[:space:]]+"([^"]+)".*/\1/p' | head -n1)"
        if [ -z "$BIND_DIR" ] && [ -n "$NAMED_CONF" ]; then
            BIND_DIR="$(conf_files | while read -r f; do as_root cat "$f"; done 2>/dev/null \
                | sed -nE 's/^[[:space:]]*directory[[:space:]]+"([^"]+)".*/\1/p' | head -n1)"
        fi
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
                [[ "$inc" != /* ]] && inc="$base/$inc"
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
        inz = 1; start = NR; depth = 0; opened = 0
        line = substr(line, RSTART + RLENGTH)
    }
    for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "{") { depth++; opened = 1 }
        else if (c == "}") depth--
        else if (c == ";" && opened && depth == 0) {
            if (substr(line, i + 1) !~ /^[[:space:]]*$/) clean = 0
            print tolower(name) "\t" F "\t" start "\t" NR "\t" clean "\t" SRC
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

TO_REMOVE=()
SKIPPED=()
ALREADY_GONE=()
declare -A LIVE=()

row() { printf "%-40s %-9s %-10s %s\n" "$@"; }

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
#   DYN    = added with rndc addzone (Plesk Slave DNS Manager): rndc delzone
#   CONF   = defined in a named.conf file: comment it out, check the config, reload BIND
#   MANUAL = can't be done safely here: reported, left alone
# ---------------------------------------------------------------------------

declare -A METHOD=() WHERE=() ZFILE=()
for ZONE in "${TO_REMOVE[@]}"; do
    e="$(zone_entry "$ZONE")"
    ZFILE["$ZONE"]="$(zone_files "$ZONE" | head -n1)"
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
    local f="${ZFILE[$1]:-}"
    [ -z "$f" ] && { echo "zone file unknown"; return; }
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
    local zone="$1" f moved=""
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
        log_event FAILED "$ZONE: rndc delzone failed: ${out:-no output} (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
        FAILED=$((FAILED + 1)); continue
    fi
    if ! wait_gone "$ZONE"; then
        echo "  ERROR: $ZONE is still loaded in BIND"
        log_event FAILED "$ZONE: still loaded in BIND after rndc delzone"
        FAILED=$((FAILED + 1)); continue
    fi
    handle_files "$ZONE" "${PATHS[@]}"
    echo "  OK: zone removed, $(file_note "$ZONE")"
    log_event REMOVED "$ZONE, $(file_note "$ZONE") (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
    REMOVED=$((REMOVED + 1))
done

# 2) Zones defined in config files: back up, comment out, check, reload
CONF_LIST=()
for ZONE in "${TO_REMOVE[@]}"; do [ "${METHOD[$ZONE]}" == "CONF" ] && CONF_LIST+=("$ZONE"); done
if [ ${#CONF_LIST[@]} -gt 0 ]; then
    declare -A RANGES=()
    for ZONE in "${CONF_LIST[@]}"; do
        cf="${WHERE[$ZONE]%:*}"; r="${WHERE[$ZONE]##*:}"
        RANGES["$cf"]+="${r%-*}:${r#*-}:$ZONE "
    done
    conf_ok=1
    for cf in "${!RANGES[@]}"; do
        as_root mkdir -p "$BACKUP_ROOT/config$(dirname "$cf")"
        as_root cp -p -- "$cf" "$BACKUP_ROOT/config$cf" || { conf_ok=""; break; }
        as_root cat "$cf" | awk -v R="${RANGES[$cf]}" -v D="$(date '+%F %H:%M')" -v M="$MARKER" '
            BEGIN { n = split(R, parts, " ")
                    for (i = 1; i <= n; i++) { split(parts[i], x, ":"); s[x[1]] = x[2]; z[x[1]] = x[3] } }
            { if (NR in s) { e = s[NR]; zn = z[NR]
                  print "# [" M " " D "] zone " zn " removed: no primary serves it. To restore, remove the \"# \" in front of the lines below." }
              if (e && NR <= e) { print "# " $0; if (NR == e) e = 0 } else print }' > "$TMPD/new.conf"
        # Write in place so owner, group, permissions and SELinux labels stay the same
        as_root sh -c "cat '$TMPD/new.conf' > '$cf'" || { conf_ok=""; break; }
    done
    if [ -n "$conf_ok" ] && command -v named-checkconf >/dev/null 2>&1; then
        if ! out="$(as_root named-checkconf "$NAMED_CONF" 2>&1)"; then
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
            log_event REMOVED "$ZONE, commented out in ${WHERE[$ZONE]%:*} (backup $BACKUP_ROOT/config), $note (${REASON[$ZONE]}, primary ${PRIMARY[$ZONE]:-unknown})"
            REMOVED=$((REMOVED + 1))
        done
    fi
fi

# 3) Zones that need a human
for ZONE in "${TO_REMOVE[@]}"; do
    [ "${METHOD[$ZONE]}" == "MANUAL" ] || continue
    echo "Remove by hand: $ZONE - ${WHERE[$ZONE]}"
    log_event MANUAL "$ZONE: no primary serves it, remove by hand - ${WHERE[$ZONE]}"
    MANUAL_COUNT=$((MANUAL_COUNT + 1))
done

echo "Cleanup completed! Removed: $REMOVED, failed: $FAILED, by hand: $MANUAL_COUNT, skipped: ${#SKIPPED[@]}."
[ "$FAILED" -gt 0 ] && exit 1
[ "$SAFETY_HELD" -gt 0 ] && exit 2
exit 0
