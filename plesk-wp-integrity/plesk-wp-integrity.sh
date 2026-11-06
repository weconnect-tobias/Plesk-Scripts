#!/usr/bin/env bash
# plesk-wp-integrity - verify WordPress core and plugin files on a Plesk server, and repair them
#
# Uses WP Toolkit's bundled wp-cli to compare every WordPress installation against the
# official checksums from wordpress.org: core files, and plugins from the wordpress.org
# directory. Modified PHP files are also searched for typical backdoor code.
#
# Usage:
#   plesk-wp-integrity                      # check all installations, change nothing
#   plesk-wp-integrity -d example.com       # only installations whose URL contains this
#   plesk-wp-integrity -i 122               # only WP Toolkit instance 122
#   plesk-wp-integrity --core-only          # skip the plugin check (faster)
#   plesk-wp-integrity --fix -d example.com # repair: show the plan, ask, then repair
#   plesk-wp-integrity --fix --yes          # repair without asking (all installations!)
#   plesk-wp-integrity --restore DIR        # undo a repair, using its quarantine folder
#
# What --fix does (nothing is deleted):
#   - modified or missing core files: reinstalled from wordpress.org, same version
#   - extra files in wp-admin, wp-includes and the root: moved to quarantine
#   - wordpress.org plugins with modified files: reinstalled, same version
#   - files a plugin should not have: moved to quarantine
#   Every file that is replaced or moved is saved under /var/backups/plesk-wp-integrity/<time>/
#   first, and --restore puts it all back.
# Never touched: plugins not on wordpress.org (premium/custom), themes, uploads, wp-config.php.
#
# Run as a regular sudo user; the script re-runs itself with sudo when needed. MIT license.

set -uo pipefail

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi
export LC_ALL=C

FIX=0; YES=0; DOM=""; IID=""; RESTORE=""; PLUGINS=1
while [ $# -gt 0 ]; do
  case $1 in
    --fix) FIX=1 ;;
    --yes|-y) YES=1 ;;
    -d) DOM=${2:-}; shift ;;
    -i) IID=${2:-}; shift ;;
    --core-only) PLUGINS=0 ;;
    --restore) RESTORE=${2:-}; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
  shift
done

QBASE=${PWI_QUARANTINE:-/var/backups/plesk-wp-integrity}
TS=$(date +%Y%m%d-%H%M%S)
Q="$QBASE/$TS"
SUSP='(system|exec|passthru|shell_exec)[[:space:]]*\([[:space:]]*\$_(GET|POST|REQUEST|COOKIE)|eval[[:space:]]*\(|base64_decode|gzinflate|gzuncompress|str_rot13|assert[[:space:]]*\([[:space:]]*\$|create_function|\$_(POST|GET|REQUEST|COOKIE)\[[^]]+\][[:space:]]*\(|(shell_exec|passthru|proc_open|popen)[[:space:]]*\(|preg_replace[[:space:]]*\(.*/e'
# Core files that are often removed on purpose; their absence is not a problem.
OPTIONAL_CORE='^(readme\.html|license\.txt|wp-config-sample\.php|liesmich\.html|licens\.html)$'

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'; else B=""; R=""; Y=""; G=""; N=""; fi

# Run wp-cli through WP Toolkit and strip its noise: Plesk's error log lines, PHP deprecation
# warnings from the bundled wp-cli, and the duplicate copy of the output in the error message.
wpt() {
  local id=$1; shift
  plesk ext wp-toolkit --wp-cli -instance-id "$id" -- "$@" < /dev/null 2>&1 \
    | grep -vE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+\]|^(PHP )?Deprecated: |^exit status [0-9]+$|^[[:space:]]*$' \
    | awk '!seen[$0]++'
}

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$Q/manifest.tsv"; }   # action original saved

# Save a copy of a file before it is overwritten.
save_copy() {
  local f=$1 dest="$Q/files$1"
  mkdir -p "$(dirname "$dest")"; cp -p "$f" "$dest" && record copied "$f" "$dest"
}
# Move a file out of the web root into quarantine.
quarantine() {
  local f=$1 dest="$Q/files$1"
  mkdir -p "$(dirname "$dest")"; mv "$f" "$dest" && record moved "$f" "$dest" && echo "    quarantined $f"
}

