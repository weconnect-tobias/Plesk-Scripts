#!/usr/bin/env bash
# plesk-cron-cleanup - find and clean up broken user crontabs on a Plesk server
#
# When Plesk subscriptions are deleted, their crontab files can be left behind. Later,
# a new system user may get the same UID and suddenly "own" someone else's crontab.
# cron refuses to load such files, and in some cases the cron daemon ends up re-reading
# its spool in a tight loop, using a full CPU core and keeping systemd busy as well.
#
# Usage:
#   plesk-cron-cleanup                # dry run: show what is wrong, change nothing
#   plesk-cron-cleanup --apply        # move orphaned crontabs to a backup folder, restart cron
#   plesk-cron-cleanup --fix-owner    # also give wrong-owner crontabs back to their named user
#   plesk-cron-cleanup --restore DIR  # put crontabs from a backup folder back
#
# Run as a regular sudo user; the script re-runs itself with sudo when needed.
# Nothing is deleted: files are only moved to /var/backups/plesk-cron-cleanup/<time>/.
# MIT license.

set -uo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi
export LC_ALL=C
shopt -s nullglob

APPLY=0; FIX_OWNER=0; RESTORE=""
while [ $# -gt 0 ]; do
  case $1 in
    --apply) APPLY=1 ;;
    --fix-owner) APPLY=1; FIX_OWNER=1 ;;
    --restore) RESTORE=${2:-}; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

# Debian/Ubuntu keep user crontabs in crontabs/, RHEL-based systems directly in the spool.
if [ -n "${CRON_SPOOL:-}" ]; then SPOOL=$CRON_SPOOL; CGROUP=root; CRON="cron"
elif [ -d /var/spool/cron/crontabs ]; then SPOOL=/var/spool/cron/crontabs; CGROUP="crontab"; CRON="cron"
else SPOOL=/var/spool/cron; CGROUP=root; CRON="crond"; fi
BACKUP_BASE=${CRON_BACKUP:-/var/backups/plesk-cron-cleanup}
VHOSTS=${VHOSTS:-/var/www/vhosts}

if [ -t 1 ]; then B=$'\033[1m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'; else B=""; Y=""; G=""; N=""; fi

cron_cpu() {
  local pid et ct; pid=$(systemctl show -p MainPID --value "$CRON" 2>/dev/null)
  [ "${pid:-0}" -gt 0 ] || { echo "cron daemon not running"; return; }
  read -r et ct < <(ps -o etimes=,times= -p "$pid")
  awk -v e="$et" -v c="$ct" -v p="$pid" 'BEGIN { printf "cron daemon (pid %s): %.2f %% CPU on average since start (normal is close to 0)\n", p, (e > 0 ? 100 * c / e : 0) }'
}

# Does a crontab still point at something that exists on this server?
still_relevant() {
  local f=$1 hit=""
  while IFS= read -r p; do [ -e "$p" ] && hit="$hit $p"; done < <(grep -oE "$VHOSTS/[^/[:space:]'\"]+" "$f" | sort -u)
  while IFS= read -r d; do [ -d "$VHOSTS/system/$d" ] && hit="$hit $d"; done < <(grep -oE 'https?://[^/[:space:]"'"'"']+' "$f" | sed -E 's#https?://(www\.)?##' | sort -u)
  echo "$hit"
}

# ---------- restore ----------
if [ -n "$RESTORE" ]; then
  [ -d "$RESTORE" ] || { echo "No such folder: $RESTORE"; exit 1; }
  for f in "$RESTORE"/*; do
    [ -f "$f" ] || continue
    if [ -e "$SPOOL/${f##*/}" ]; then echo "${Y}skip${N} ${f##*/}: already exists in $SPOOL"; continue; fi
    cp -p "$f" "$SPOOL/" && echo "restored ${f##*/}"
  done
  systemctl restart "$CRON" && echo "cron restarted"
  exit 0
fi

echo "${B}plesk-cron-cleanup${N}  host=$(hostname -f 2>/dev/null || hostname)  spool=$SPOOL  mode=$([ "$APPLY" = 1 ] && echo apply || echo dry-run)"
cron_cpu
echo

ORPHANS=(); WRONG=(); MODE=()
for f in "$SPOOL"/*; do
  [ -f "$f" ] || continue
  name=${f##*/}; owner=$(stat -c %U "$f"); perm=$(stat -c %a "$f")
  if ! getent passwd "$name" >/dev/null; then ORPHANS+=("$f")
  elif [ "$owner" != "$name" ]; then WRONG+=("$f")
  elif [ "$perm" != 600 ]; then MODE+=("$f")
  fi
