#!/usr/bin/env bash
# plesk-compromise-check - look for signs that a Plesk server or one of its sites is compromised
#
# Scans for webshells, PHP in upload folders, hidden PHP files, auto_prepend backdoors,
# shells spawned by the web server, malware running from /tmp, suspicious cron jobs,
# rogue accounts and SSH keys, modified system binaries, PHP-FPM crashes, and WordPress
# admins created recently, hidden WordPress users and modified WordPress core files.
# Every finding is mapped to a site and, for files, checked against that site's access logs.
#
# Usage:
#   plesk-compromise-check                   # look back 30 days, all sites
#   plesk-compromise-check -s 2026-10-01     # look back to a given date
#   plesk-compromise-check -d example.com    # only this subscription
#   plesk-compromise-check -f                # full scan: grep every PHP file, not just recent ones (slow)
#   plesk-compromise-check -W                # skip the WordPress checks
#   plesk-compromise-check -v                # list every finding (default: 15 per category)
#
# Exit code: 0 = nothing found, 1 = review needed, 2 = likely compromise.
# Run as a regular sudo user; the script re-runs itself with sudo when needed.
# Read-only, changes nothing. "Nothing found" is not proof that a server is clean.
# MIT license.

set -uo pipefail

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi
export LC_ALL=C
shopt -s nullglob

SINCE=$(date -d '-30 days' +%F); DOM=""; FULL=0; WP_CHECK=1; VERBOSE=0
while getopts "s:d:fWvh" o; do
  case $o in
    s) SINCE=$OPTARG ;; d) DOM=$OPTARG ;; f) FULL=1 ;; W) WP_CHECK=0 ;; v) VERBOSE=1 ;; *) usage ;;
  esac
done
date -d "$SINCE" >/dev/null 2>&1 || { echo "Invalid date: $SINCE"; exit 1; }

VHOSTS=${VHOSTS:-/var/www/vhosts}
TS=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FINDINGS=$TMP/findings.tsv; : > "$FINDINGS"

# Report goes to the home of the user who ran sudo, so they can read it without root.
RUN_USER=${SUDO_USER:-root}
RUN_HOME=$(getent passwd "$RUN_USER" | cut -d: -f6); RUN_HOME=${RUN_HOME:-/root}
REPORT="$RUN_HOME/plesk-compromise-check-$(hostname -s)-$TS.txt"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; N=$'\033[0m'; else B=""; R=""; Y=""; G=""; N=""; fi

add() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FINDINGS"; }   # severity site category detail

# Map a path under the vhosts directory to its site name.
site_of_path() {
  awk -F/ -v v="$VHOSTS" 'BEGIN { n = split(v, p, "/") }
    { if (index($0, v "/") == 1) { s = $(n + 1); if (s == "system") s = $(n + 2); print s } else print "SERVER" }' <<< "$1"
}
# Map a system user to its site via its home directory.
site_of_user() {
  local home; home=$(getent passwd "$1" | cut -d: -f6)
  case "$home" in "$VHOSTS"/*) site_of_path "$home" ;; *) echo "SERVER" ;; esac
}
# Directories to scan: one subscription or all of them.
scan_roots() {
  if [ -n "$DOM" ]; then [ -d "$VHOSTS/$DOM" ] && echo "$VHOSTS/$DOM"
  else for d in "$VHOSTS"/*/; do d=${d%/}; case "${d##*/}" in system|default|chroot|fs|.skel) continue ;; esac; echo "$d"; done
  fi
}

