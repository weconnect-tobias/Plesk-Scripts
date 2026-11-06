#!/usr/bin/env bash
# plesk-triage - find out what is loading a Plesk server
#
# Reads the Apache and nginx logs for every domain, measures CPU per PHP-FPM pool
# and flags common problems: one IP dominating, AI agents/MCP, auth loops (401/403),
# xmlrpc/wp-login attacks, admin-ajax/wp-cron hammering, broken crontabs and more.
# Also lists vulnerability scanners, the plugins/themes they probed for, and any probe
# that found something (worth checking that plugin's version).
#
# Usage:
#   plesk-triage                     # last 60 minutes, all domains
#   plesk-triage -m 15               # last 15 minutes
#   plesk-triage -H 02/Nov/2026:14   # a specific hour (also searches rotated logs)
#   plesk-triage -d example.com      # deep dive into one domain
#   plesk-triage -n 20 -S            # top 20, skip the CPU sample
#   plesk-triage -P -H 06/Nov/2026   # scanners and probes only, for a whole day
#
# Run as a regular sudo user; the script re-runs itself with sudo when needed.
# Read-only, changes nothing. MIT license.

set -uo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

if [ "$(id -u)" -ne 0 ]; then exec sudo -- "$0" "$@"; fi
export LC_ALL=C
shopt -s nullglob

MIN=60; HOUR=""; DOM=""; TOP=10; SAMPLE=1; PROBES_ONLY=0
while getopts "m:H:d:n:SPh" o; do
  case $o in
    m) MIN=$OPTARG ;; H) HOUR=$OPTARG ;; d) DOM=$OPTARG ;; n) TOP=$OPTARG ;;
    S) SAMPLE=0 ;; P) PROBES_ONLY=1; SAMPLE=0 ;; *) usage ;;
  esac
done

VH=/var/www/vhosts/system
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PAT=$TMP/pat; HITS=$TMP/hits; TSV=$TMP/dom.tsv
h() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# ---------- time window ----------
if [ -n "$HOUR" ]; then
  echo "[$HOUR" > "$PAT"
  if [[ "$HOUR" == *:* ]]; then MINS=60; WIN="hour $HOUR"; else MINS=1440; WIN="day $HOUR"; fi
else
  for i in $(seq 0 $((MIN - 1))); do date -d "-$i min" '+[%d/%b/%Y:%H:%M'; done > "$PAT"
  MINS=$MIN; WIN="last $MIN min"
fi

# ---------- system ----------
if [ "$PROBES_ONLY" = 0 ]; then
h "System ($(hostname), $(date '+%F %T'))"
echo "Cores: $(nproc)   $(uptime | sed 's/.*load average/load average/')"
top -b -n1 | sed -n '3,4p'
echo "(Rule of thumb: load above core count = queueing. High 'sy' = kernel work, high 'wa' = disk.)"
fi

# ---------- CPU per pool ----------
if [ "$SAMPLE" = 1 ]; then
  h "CPU per PHP pool/process (5 s sample)"
  top -b -d 5 -n 2 -w 512 | awk '/^top -/{n++} n==2 && $1 ~ /^[0-9]+$/ && $9+0 > 0 {print $1, $9, $12}' > "$TMP/top"
  while read -r pid cpu cmd; do
    if [ "$cmd" = php-fpm ]; then
      pool=$(ps -o args= -p "$pid" 2>/dev/null | awk '/pool/{print $NF}')
      echo "$cpu ${pool:-php-fpm(exited)}"
    else
      echo "$cpu [$cmd]"
    fi
  done < "$TMP/top" | awk '{c[$2]+=$1} END {for (k in c) printf "%7.1f %%  %s\n", c[k], k}' | sort -rn | head -"$TOP"
  echo "(100 % = one core. Workers per pool right now:)"
  ps -eo args= | awk '/^php-fpm: pool / {c[$NF]++} END {for (k in c) printf "  %3d  %s\n", c[k], k}' | sort -rn | head -5
fi

# ---------- collect log lines ----------
for dir in "$VH"/${DOM:-*}/logs; do
  d=$(basename "$(dirname "$dir")")
  for f in access_ssl_log access_log proxy_access_ssl_log proxy_access_log; do
    if [ -n "$HOUR" ]; then files=("$dir/$f"*); else files=("$dir/$f"); fi
    for file in "${files[@]}"; do
      [ -f "$file" ] || continue
      zcat -f -- "$file" | grep -F -f "$PAT" | awk -v d="$d" '{print d" "$0}'
    done
  done
