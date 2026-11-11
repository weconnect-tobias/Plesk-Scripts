#!/bin/bash
#
# plesk-slave-zone-cleanup has been renamed to dns-zone-cleanup.
#
# This small script moves an existing installation over by itself: an installed
# plesk-slave-zone-cleanup 1.0.0 finds this file at its next update, installs it and runs
# "install", which downloads dns-zone-cleanup and installs that. dns-zone-cleanup takes
# over the settings, schedule, mail report and logs, and the old command name keeps
# working as a link.
#
# New installs: use dns-zone-cleanup directly (see dns-zone-cleanup/README.md).
# MIT license.

VERSION="1.1.0"
NEW="dns-zone-cleanup"
URL="https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/$NEW/$NEW.sh"

set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# Already moved over: just run the new script
if [ -x "/usr/local/sbin/$NEW" ] && [ "${1:-}" != "install" ]; then
    exec "/usr/local/sbin/$NEW" "$@"
fi
case "${1:-}" in version|--version) echo "plesk-slave-zone-cleanup $VERSION (renamed to $NEW)"; exit 0 ;; esac

if [ "$(id -u)" -ne 0 ]; then
    [ -f "$0" ] && exec sudo -- bash "$0" "$@"
    echo "Error: run this with sudo" >&2; exit 1
fi

echo "==> plesk-slave-zone-cleanup is now called $NEW - installing it"
tmp="$(mktemp)"
if command -v wget >/dev/null 2>&1; then wget -qO "$tmp" "$URL"; else curl -fsSL -o "$tmp" "$URL"; fi
if [ ! -s "$tmp" ] || ! head -n1 "$tmp" | grep -q '^#!/bin/bash' || ! grep -q "$NEW" "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    logger -t plesk-slave-zone-cleanup -- "ERROR: could not download $NEW from $URL" 2>/dev/null
    echo "Error: could not download a valid $NEW from $URL" >&2
    exit 1
fi
chmod 700 "$tmp"
exec bash "$tmp" install