# ---------- restore ----------
if [ -n "$RESTORE" ]; then
  M="$RESTORE/manifest.tsv"
  [ -f "$M" ] || { echo "No manifest.tsv in $RESTORE"; exit 1; }
  # Newest actions first, so a plugin archive is restored before single files on top of it.
  tac "$M" | while IFS=$'\t' read -r action orig saved; do
    case $action in
      moved)  if [ -e "$orig" ]; then echo "${Y}skip${N} $orig exists"; else mkdir -p "$(dirname "$orig")"; mv "$saved" "$orig" && echo "restored $orig"; fi ;;
      copied) cp -p "$saved" "$orig" && echo "restored $orig" ;;
      plugin) parent=$(dirname "$orig"); rm -rf "$orig" && tar -xzpf "$saved" -C "$parent" && echo "restored plugin $orig" ;;
    esac
  done
  exit 0
fi

command -v plesk >/dev/null 2>&1 || { echo "plesk command not found: this script needs Plesk with WP Toolkit."; exit 1; }

echo "${B}plesk-wp-integrity${N}  host=$(hostname -f 2>/dev/null || hostname)  $(date '+%F %T')  mode=$([ "$FIX" = 1 ] && echo fix || echo check)"
mapfile -t INST < <(plesk ext wp-toolkit --list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {
  u = ""; for (i = 1; i <= NF; i++) if ($i ~ /^https?:\/\//) u = $i; print $1 "\t" u }')
[ ${#INST[@]} -gt 0 ] || { echo "WP Toolkit lists no installations."; exit 0; }

TOTAL=0; DIRTY=0; STALE=0; FIXED=0; FINDINGS=0

for line in "${INST[@]}"; do
  id=${line%%$'\t'*}; url=${line#*$'\t'}
  [ -n "$IID" ] && [ "$id" != "$IID" ] && continue
  [ -n "$DOM" ] && [[ "$url" != *"$DOM"* ]] && continue
  TOTAL=$((TOTAL + 1))

  cfg=$(wpt "$id" config path | grep -m1 '^/')
  if [ -z "$cfg" ]; then
    root=$(wpt "$id" eval 'echo rtrim(ABSPATH, "/");' | grep -m1 '^/')
  else
    root=$(dirname "$cfg")
  fi
  # wp-config.php may sit one level above the installation.
  [ -n "$root" ] && [ ! -f "$root/wp-includes/version.php" ] && [ -f "$root/wordpress/wp-includes/version.php" ] && root="$root/wordpress"
  if [ -z "$root" ] || [ ! -f "$root/wp-includes/version.php" ]; then
    echo; echo "${B}=== $url${N} (instance $id)"
    echo "  ${Y}Installation not found on disk.${N} Stale WP Toolkit entry? Remove it in WP Toolkit if the site is gone."
    STALE=$((STALE + 1)); continue
  fi
  ver=$(sed -nE "s/.*\\\$wp_version = '([^']+)'.*/\1/p" "$root/wp-includes/version.php" | head -1)

  # ---------- core ----------
  core=$(wpt "$id" core verify-checksums)
  mapfile -t C_MOD   < <(sed -nE "s/^Warning: File doesn't verify against checksum: (.*)$/\1/p" <<< "$core")
  mapfile -t C_EXTRA < <(sed -nE "s/^Warning: File should not exist: (.*)$/\1/p" <<< "$core")
  mapfile -t C_MISS  < <(sed -nE "s/^Warning: File doesn't exist: (.*)$/\1/p" <<< "$core" | grep -vE "$OPTIONAL_CORE")
  core_err=$(grep -E '^Error: ' <<< "$core" | grep -v "doesn't verify against checksums" | head -1)

  # ---------- plugins ----------
  declare -A P_MOD=() P_ADD=() P_MISS=() P_PHP=() P_SUSP=()
  P_LIST=(); P_SKIP=()
  if [ "$PLUGINS" = 1 ]; then
    pout=$(wpt "$id" plugin verify-checksums --all --format=csv)
    while IFS=, read -r slug file msg; do
      [ "$slug" = plugin_name ] && continue
      [ -z "${P_MOD[$slug]+x}" ] && { P_LIST+=("$slug"); P_MOD[$slug]=0; P_ADD[$slug]=0; P_MISS[$slug]=0; P_PHP[$slug]=""; P_SUSP[$slug]=""; }
      case $msg in
        "Checksum does not match") P_MOD[$slug]=$((P_MOD[$slug] + 1)) ;;
        "File was added")          P_ADD[$slug]=$((P_ADD[$slug] + 1)) ;;
        "File is missing")         P_MISS[$slug]=$((P_MISS[$slug] + 1)) ;;
        *) continue ;;
      esac
      if [[ "$file" =~ \.(php[0-9]?|phtml|phar|inc)$ ]] && [ "$msg" != "File is missing" ]; then
        P_PHP[$slug]+="$file"$'\n'
        pdir="$root/wp-content/plugins/$slug"; [ -d "$pdir" ] || pdir="$root/wp-content/plugins"
        grep -qsE "$SUSP" "$pdir/$file" && P_SUSP[$slug]+="$file"$'\n'
      fi
    done < <(grep -E '^[^,]+,[^,]+,(Checksum does not match|File was added|File is missing)$|^plugin_name,' <<< "$pout")
    mapfile -t P_SKIP < <(sed -nE 's#.*plugin-checksums/([^/]+)/([^/]+)\.json.*#\1 \2#p' <<< "$pout"; \
                          sed -nE 's/.*Could not retrieve the checksums for version ([^ ]+) of plugin ([^,]+),.*/\2 \1/p' <<< "$pout")
  fi

  issues=$(( ${#C_MOD[@]} + ${#C_EXTRA[@]} + ${#C_MISS[@]} + ${#P_LIST[@]} ))
  if [ "$issues" -eq 0 ] && [ -z "$core_err" ]; then continue; fi
  DIRTY=$((DIRTY + 1))

  echo; echo "${B}=== $url${N} (instance $id, WordPress $ver, $root)"
  [ -n "$core_err" ] && echo "  ${Y}core check failed:${N} $core_err"
  for f in "${C_MOD[@]}"; do
    s=""; grep -qsE "$SUSP" "$root/$f" && s="  ${R}SUSPICIOUS CODE${N}"
    echo "  ${R}core modified${N}  $f$s"; FINDINGS=$((FINDINGS + 1))
  done
  for f in "${C_MISS[@]}"; do echo "  ${Y}core missing${N}   $f"; FINDINGS=$((FINDINGS + 1)); done
  for f in "${C_EXTRA[@]}"; do
    p="$root/$f"; info=$(stat -c '%s bytes, changed %y' "$p" 2>/dev/null | cut -d. -f1)
    s=""; grep -qsE "$SUSP" "$p" && s="  ${R}SUSPICIOUS CODE${N}"
    echo "  ${Y}core extra${N}     $f ($info)$s"; FINDINGS=$((FINDINGS + 1))
  done
  for slug in "${P_LIST[@]}"; do
    nphp=$(printf '%s' "${P_PHP[$slug]}" | grep -c .)
    note=""
    # Every file differing, including CSS/JS, almost always means a different version
    # than wordpress.org has checksums for, not an injected backdoor.
    total_mod=$((P_MOD[$slug] + P_ADD[$slug]))
    [ "$total_mod" -gt "$nphp" ] && [ "$total_mod" -ge 5 ] && note=" ${Y}(non-PHP files differ too: probably a different version)${N}"
    echo "  ${Y}plugin${N} $slug: ${P_MOD[$slug]} modified, ${P_ADD[$slug]} added, ${P_MISS[$slug]} missing, $nphp PHP$note"
    if [ -n "${P_SUSP[$slug]}" ]; then
      printf '%s' "${P_SUSP[$slug]}" | sed "s/^/    ${R}SUSPICIOUS CODE${N} /"
    elif [ "$nphp" -gt 0 ] && [ "$nphp" -le 5 ]; then
      printf '%s' "${P_PHP[$slug]}" | sed 's/^/    /'
    fi
    FINDINGS=$((FINDINGS + 1))
  done
  [ ${#P_SKIP[@]} -gt 0 ] && echo "  not on wordpress.org, not checked: $(printf '%s ' "${P_SKIP[@]}" | awk '{for (i = 1; i <= NF; i += 2) printf "%s%s", (i > 1 ? ", " : ""), $i}')"

  # ---------- fix ----------
  [ "$FIX" = 1 ] || continue
  plan=()
  [ $(( ${#C_MOD[@]} + ${#C_MISS[@]} )) -gt 0 ] && plan+=("reinstall WordPress $ver core files (modified ones are saved first)")
  [ ${#C_EXTRA[@]} -gt 0 ] && plan+=("move ${#C_EXTRA[@]} extra core file(s) to quarantine")
  fixable=()
  for slug in "${P_LIST[@]}"; do
    if [ -d "$root/wp-content/plugins/$slug" ]; then fixable+=("$slug"); plan+=("reinstall plugin $slug from wordpress.org, same version (old copy saved)")
    else echo "  ${Y}plugin $slug is a single file; repair it by hand${N}"; fi
  done
  [ ${#plan[@]} -gt 0 ] || continue
  echo "  ${B}Plan:${N}"; printf '    - %s\n' "${plan[@]}"
  if [ "$YES" = 0 ]; then
    read -r -p "  Repair $url now? [y/N] " ans < /dev/tty || ans=""
    [[ "$ans" =~ ^[yYjJ] ]] || { echo "  skipped"; continue; }
  fi
  mkdir -p "$Q"; chmod 700 "$QBASE" "$Q"

  if [ $(( ${#C_MOD[@]} + ${#C_MISS[@]} )) -gt 0 ]; then
    for f in "${C_MOD[@]}"; do save_copy "$root/$f"; done
    wpt "$id" core download --version="$ver" --skip-content --force | sed 's/^/    /'
  fi
  for f in "${C_EXTRA[@]}"; do quarantine "$root/$f"; done

  for slug in "${fixable[@]}"; do
    pdir="$root/wp-content/plugins/$slug"
    pver=$(wpt "$id" plugin get "$slug" --field=version | grep -m1 -E '^[0-9]')
    [ -n "$pver" ] || { echo "    ${Y}could not read the version of $slug, skipped${N}"; continue; }
    arc="$Q/plugins/$slug-$pver.tar.gz"; mkdir -p "$Q/plugins"
    tar -czpf "$arc" -C "$root/wp-content/plugins" "$slug" && record plugin "$pdir" "$arc"
    wpt "$id" plugin install "$slug" --version="$pver" --force | sed 's/^/    /'
    # Files that are still not part of the official plugin go to quarantine.
    wpt "$id" plugin verify-checksums "$slug" --format=csv | awk -F, '$3 == "File was added" {print $2}' \
      | while IFS= read -r f; do quarantine "$pdir/$f"; done
  done

  after=$(wpt "$id" core verify-checksums | grep -cE "^Warning: File (doesn't verify|should not exist)")
  if [ "$after" -eq 0 ]; then echo "  ${G}core now verifies against checksums${N}"; else echo "  ${Y}core still has $after finding(s)${N}"; fi
  FIXED=$((FIXED + 1))
done

echo
echo "${B}Summary:${N} $TOTAL installation(s) checked, $DIRTY with findings ($FINDINGS item(s)), $STALE not found on disk$([ "$FIX" = 1 ] && echo ", $FIXED repaired")."
if [ "$FIX" = 1 ] && [ -d "$Q" ]; then
  echo "Everything replaced or moved is saved in $Q"
  echo "Undo with: plesk-wp-integrity --restore $Q"
elif [ "$DIRTY" -gt 0 ]; then
  echo "Check the PHP files listed above (especially SUSPICIOUS CODE) before repairing."
  echo "Repair one site at a time: plesk-wp-integrity --fix -d <domain>"
fi
[ "$DIRTY" -eq 0 ]