done

if [ ${#ORPHANS[@]} -eq 0 ] && [ ${#WRONG[@]} -eq 0 ] && [ ${#MODE[@]} -eq 0 ]; then
  echo "${G}All crontabs are fine.${N}"; exit 0
fi

if [ ${#ORPHANS[@]} -gt 0 ]; then
  echo "${B}Orphaned crontabs${N} (the user no longer exists, cron never runs these): ${#ORPHANS[@]}"
  for f in "${ORPHANS[@]}"; do
    rel=$(still_relevant "$f")
    printf '  %-28s owner %-16s %s\n' "${f##*/}" "$(stat -c %U "$f")" "${rel:+${Y}refers to existing:$rel${N}}"
  done
  echo "  Crontabs marked 'refers to existing' point at sites still on this server. Their jobs have not been"
  echo "  running; recreate them under the right subscription in Plesk (Scheduled Tasks) if they are still needed."
  echo
fi

if [ ${#WRONG[@]} -gt 0 ]; then
  echo "${B}Wrong owner${N} (the user exists, but the file is owned by someone else, so cron skips it): ${#WRONG[@]}"
  for f in "${WRONG[@]}"; do
    printf '  %-28s owned by %s\n' "${f##*/}" "$(stat -c %U "$f")"
    grep -vE '^[[:space:]]*(#|$)' "$f" | head -5 | sed 's/^/      /'
  done
  echo "  Check that each file really belongs to the user in its name before using --fix-owner."
  echo
fi

if [ ${#MODE[@]} -gt 0 ]; then
  echo "${B}Wrong permissions${N} (should be 600): ${#MODE[@]}"
  for f in "${MODE[@]}"; do printf '  %-28s mode %s\n' "${f##*/}" "$(stat -c %a "$f")"; done
  echo
fi

if [ "$APPLY" = 0 ]; then
  echo "Dry run, nothing changed."
  echo "  --apply      moves the orphaned crontabs to $BACKUP_BASE/<time>/ and fixes permissions"
  echo "  --fix-owner  also gives wrong-owner crontabs back to the user in their file name"
  exit 1
fi

# ---------- apply ----------
BK="$BACKUP_BASE/$(date +%Y%m%d-%H%M%S)"; changed=0
if [ ${#ORPHANS[@]} -gt 0 ]; then
  mkdir -p "$BK"; chmod 700 "$BK"
  for f in "${ORPHANS[@]}"; do mv "$f" "$BK/" && echo "moved ${f##*/} -> $BK/" && changed=1; done
fi
for f in "${MODE[@]}"; do chmod 600 "$f" && chgrp "$CGROUP" "$f" && echo "fixed permissions on ${f##*/}" && changed=1; done
if [ ${#WRONG[@]} -gt 0 ]; then
  if [ "$FIX_OWNER" = 1 ]; then
    for f in "${WRONG[@]}"; do
      chown "${f##*/}:$CGROUP" "$f" && chmod 600 "$f" && echo "gave ${f##*/} back to user ${f##*/}" && changed=1
    done
    echo "${Y}Note:${N} those jobs start running again now. They may have been stopped for a long time."
  else
    echo "Left ${#WRONG[@]} wrong-owner crontab(s) alone (use --fix-owner after checking them)."
  fi
fi

if [ "$changed" = 1 ]; then
  systemctl restart "$CRON" && echo "${G}cron restarted${N}"
  [ -d "$BK" ] && echo "Undo with: plesk-cron-cleanup --restore $BK"
  echo
  sleep 5; cron_cpu
fi
