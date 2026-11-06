# plesk-triage

Quick troubleshooting for a slow Plesk server. One command shows **which site is loading the server, who is sending the traffic, and why**.

The script is read-only. It changes nothing on the server.

```bash
plesk-triage
```

## What it checks

| Section | What it shows |
|---|---|
| **System** | Load, core count, and how CPU time is split (user, system, I/O wait) |
| **CPU per pool** | Which PHP-FPM pools (domains) are actually using CPU, sampled over 5 seconds |
| **Traffic per domain** | Request count, top IP, top user agent and top URL, from both the Apache and nginx logs |
| **Flags** | Warnings for common problems, see the table below |
| **Cron** | Whether the cron daemon uses an abnormal amount of CPU, and crontabs with the wrong owner or no matching user |
| **Scanners and probes** | IPs that mostly get 404/400/403 (vulnerability scanners), what they got a 200 on, and which plugins/themes they probed for, with FOUND when the plugin exists on a site |
| **OPcache** | Domains where OPcache is disabled |

### Flags

| Flag | What it usually means |
|---|---|
| `One IP sends X of Y dynamic requests` | A single client hammering PHP: an integration, a script or a scraper. Static files (images, CSS, JS, HTML, PDF) are not counted, so a normal visitor does not trigger it. |
| `Bots/agents/scripts` | AI crawlers, SEO bots, AI agents, curl/python scripts |
| `responses with 401/403` | A client failing to authenticate and retrying in a loop |
| `MCP/OAuth requests` | An AI agent (e.g. Codex or Claude) connected to WordPress over MCP |
| `xmlrpc.php` / `wp-login.php` | Brute-force attempts |
| `admin-ajax.php` / `wp-cron.php` | The site loading itself (Heartbeat, plugins, wp-cron on every page view) |
| `server errors (5xx)` | PHP crashes or timeouts |
| `stopped by rate limit (429)` | An existing rate limit is dropping traffic |

## Requirements

- Plesk on Linux (tested on Ubuntu 24.04)
- A user with sudo. The script doesn't need to be run as root; it re-runs itself with `sudo`.
- Standard tools already on the server: `top`, `ps`, `awk`, `grep`, `zcat`

## Installation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-triage/plesk-triage.sh \
  -o /usr/local/sbin/plesk-triage
sudo chmod 755 /usr/local/sbin/plesk-triage
```

Run the same command again to update.

## Usage

```bash
plesk-triage                     # last 60 minutes, all domains
plesk-triage -m 15               # last 15 minutes
plesk-triage -H 02/Nov/2026:14   # a specific hour, also searches rotated logs
plesk-triage -d example.com      # deep dive into one domain
plesk-triage -n 20               # show top 20 instead of top 10
plesk-triage -S                  # skip the CPU sample (faster)
plesk-triage -P -H 06/Nov/2026   # scanners and probes only, for a whole day
```

| Option | Meaning | Default |
|---|---|---|
| `-m MIN` | Time window in minutes back from now | 60 |
| `-H HOUR` | A specific hour (`02/Nov/2026:14`) or a whole day (`02/Nov/2026`) in log format | – |
| `-d DOMAIN` | Only this domain, with detailed top lists | all |
| `-n COUNT` | Number of rows in the top lists | 10 |
| `-S` | Skip the CPU sample | – |
| `-P` | Only the scanners and probes section (combine with `-H` for a day, or `-d` for one site) | – |

## Reading the output

1. **Start with CPU per pool.** It shows who is loading the server *right now*.
2. **Compare with traffic per domain.**
   - High CPU **and** lots of traffic: check the flags and the top IP/UA. The traffic explains the load.
   - High CPU but **little** traffic: the site is heavy per request (plugins, theme). Continue with `-d DOMAIN`.
3. **Check the flags.** They usually point straight at the cause.

## Scanners and probes

Bots constantly scan WordPress sites for known vulnerable plugins and for webshells left by other attackers. Most of it is harmless noise; what matters is whether anything was found. The section shows:

- **Scanner IPs:** IPs whose dynamic requests mostly got 404/400/403, with how many sites they hit.
- **What scanners got a 200 on:** paths that existed. Most are harmless pages, but a `.php` file you don't recognise here is worth a look with `plesk-compromise-check`.
- **Plugins/themes probed:** scanners check a plugin's `readme.txt` or `changelog.txt` to learn its version. Browsers never load those files, so each request is a probe. **FOUND** means the plugin exists on that site, and scanners are interested in it: make sure it is up to date.

## Good to know

- **PHP traffic is logged by Apache, not nginx.** Plesk's proxy blocks have `access_log off`, so PHP requests only show up in Apache's `access_ssl_log`. The script reads both.
- **Requests still running don't show up yet.** A log line is written when the request finishes, so long requests appear afterwards.
- **Top IPs in `-d` shows two numbers:** all requests and dynamic requests (pages that run PHP). A normal visitor has many requests but few dynamic ones, since one page view loads dozens of images and scripts. A bot or script usually has almost only dynamic requests. The list is sorted by dynamic requests.
- **Requests stopped in nginx** (e.g. by a rate limit in a block with `access_log off`) are not logged at all.
- **Response times are not logged** in Plesk's default format. Measure them separately:
  ```bash
  curl -o /dev/null -s -w 'tls %{time_appconnect}  ttfb %{time_starttransfer}\n' https://example.com/
  ```
- **Don't use `ps` to measure CPU per worker.** `ps` reports an average over the process lifetime, so a worker that is a few seconds old can look like it's using 800 %. The script samples with `top` over an interval instead.

## License

MIT