# For a file inside a web root, show how often it was requested and by whom.
log_hits() {
  local f=$1 site rel logs url tmp
  site=$(site_of_path "$f")
  rel=${f#"$VHOSTS/$site/"}
  case "$rel" in
    httpdocs/*) url="/${rel#httpdocs/}"; logs=("$VHOSTS/system/$site/logs"/*access*log*) ;;
    */*) local sub=${rel%%/*}
         if [ -d "$VHOSTS/system/$sub/logs" ]; then url="/${rel#*/}"; logs=("$VHOSTS/system/$sub/logs"/*access*log*)
         else return; fi ;;
    *) return ;;
  esac
  [ ${#logs[@]} -gt 0 ] || return
  tmp=$TMP/hits
  zcat -f -- "${logs[@]}" 2>/dev/null | grep -F "\"$(printf 'GET %s' "$url")" > "$tmp"
  zcat -f -- "${logs[@]}" 2>/dev/null | grep -F "\"$(printf 'POST %s' "$url")" >> "$tmp"
  local n; n=$(wc -l < "$tmp")
  if [ "$n" -eq 0 ]; then echo "      access log: no requests to $url in available logs"; return; fi
  awk -v url="$url" '
    { if ($6 ~ /POST/) post++; ip[$1]++; t = substr($4, 2)
      m = (index("JanFebMarAprMayJunJulAugSepOctNovDec", substr(t, 4, 3)) + 2) / 3
      k = substr(t, 8, 4) sprintf("%02d", m) substr(t, 1, 2) substr(t, 13, 8)
      if (first == "" || k < fk) { fk = k; first = t }
      if (last == "" || k > lk) { lk = k; last = t } }
    END { printf "      access log: %d requests to %s (%d POST), first %s, last %s\n", NR, url, post, first, last
          printf "      from:"; c = 0; for (i in ip) { printf " %s(%d)", i, ip[i]; if (++c >= 5) break }; print "" }' "$tmp"
}

explain() {
  case $1 in
    webshell)      echo "PHP code with typical backdoor/webshell patterns (eval of decoded data, running request data as code or commands)." ;;
    upload_php)    echo "Executable PHP in an upload folder. Upload folders should only hold media; PHP there is almost always a dropped backdoor." ;;
    hidden_php)    echo "PHP file whose name starts with a dot. Legitimate code rarely does this; attackers use it to hide backdoors." ;;
    prepend)       echo "auto_prepend_file/auto_append_file makes PHP run a file before or after every request. A classic way to inject a backdoor into every page." ;;
    web_shell_proc) echo "A shell or network tool started by the web server or PHP. On a normal web server PHP should not spawn shells; this is the strongest sign of remote code execution." ;;
    tmp_exec)      echo "Process running from /tmp, /var/tmp, /dev/shm or a deleted file. Typical for cryptominers and dropped malware." ;;
    tmp_file)      echo "Executable or script in a temp directory. Often a dropped payload waiting to run." ;;
    listener)      echo "A site user is listening on a network port. Hosting accounts should not run servers; could be a backdoor or a bind shell." ;;
    outbound)      echo "Connection to a port commonly used by reverse shells, IRC bots or mining pools." ;;
    cron)          echo "Cron job that downloads and runs code, decodes base64 or runs from a temp directory. A common way to persist after a break-in." ;;
    systemd)       echo "Systemd unit starting a program from a temp or web directory." ;;
    root_user)     echo "An account other than root with UID 0 has full root rights." ;;
    ssh_key)       echo "SSH authorized_keys changed in the scan window. Check that every key is known." ;;
    shell_access)  echo "A web server user has a login shell, which it never needs." ;;
    ld_preload)    echo "/etc/ld.so.preload loads a library into every process. Used by userland rootkits to hide themselves." ;;
    modified_bin)  echo "A system binary differs from its package checksum. Possible rootkit or trojanized tool." ;;
    fpm_crash)     echo "PHP-FPM workers crashed (SIGSEGV/SIGABRT). Can be bugs, but also exploitation attempts against memory-corruption flaws." ;;
    wp_admin)      echo "WordPress administrator created in the scan window. Creating a rogue admin is one of the first things attackers do." ;;
    wp_hidden)     echo "The database holds more WordPress users than WordPress shows. Malware hides admin accounts this way." ;;
    wp_core)       echo "WordPress core file modified or added. Core files should match wordpress.org exactly." ;;
    *)             echo "" ;;
  esac
}

