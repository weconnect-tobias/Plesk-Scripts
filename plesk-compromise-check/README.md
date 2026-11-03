# plesk-compromise-check

Looks for signs that a Plesk server, or one of the sites on it, has been compromised. Run it when you suspect a break-in, after a security advisory, or regularly as a health check.

The script is read-only. It changes, moves or deletes nothing.

```bash
plesk-compromise-check
```

## What it checks

| Check | What it looks for |
|---|---|
| **Webshells** | PHP files changed in the scan window with typical backdoor code: `eval(base64_decode(...))`, request data run as code or commands, known webshell names |
| **PHP in upload folders** | PHP files in `wp-content/uploads`, where only media belongs (WordPress' tiny `index.php` files are ignored) |
| **Hidden PHP files** | PHP files whose name starts with a dot, e.g. `.logs.php` |
| **Prepend backdoors** | `auto_prepend_file` / `auto_append_file` in php.ini, FPM pools, `.user.ini` and `.htaccess` (Wordfence's WAF is excluded) |
| **Shells from the web server** | `sh`, `bash`, `curl`, `wget`, `nc`, `perl`, `python` etc. started by PHP, Apache or nginx (PHP's `mail()` calling sendmail is ignored) |
| **Malware in temp folders** | Processes running from `/tmp`, `/var/tmp`, `/dev/shm` or a deleted file, and new binaries or scripts in those folders |
| **Network** | Site users listening on ports, and connections to ports typical for reverse shells, IRC bots and mining pools |
| **Cron and systemd** | Jobs that pipe downloads into a shell, decode base64 or run from temp folders |
| **Accounts** | Extra UID 0 accounts, `authorized_keys` changed in the scan window, web server users with a login shell |
| **Rootkit indicators** | `/etc/ld.so.preload`, and system binaries that differ from their package checksum |
| **PHP-FPM crashes** | Workers dying with SIGSEGV/SIGABRT, grouped per pool |
| **WordPress** | Administrators created in the scan window, users hidden from WordPress, and modified or extra core files (via `wp core verify-checksums`) |

Every finding is mapped to its site. For suspicious files, the script also looks in that site's access logs and shows how many requests the file got, how many were POSTs, when it was first and last used, and from which IPs.

## Requirements

- Plesk on Linux (tested on Ubuntu 24.04)
- A user with sudo. The script doesn't need to be run as root; it re-runs itself with `sudo`.
- For the WordPress checks: `wp-cli` available as `wp`. Without it those checks are skipped. Plugins and themes are never loaded during the check, so no site code runs.

## Installation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-compromise-check/plesk-compromise-check.sh \
  -o /usr/local/sbin/plesk-compromise-check
sudo chmod 755 /usr/local/sbin/plesk-compromise-check
```

## Usage

```bash
plesk-compromise-check                   # look back 30 days, all sites
plesk-compromise-check -s 2026-10-01     # look back to a given date
plesk-compromise-check -d example.com    # only this subscription
plesk-compromise-check -f                # grep every PHP file, not only recently changed ones (slow)
plesk-compromise-check -W                # skip the WordPress checks (faster)
plesk-compromise-check -v                # list every finding (default: 15 per category)
```

| Option | Meaning | Default |
|---|---|---|
| `-s DATE` | How far back to look for changed files, keys and admins | 30 days ago |
| `-d DOMAIN` | Only scan this subscription | all |
| `-f` | Full scan of all PHP files, regardless of change date | off |
| `-W` | Skip the WordPress checks | off |
| `-v` | List every finding instead of the first 15 per category | off |

## Result

| Result | Exit code | Meaning |
|---|---|---|
| **OK** | 0 | Nothing suspicious found |
| **REVIEW NEEDED** | 1 | Medium findings only. Often harmless, but check them. |
| **LIKELY COMPROMISE** | 2 | At least one high finding. The script prints next steps. |

Each finding comes with a short explanation of what it means. A copy of the report is saved in the home folder of the user who ran the script, e.g. `/home/ubuntu/plesk-compromise-check-<host>-<time>.txt`.

## Known-good files

To keep the report readable, some common, legitimate files are not reported on their own. They are still grepped for backdoor code, and reported as a webshell if they contain any:

- PHP that plugins keep in `wp-content/uploads`: icon font maps (`smile_fonts/*/charmap.php`), MailPoet, WPForms, Divi and Beaver Builder caches, Avada page templates, All-In-One Security firewall rules and PDF font metrics (`uploads/fonts/*.php`)
- Hidden PHP files inside `vendor/` folders (e.g. `.phpstorm.meta.php`) and macOS resource forks (`._*`)
- `auto_prepend_file` pointing at a known WordPress firewall: Wordfence, NinjaFirewall, Admin Tools, All-In-One Security
- Extra files in a WordPress install that can't run as PHP (`.DS_Store`, `.htaccess`, `.orig`, `.zip`) or are empty

## Good to know

- **"Nothing found" is not proof the server is clean.** The checks look for common traces of an attack. A careful attacker can avoid all of them.
- **Attackers can fake modification times.** By default only files changed in the scan window are grepped for webshell code. Use `-f` to check every PHP file when you really suspect a break-in.
- **False positives happen.** Some plugins use code that looks like a backdoor. Check the file before acting, and use the access log lines to see whether it has been called from outside.
- **Don't delete anything straight away.** Keep copies of suspicious files and logs as evidence, and find out how the attacker got in before you clean up.

## License

MIT