done > "$HITS"
TOTAL=$(wc -l < "$HITS")

if [ "$TOTAL" -eq 0 ]; then h "Traffic ($WIN)"; echo "No log lines in this window."; else
if [ "$PROBES_ONLY" = 0 ]; then
h "Traffic per domain ($WIN, $TOTAL requests total, Apache + nginx)"

# ---------- single pass: stats + flags per domain ----------
awk -F'"' '
{
  split($1, a, " "); d = a[1]; ip = a[2]
  split($2, r, " "); m = r[1]; u = r[2]; sub(/\?.*/, "", u)
  split($3, s, " "); st = s[1]; ua = $6; lua = tolower(ua)
  n[d]++; ipc[d SUBSEP ip]++; uac[d SUBSEP ua]++; urc[d SUBSEP m " " u]++
  if (u !~ /\.(css|js|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico|map|mp4|webm|mp3|pdf|html?|txt)$/) { dyn[d]++; dipc[d SUBSEP ip]++ }
  if (st == "401" || st == "403") e4[d]++
  if (st ~ /^5/) e5[d]++
  if (st == "429") rl[d]++
  if (u ~ /xmlrpc\.php/) xr[d]++
  if (u ~ /wp-login\.php/ && m == "POST") wl[d]++
  if (u ~ /admin-ajax\.php/) aj[d]++
  if (u ~ /wp-cron\.php/) wc[d]++
  if (u ~ /mcp/ || u ~ /\.well-known\/oauth/ || u ~ /oauth\/token/) mc[d]++
  if (lua ~ /(codex|mcp-client|claude|anthropic|openai|gpt|chatgpt|perplexity|bytespider|meta-externalagent|amazonbot|ahrefs|semrush|mj12|dotbot|petalbot|dataforseo|python-requests|python-httpx|aiohttp|go-http-client|node-fetch|axios|curl\/|wget)/) bt[d]++
}
function best(arr, d_,   k, p, bk, bv) { bv = 0
  for (k in arr) { split(k, p, SUBSEP); if (p[1] == d_ && arr[k] > bv) { bv = arr[k]; bk = p[2] } }
  BV = bv; return bk }
END {
  for (d in n) {
    tip = best(ipc, d); tipc = BV; tua = best(uac, d); tuac = BV; tur = best(urc, d); turc = BV; dip = best(dipc, d); dipcn = BV
    printf "%s\t%d\t%s\t%d\t%s\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%d\n", d, n[d], tip, tipc, tua, tuac, tur, turc,
      e4[d], e5[d], rl[d], xr[d], wl[d], aj[d], wc[d], mc[d], bt[d], dyn[d], dip, dipcn
  }
}' "$HITS" | sort -t$'\t' -k2,2nr > "$TSV"

awk -F'\t' -v top="$TOP" -v mins="$MINS" '
{
  pct = 100 / $2; rate = $2 / mins
  if (NR <= top) {
    printf "\n%-34s %7d requests  (%.1f/min)\n", $1, $2, rate
    printf "   top IP : %-45s %6d (%3.0f%%)\n", $3, $4, $4 * pct
    printf "   top UA : %-70.70s %6d (%3.0f%%)\n", $5, $6, $6 * pct
    printf "   top URL: %-70.70s %6d\n", $7, $8
  }
  f = ""
  if ($20 / mins >= 2 && $20 > 0.5 * $18) f = f sprintf("\n   ! One IP sends %d of %d dynamic requests (%s)", $20, $18, $19)
  if ($17 >= 50 && $17 * pct > 30) f = f sprintf("\n   ! Bots/agents/scripts: %d requests (%.0f%%)", $17, $17 * pct)
  if ($9 >= 50 && $9 * pct > 15)   f = f sprintf("\n   ! %d responses with 401/403, auth loop or blocked client?", $9)
  if ($16 >= 20)                    f = f sprintf("\n   ! %d MCP/OAuth requests, AI agent connected to the site?", $16)
  if ($12 >= 50)                    f = f sprintf("\n   ! %d requests to xmlrpc.php", $12)
  if ($13 >= 20)                    f = f sprintf("\n   ! %d login attempts (POST wp-login.php)", $13)
  if ($14 / mins >= 5)              f = f sprintf("\n   ! admin-ajax.php: %.1f/min", $14 / mins)
  if ($15 / mins >= 2)              f = f sprintf("\n   ! wp-cron.php: %.1f/min (DISABLE_WP_CRON + system cron?)", $15 / mins)
  if ($10 >= 10)                    f = f sprintf("\n   ! %d server errors (5xx)", $10)
  if ($11 > 0)                      f = f sprintf("\n   i %d requests stopped by rate limit (429)", $11)
  if (f != "") { if (NR <= top) print f; else w[++nw] = sprintf("%s (%d requests)%s", $1, $2, f) }
}
END { if (nw) { print "\n--- Flagged domains outside the top list"; for (i = 1; i <= nw; i++) print w[i] } }
' "$TSV"