main() {
  echo "${B}plesk-compromise-check${N}  host=$(hostname -f 2>/dev/null || hostname)  $(date '+%F %T %Z')  since=$SINCE  full=$FULL${DOM:+  domain=$DOM}"
  command -v plesk >/dev/null 2>&1 && echo "Plesk: $(plesk version 2>/dev/null | awk -F': *' '/Product version/ {print $2}')"
  echo "Scanning..."

  mapfile -t ROOTS < <(scan_roots)
  [ ${#ROOTS[@]} -gt 0 ] || { echo "No sites found under $VHOSTS${DOM:+/$DOM}"; return 0; }
  local prune=( \( -path '*/node_modules' -o -path '*/.git' -o -path '*/logs' -o -path '*/.cache' \) -prune -o )

  # ---------- files: webshells ----------
  local pat='eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|str_rot13|strrev|rawurldecode|hex2bin)[[:space:]]*\(|assert[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE)|(system|passthru|shell_exec|exec|popen|proc_open)[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE|SERVER)|\$_(POST|GET|REQUEST|COOKIE)\[[^]]{1,40}\][[:space:]]*\(|FilesMan|b374k|WSOsetcookie|c99shell|r57shell|\\x65\\x76\\x61\\x6c|move_uploaded_file[[:space:]]*\(\$_FILES[^;]{0,80}\$_(GET|POST|REQUEST)'
  local newer=(); [ "$FULL" = 1 ] || newer=(-newermt "$SINCE")
  find "${ROOTS[@]}" "${prune[@]}" -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.php[0-9]' -o -iname '*.phar' -o -iname '*.inc' \) \
       -size -5M "${newer[@]}" -print0 2>/dev/null \
    | xargs -0 -r grep -lsE "$pat" 2>/dev/null \
    | grep -v '/wordfence/' | while IFS= read -r f; do add HIGH "$(site_of_path "$f")" webshell "$f"; done

  # ---------- files: PHP in upload folders ----------
  # Plugins that legitimately keep PHP in uploads: icon font maps, mail/page-builder caches,
  # page templates, firewall rules and PDF font metrics.
  local known_uploads='/uploads/(smile_fonts/[^/]+/charmap\.php|mailpoet/cache/|fusion-builder-avada-pages/|aios/firewall-rules/|fonts/[^/]+\.php$|wpforms/cache/|et-cache/|bb-plugin/cache/)'
  find "${ROOTS[@]}" "${prune[@]}" -type f -path '*/wp-content/uploads/*' \
       \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.php[0-9]' -o -iname '*.phar' \) -print 2>/dev/null \
    | while IFS= read -r f; do
        # WordPress drops tiny "silence is golden" index.php files; ignore those.
        [ "${f##*/}" = index.php ] && [ "$(stat -c %s "$f")" -lt 200 ] && continue
        # Known plugin files that live in uploads: only flag them if they contain backdoor code.
        if [[ "$f" =~ $known_uploads ]]; then
          grep -qsE "$pat" "$f" && add HIGH "$(site_of_path "$f")" webshell "$f"
          continue
        fi
        add HIGH "$(site_of_path "$f")" upload_php "$f"
      done

  # ---------- files: hidden PHP ----------
  find "${ROOTS[@]}" "${prune[@]}" -type f -name '.*' \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.php[0-9]' \) -print 2>/dev/null \
    | while IFS= read -r f; do
        case "${f##*/}" in ._*) continue ;; esac                      # macOS resource forks, not code
        if [[ "$f" == */vendor/* ]]; then                            # dev tool files in libraries
          grep -qsE "$pat" "$f" && add HIGH "$(site_of_path "$f")" webshell "$f"
          continue
        fi
        add MEDIUM "$(site_of_path "$f")" hidden_php "$f"
      done

  # ---------- auto_prepend / auto_append ----------
  {
    find "${ROOTS[@]}" "${prune[@]}" -type f \( -name '.user.ini' -o -name '.htaccess' -o -name 'php.ini' \) -print 2>/dev/null
    [ -n "$DOM" ] && ls "$VHOSTS/system/$DOM/etc/php.ini" 2>/dev/null || ls "$VHOSTS"/system/*/etc/php.ini 2>/dev/null
    ls /opt/plesk/php/*/etc/php.ini /opt/plesk/php/*/etc/php.d/*.ini /opt/plesk/php/*/etc/php-fpm.d/*.conf /etc/php/*/*/php.ini /etc/php/*/*/conf.d/*.ini /etc/php/*/fpm/pool.d/*.conf 2>/dev/null
  } | sort -u | while IFS= read -r f; do
      grep -HnE '^[^;#]*(auto_prepend_file|auto_append_file)([[:space:]]*=[[:space:]]*|[[:space:]]+)"?[^"=[:space:];]+' "$f" 2>/dev/null \
        | grep -viE '(wordfence-waf|ninjafirewall|admintools-waf|aios-bootstrap)\.php|=[[:space:]]*"?none"?[[:space:]]*$|=[[:space:]]*""' \
        | while IFS= read -r l; do add HIGH "$(site_of_path "$f")" prepend "$l"; done
    done

  # ---------- processes ----------
  ps -eo pid=,ppid=,user:32=,comm= > "$TMP/ps.txt"
  awk 'NR == FNR { comm[$1] = $4; next }
       $4 ~ /^(sh|bash|dash|zsh|ash|busybox|curl|wget|nc|ncat|netcat|socat|perl|python[0-9.]*|ruby|telnet)$/ &&
       comm[$2] ~ /^(php-fpm|php-cgi|php|apache2|httpd|nginx|sw-engine|sw-engine-fpm|lsphp)/ { print $1, $3, $4, comm[$2] }' \
       "$TMP/ps.txt" "$TMP/ps.txt" | while read -r pid user c parent; do
    local args; args=$(ps -o args= -p "$pid" 2>/dev/null)
    case "$args" in *sendmail*|*qmail-inject*) continue ;; esac   # PHP mail() runs sendmail via sh
    add HIGH "$(site_of_user "$user")" web_shell_proc "pid $pid user $user: $c started by $parent: ${args:0:200}"
  done
  for p in /proc/[0-9]*; do
    local exe; exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "$exe" in
      /tmp/*|/var/tmp/*|/dev/shm/*|*" (deleted)")
        case "$exe" in /usr/*" (deleted)"|/lib/*" (deleted)"|/opt/*" (deleted)"|*/memfd:*) continue ;; esac   # upgraded packages, JIT
        local pid=${p#/proc/} user; user=$(ps -o user= -p "$pid" 2>/dev/null)
        add HIGH "$(site_of_user "$user")" tmp_exec "pid $pid user $user exe $exe: $(ps -o args= -p "$pid" 2>/dev/null | cut -c1-150)" ;;
    esac
  done

  # ---------- network ----------
  ss -Htlnp 2>/dev/null | while read -r _ _ _ local _ proc; do
    local pid; pid=$(grep -o 'pid=[0-9]*' <<< "$proc" | head -1 | cut -d= -f2); [ -n "$pid" ] || continue
    local uid user; uid=$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' '); user=$(ps -o user= -p "$pid" 2>/dev/null)
    [ "${uid:-0}" -ge 10000 ] && add MEDIUM "$(site_of_user "$user")" listener "user $user listens on $local ($(ps -o args= -p "$pid" | cut -c1-120))"
  done
  ss -Htnp state established 2>/dev/null | while read -r _ _ local peer proc; do
    case "${peer##*:}" in 4444|4445|5555|1337|31337|6666|6667|6697|3333|14444|45700|7777|9999|8333) ;; *) continue ;; esac
    local pid user; pid=$(grep -o 'pid=[0-9]*' <<< "$proc" | head -1 | cut -d= -f2)
    user=$(ps -o user= -p "${pid:-0}" 2>/dev/null)
    add HIGH "$(site_of_user "${user:-root}")" outbound "user ${user:-?} $local -> $peer ($(ps -o args= -p "${pid:-0}" 2>/dev/null | cut -c1-120))"
  done

  # ---------- temp directories ----------
  find /tmp /var/tmp /dev/shm "${ROOTS[@]/%//tmp}" -xdev -type f -newermt "$SINCE" \
       ! -path '/tmp/systemd-private-*' ! -path '*/.X11-unix/*' ! -path '/tmp/snap-private-tmp/*' 2>/dev/null \
    | while IFS= read -r f; do
        local magic owner; magic=$(head -c4 "$f" 2>/dev/null | od -An -c | tr -d ' ')
        owner=$(stat -c %U "$f")
        if [ "$magic" = '177ELF' ]; then
          [ "$owner" = root ] && sev=MEDIUM || sev=HIGH
          add "$sev" "$(site_of_user "$owner")" tmp_file "ELF binary $f (owner $owner)"
        elif [[ "$f" =~ \.(php|sh|pl|py)$ ]] || [ -x "$f" ]; then
          [ "$owner" = root ] && continue
          add MEDIUM "$(site_of_user "$owner")" tmp_file "script $f (owner $owner)"
        fi
      done

  # ---------- cron and systemd ----------
  local cronpat='(curl|wget)[^|#]*\|[[:space:]]*(ba)?sh|base64[[:space:]]+(-d|--decode)|/dev/tcp/|/dev/shm/|/tmp/[^[:space:]]*\.(sh|php|py|pl)|/var/tmp/'
  for f in /var/spool/cron/crontabs/* /var/spool/cron/* /etc/crontab /etc/cron.d/*; do
    [ -f "$f" ] || continue
    grep -HnE "$cronpat" "$f" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' | while IFS= read -r l; do
      local owner; owner=$(stat -c %U "$f")
      add HIGH "$(site_of_user "$owner")" cron "$l"
    done
  done
  for f in /etc/systemd/system/*.service /etc/systemd/system/*/*.service /lib/systemd/system/*.service; do
    grep -HE '^Exec(Start|StartPre)=[-@+!:]*(/tmp/|/var/tmp/|/dev/shm/|'"$VHOSTS"'/)' "$f" 2>/dev/null \
      | while IFS= read -r l; do add HIGH SERVER systemd "$l"; done
  done

  # ---------- accounts ----------
  awk -F: '$3 == 0 && $1 != "root" {print}' /etc/passwd | while IFS= read -r l; do add HIGH SERVER root_user "$l"; done
  find /root/.ssh /home/*/.ssh "${ROOTS[@]/%//.ssh}" -name 'authorized_keys*' -newermt "$SINCE" 2>/dev/null | while IFS= read -r f; do
    add MEDIUM "$(site_of_user "$(stat -c %U "$f")")" ssh_key "$f changed $(stat -c %y "$f" | cut -d. -f1), $(grep -c '^[^#]' "$f") key(s)"
  done
  for u in www-data apache nginx http wwwrun; do
    getent passwd "$u" | awk -F: '$7 ~ /\/(bash|sh|zsh|dash)$/ {print $1 " has login shell " $7}'
  done | while IFS= read -r l; do add HIGH SERVER shell_access "$l"; done

  # ---------- rootkit indicators ----------
  [ -s /etc/ld.so.preload ] && add HIGH SERVER ld_preload "/etc/ld.so.preload contains: $(tr '\n' ' ' < /etc/ld.so.preload)"
  if command -v dpkg >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    dpkg --verify coreutils procps openssh-server util-linux passwd login sudo iproute2 net-tools findutils lsof cron bash libc-bin 2>/dev/null \
      | awk '$1 ~ /^..5/ && $2 != "c" {print $NF}' | grep -E '/(s?bin|lib(64)?)/' \
      | while IFS= read -r f; do add HIGH SERVER modified_bin "$f differs from its package checksum"; done
  elif command -v rpm >/dev/null 2>&1; then
    rpm -V coreutils procps-ng openssh-server util-linux shadow-utils sudo iproute net-tools findutils lsof cronie bash glibc 2>/dev/null \
      | awk '$1 ~ /^..5/ && $2 != "c" {print $NF}' | grep -E '/(s?bin|lib(64)?)/' \
      | while IFS= read -r f; do add HIGH SERVER modified_bin "$f differs from its package checksum"; done
  fi

  # ---------- PHP-FPM crashes ----------
  local fpmlogs=(/var/log/plesk-php*-fpm/*.log* /var/log/php*-fpm.log* /var/log/php-fpm/*.log*)
  if [ ${#fpmlogs[@]} -gt 0 ]; then
    zgrep -hE 'exited on signal (11|6)' "${fpmlogs[@]}" < /dev/null 2>/dev/null \
      | sed -nE 's/.*\[pool ([^]]+)\].*/\1/p' | sort | uniq -c | while read -r n pool; do
          add MEDIUM "$pool" fpm_crash "$n PHP-FPM worker crashes in pool $pool (in available logs)"
        done
  fi

  # ---------- WordPress ----------
  if [ "$WP_CHECK" = 1 ]; then
    local WP PHPBIN
    WP=$(command -v wp || true)
    PHPBIN=$(ls -d /opt/plesk/php/*/bin/php 2>/dev/null | sort -V | tail -1); PHPBIN=${PHPBIN:-$(command -v php)}
    if [ -z "$WP" ] || [ -z "$PHPBIN" ]; then
      echo "WordPress checks skipped: wp-cli or PHP not found (install wp-cli or run with -W)."
    else
      find "${ROOTS[@]}" -maxdepth 4 -name wp-config.php -not -path '*/wp-content/*' 2>/dev/null | while IFS= read -r cfg; do
        local dir owner site; dir=$(dirname "$cfg"); owner=$(stat -c %U "$cfg"); site=$(site_of_path "$dir")
        [ -f "$dir/wp-includes/version.php" ] || continue
        # Plugins and themes are skipped so that no site code (possibly malicious) runs during the check.
        wpc() { timeout 90 sudo -u "$owner" "$PHPBIN" -d memory_limit=1024M "$WP" --path="$dir" --skip-plugins --skip-themes --no-color "$@"; }
        wpc user list --role=administrator --fields=user_login,user_email,user_registered --format=csv 2>/dev/null \
          | awk -F, -v s="$SINCE" 'NR > 1 && $3 >= s' | while IFS= read -r l; do add HIGH "$site" wp_admin "$dir: admin $l"; done
        local prefix shown raw
        prefix=$(wpc db prefix 2>/dev/null); shown=$(wpc user list --format=count 2>/dev/null)
        raw=$(wpc db query "SELECT COUNT(*) FROM ${prefix}users" --skip-column-names 2>/dev/null | tr -d '[:space:]')
        if [ -n "$shown" ] && [ -n "$raw" ] && [ "$raw" != "$shown" ]; then
          add HIGH "$site" wp_hidden "$dir: database has $raw users, WordPress shows $shown"
        fi
        wpc core verify-checksums 2>&1 | sed -nE "s/^Warning: File doesn't verify against checksum: (.*)$/MOD \1/p; s/^Warning: File should not exist: (.*)$/EXTRA \1/p" \
          | while read -r kind f; do
              if [ "$kind" = MOD ]; then add HIGH "$site" wp_core "$dir/$f (modified)"; continue; fi
              # Extra files: only PHP or extension-less files matter; .DS_Store, .htaccess, .orig, .zip etc. don't run.
              b=${f##*/}
              [ -s "$dir/$f" ] || continue                               # empty leftovers can't run anything
              [[ "$b" =~ \.(php[0-9]?|phtml|phar)$ || "$b" != *.* ]] && add MEDIUM "$site" wp_core "$dir/$f (not part of WordPress)"
            done
      done
    fi
  fi

  # ---------- report ----------
  local high med
  high=$(awk -F'\t' '$1 == "HIGH"' "$FINDINGS" | sort -u | wc -l); med=$(awk -F'\t' '$1 == "MEDIUM"' "$FINDINGS" | sort -u | wc -l)
  echo
  if [ "$high" -eq 0 ] && [ "$med" -eq 0 ]; then
    echo "${G}${B}OK${N}: nothing suspicious found. This is not proof the server is clean, only that these checks found nothing."
    return 0
  fi

  sort -t$'\t' -k2,2 -k1,1 -k3,3 "$FINDINGS" | awk -F'\t' '{print $2}' | uniq | while IFS= read -r site; do
    echo; echo "${B}=== $site ===${N}"
    awk -F'\t' -v s="$site" '$2 == s {print $3}' "$FINDINGS" | sort -u | while IFS= read -r cat; do
      echo "  ${B}[$cat]${N} $(explain "$cat")"
      local total; total=$(awk -F'\t' -v s="$site" -v c="$cat" '$2 == s && $3 == c' "$FINDINGS" | sort -u | wc -l)
      awk -F'\t' -v s="$site" -v c="$cat" '$2 == s && $3 == c {print $1 "\t" $4}' "$FINDINGS" | sort -u \
        | { if [ "$VERBOSE" = 1 ]; then cat; else head -15; fi; } | while IFS=$'\t' read -r sev detail; do
        [ "$sev" = HIGH ] && col=$R || col=$Y
        echo "    ${col}${sev}${N} $detail"
        case "$cat" in webshell|upload_php|hidden_php|wp_core) log_hits "${detail%% (*}" ;; esac
      done
      [ "$VERBOSE" = 0 ] && [ "$total" -gt 15 ] && echo "    ... and $((total - 15)) more (run with -v to list all)"
    done
  done

  echo
  if [ "$high" -gt 0 ]; then
    echo "${R}${B}LIKELY COMPROMISE${N}: $high high and $med medium finding(s)."
    echo "Next steps:"
    echo "  1. Do not delete anything yet. Copy suspicious files and logs somewhere safe as evidence."
    echo "  2. Check the access log lines above to see when and from where files were used."
    echo "  3. Find how the attacker got in (outdated plugin, stolen password) before cleaning, or they will be back."
    echo "  4. Clean or restore the affected sites from a backup taken before the first sign of compromise."
    echo "  5. Rotate passwords, database credentials, WordPress salts and API keys for affected sites."
    echo "  6. If personal data may have been accessed, check your GDPR obligations (72-hour notification)."
    return 2
  fi
  echo "${Y}${B}REVIEW NEEDED${N}: $med medium finding(s). These are often harmless but should be checked."
  return 1
}

main | tee "$REPORT"; rc=${PIPESTATUS[0]}
sed -i 's/\x1b\[[0-9;]*m//g' "$REPORT"
chown "$RUN_USER" "$REPORT" 2>/dev/null; chmod 600 "$REPORT"
echo; echo "Report saved to $REPORT"
exit "$rc"