# ---------- deep dive ----------
if [ -n "$DOM" ]; then
  h "Details for $DOM"
  echo "--- Top IPs (all requests / dynamic requests, sorted by dynamic)"
  awk -F'"' '{ split($1, a, " "); ip = a[2]; split($2, r, " "); u = r[2]; sub(/\?.*/, "", u); all[ip]++
               if (u !~ /\.(css|js|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico|map|mp4|webm|mp3|pdf|html?|txt)$/) dyn[ip]++ }
             END { for (i in all) printf "%7d %7d  %s\n", all[i], dyn[i], i }' "$HITS" | sort -k2,2nr -k1,1nr | head -"$TOP"
  echo "--- Top user agents"; awk -F'"' '{print $6}' "$HITS" | sort | uniq -c | sort -rn | head -"$TOP"
  echo "--- Top dynamic URLs (static files, HTML and PDF excluded)"
  awk -F'"' '{split($2,r," "); u=r[2]; sub(/\?.*/,"",u); split($3,s," "); print r[1], u, s[1]}' "$HITS" \
    | grep -vE '\.(css|js|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico|map|mp4|webm|mp3|pdf|html?|txt) ' | sort | uniq -c | sort -rn | head -"$TOP"
  echo "--- Status codes";  awk -F'"' '{split($3,s," "); print s[1]}' "$HITS" | sort | uniq -c | sort -rn
  echo "--- Requests per minute (last 15)"
  awk '{print substr($5,14,5)}' "$HITS" | sort | uniq -c | tail -15
fi
fi   # PROBES_ONLY

# ---------- scanners and probes ----------
h "Scanners and probes ($WIN${DOM:+, $DOM})"
awk -F'"' -v top="$TOP" -v single="${DOM:+1}" '
function isdyn(x) { return x !~ /\.(css|js|png|jpe?g|gif|svg|webp|avif|woff2?|ttf|eot|ico|map|mp4|webm|mp3|pdf|html?)$/ }
{
  split($1, a, " "); d = a[1]; ip = a[2]
  split($2, r, " "); u = r[2]; sub(/\?.*/, "", u)
  split($3, s, " "); st = s[1]; ua = $6
  if (!(ip SUBSEP d in seen)) { seen[ip SUBSEP d] = 1; sites[ip]++ }
  if (!(ip in firstua)) firstua[ip] = ua
  if (isdyn(u)) {
    dyn[ip]++
    if (st ~ /^4/) e4[ip]++
    if (st == "200" && u != "/" && u !~ /(^|\/)index\.php$/ && u !~ /^\/(wp-cron|wp-login|xmlrpc|robots)/ && u !~ /^\/wp-(admin|json|includes)\// && u !~ /\/$/ && u !~ /\/(readme|changelog|change_log|CHANGELOG|README)\.(txt|md)$/)
      ok[ip SUBSEP d " " u]++
  }
  # Version-check files: browsers never load these, scanners do.
  if (match(u, /^\/wp-content\/(plugins|themes)\/[^\/]+\/(readme|changelog|change_log|CHANGELOG|README)\.(txt|md)$/)) {
    slug = u; sub(/^\/wp-content\//, "", slug); sub(/\/[^\/]+$/, "", slug)
    probe[slug]++
    if (!(slug SUBSEP d in pseen)) { pseen[slug SUBSEP d] = 1; psites[slug]++ }
    if (st == "200" && !(slug SUBSEP d in fseen)) { fseen[slug SUBSEP d] = 1; found[slug] = found[slug] " " d }
  }
}
END {
  # Scanner: mostly 4xx on dynamic requests, or many sites with a high 4xx share.
  for (ip in dyn) {
    p = 100 * e4[ip] / dyn[ip]
    if ((dyn[ip] >= (single ? 8 : 15) && p >= 60) || (sites[ip] >= 5 && dyn[ip] >= 10 && p >= 50)) {
      sc[ip] = 1; nsc++
      printf "S\t%d\t%d\t%.0f\t%s\t%.50s\n", dyn[ip], sites[ip], p, ip, firstua[ip]
    }
  }
  for (k in ok) { split(k, q, SUBSEP); if (q[1] in sc) printf "H\t%d\t%s\t%s\n", ok[k], q[1], q[2] }
  for (sl in probe) printf "P\t%d\t%d\t%s\t%s\n", probe[sl], psites[sl], sl, found[sl]
}' "$HITS" > "$TMP/probes"

if ! grep -q '^S' "$TMP/probes"; then
  echo "No scanners found (IPs with mostly 404/400/403 on dynamic requests)."
else
  echo "--- Scanner IPs (dynamic requests, sites hit, % 4xx, first user agent)"
  awk -F'\t' '$1 == "S" {printf "%7d %4d sites %4d%%  %-40s %s\n", $2, $3, $4, $5, $6}' "$TMP/probes" | sort -rn | head -"$TOP"
  echo "--- What scanners got a 200 on (check these; '/', index.php, wp-admin, wp-json are left out)"
  if grep -q '^H' "$TMP/probes"; then
    awk -F'\t' '$1 == "H" {printf "%5d  %-40s %s\n", $2, $3, $4}' "$TMP/probes" | sort -rn | head -"$TOP"
  else echo "  nothing: every probe failed"; fi
fi
if grep -q '^P' "$TMP/probes"; then
  echo "--- Plugins/themes probed via readme/changelog (FOUND = the file exists on that site)"
  awk -F'\t' '$1 == "P" {printf "%d\t%5d %4d sites  %-45s %s\n", ($5 != "" ? 0 : 1), $2, $3, $4, ($5 != "" ? "FOUND on:" $5 : "not found")}' "$TMP/probes" \
    | sort -t$'\t' -k1,1n -k2,2nr | cut -f2- | head -"$((TOP * 2))"
  echo "(A FOUND plugin is not necessarily vulnerable, but scanners look for specific versions. Check it is up to date.)"
fi
fi

# ---------- cron ----------
h "Cron"
cpid=$(systemctl show -p MainPID --value cron 2>/dev/null || echo 0)
if [ "${cpid:-0}" -gt 0 ]; then
  read -r et ct < <(ps -o etimes=,times= -p "$cpid")
  awk -v e="$et" -v c="$ct" 'BEGIN { p = (e > 0) ? 100 * c / e : 0
    printf "cron daemon: %.2f %% CPU on average since start%s\n", p, (p > 1 ? "   ! TOO HIGH, check crontabs below" : "") }'
fi
bad=0
for f in /var/spool/cron/crontabs/*; do
  o=$(stat -c %U "$f"); b=$(basename "$f")
  if [ "$o" != "$b" ]; then
    bad=1
    if getent passwd "$b" >/dev/null; then echo "  ! $b owned by $o (wrong owner)"; else echo "  ! $b owned by $o (user no longer exists, orphaned)"; fi
  fi
done
[ "$bad" = 0 ] && echo "All crontabs have the correct owner."

# ---------- misc ----------
h "Misc"
inis=("$VH"/*/etc/php.ini)
off=""; [ ${#inis[@]} -gt 0 ] && off=$(grep -lE 'opcache\.enable\s*=\s*(0|off)' "${inis[@]}" < /dev/null 2>/dev/null | awk -F/ '{print $(NF-2)}')
if [ -n "$off" ]; then echo "OPcache disabled for:"; echo "$off" | sed 's/^/  /'; else echo "OPcache is not disabled for any domain."; fi
echo "Response times are not logged in Plesk's default log format. Measure TTFB with:"
echo "  curl -o /dev/null -s -w 'tls %{time_appconnect}  ttfb %{time_starttransfer}\n' https://DOMAIN/"
