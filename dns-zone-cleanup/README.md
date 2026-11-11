# dns-zone-cleanup

Removes stale secondary (slave) zones from BIND nameservers. Install it once on every secondary nameserver and forget about it.

It works with any primary (Plesk, cPanel, another BIND server, ...), on new and old BIND versions, and with zones added by `rndc addzone` as well as zones written into `named.conf`.

```bash
wget -qO- https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/dns-zone-cleanup/dns-zone-cleanup.sh | sudo bash -s install
dns-zone-cleanup dryrun
```

> **This script changes things.** Without `dryrun` it removes zones from BIND, and by default it also deletes their zone files (choose `keep` or `archive` instead). Always run with `dryrun` first. A removed zone comes back if its primary pushes it again (e.g. when DNS is switched back on for the domain).

*This script used to be called `plesk-slave-zone-cleanup`. Existing installations move over by themselves, see [Moving from plesk-slave-zone-cleanup](#moving-from-plesk-slave-zone-cleanup).*

## What it finds

A secondary zone is stale when:

| Source | How it is found | What it means |
|---|---|---|
| **RETRY** | Log: `refresh: retry limit for primary <IP>#53 exceeded` | The primary does not answer for the zone at all |
| **DISABLED** | Log: `refresh: unexpected rcode (REFUSED)` / `(NOTAUTH)`, or `refresh: non-authoritative answer` | The primary answers but no longer has the zone, e.g. DNS switched off for the domain |
| **MOVED** | Delegation check: the domain's NS records at the TLD point to other nameservers only | The domain has moved to another DNS host. The old primary may still serve the zone, with outdated data. |
| **UNREG** | Delegation check: the TLD says the domain does not exist | The domain has expired or been deleted |

The log is named's log: `/var/log/syslog`, `/var/log/messages` or the systemd journal, plus the newest rotated file. Both `primary` (BIND 9.18+) and `master` (older BIND) are matched. By default every primary is looked at; give an IP address to only look at one.

### Delegation check

Once a day the script asks the TLD (`.se`, `.com`, ...) which nameservers each secondary zone's domain is delegated to, and checks whether one of them is this server.

- A zone is only removed after it has been **MOVED** or **UNREG** for **7 days in a row** (`--delegation-days`). Moves, registrar changes and short outages don't cause anything.
- The day a zone starts to look moved, it shows up in the mail report under *No longer delegated to this server*, with the date it will be removed.
- If it is delegated here again before then, the counter starts over.
- Only registered domains are checked (`example.se`, `example.co.uk`). Sub-zones (`internal.example.se`), reverse zones (`*.arpa`) and private names (`.local`, `.lan`) are never touched by this check.
- **Safety check:** if more than half of the zones look "not delegated here", the script assumes it got its own addresses wrong. It removes nothing and reports an error instead.

The script finds its own addresses from the network interfaces and from what its host name resolves to. Behind NAT, or if the nameserver answers on other addresses, give them:

```bash
sudo dns-zone-cleanup install --own-ips "198.51.100.53 2001:db8::53"
```

See the result without changing anything:

```bash
dns-zone-cleanup delegation              # all secondary zones
dns-zone-cleanup delegation example.se   # one zone
```

```
ZONE                                     STATUS    SINCE      NAMESERVERS AT THE TLD
----                                     ------    -----      ----------------------
example.se                               DELEGATED -          ns1.example.net ns2.example.net
moved.se                                 NOTHERE   2026-11-11 ns1.other-dns.com ns2.other-dns.com
gone.se                                  UNREG     2026-11-11 -
internal.example.se                      SUBZONE   -          -
```

Hidden secondaries are servers that are deliberately not listed in the NS records. On such a server, turn the check off or only report:

```bash
sudo dns-zone-cleanup install --delegation report   # list in the report, never remove
sudo dns-zone-cleanup install --delegation off
```

### On a primary (master) server

Installed on a primary, for example a Plesk server, the script changes nothing: there are no secondary zones to clean up, and zones this server is primary for are never touched. It says so:

```
This server is primary for 412 zone(s) and has no secondary zones.
Secondary zones are what dns-zone-cleanup cleans up; primary zones are only checked and reported, never changed.
```

It does run a daily, **report-only** check of the primary zones. That catches the old-server case: a domain that has moved to another DNS host, or has expired, while this server still serves its zone. A primary is usually not in the domain's NS records itself, so here the TLD's NS records are compared with the NS records **in the zone**:

| Status | Meaning |
|---|---|
| `OURS` | The TLD delegates to the zone's own nameservers, or to other names with the same addresses |
| `MOVED` | The TLD delegates to other nameservers only. This server serves a stale copy. |
| `UNREG` | The domain no longer exists at the TLD |

Each stale zone is reported twice in the mail report: the day it is found, and again after `--delegation-days` days if it stays like that. The report includes the command to switch it off; on Plesk that is `plesk bin dns --off example.se`. `dns-zone-cleanup delegation` shows the table for all primary zones.

Zones that should never be touched by any check:

```bash
sudo dns-zone-cleanup install --exclude "example.se *.internal.example.se"
```

## Safety checks

For RETRY and DISABLED zones the log alone is not enough: log lines can be old, and the same domain can exist on more than one primary. So before anything is removed, the script reads the zone's **current** primaries from its config and checks **every** one of them live with `dig +norec SOA`:

| Primary answers | Action |
|---|---|
| At least one primary answers authoritatively (`aa` flag) | Skip: the zone is active somewhere |
| All primaries answer `REFUSED`, `NOTAUTH`, `NXDOMAIN`, or without the `aa` flag | Remove |
| No primary answers (timeout) | Remove RETRY zones (the original behaviour); skip DISABLED and named zones, since a sudden timeout suggests a network problem (`force` overrides for named zones) |
| Some say gone, others time out (`MIXED`) | Skip: can't be sure |
| Anything else (e.g. `SERVFAIL`) | Skip: the zone exists on a primary but is broken there, check manually |

When you give an IP address, a zone whose primaries no longer include that IP is skipped. That happens when the domain has been moved to another primary and the zone was re-added from there; the old log lines then refer to the wrong server.

### The same domain on two primaries

Say `example.com` is active on primary A and switched off (or left over) on server B:

- **The secondary's zone points to A:** A answers authoritatively, so the zone is kept, whether you run the script for B's IP or name the zone.
- **The secondary's zone points to B:** B says it doesn't have the zone, so the zone is removed. That is correct, since it was stale, but A's zone is not on the secondary until A pushes it again. On Plesk: use *Resync* in Slave DNS Manager on server A, or switch DNS off and on for the domain there.
- **The zone lists both A and B as primaries:** A answers, so the zone is kept.

Zones that no longer exist on the secondary are skipped, so the script can be run again safely.

If 10 or more zones of the same primary would be removed only because it times out, the script asks you to type `YES` first. Without a terminal it holds those zones back, removes the rest and exits with code 2. The primary may simply be down, and you don't want to wipe all its zones because of that. Other primaries are not affected.

In auto mode, zones whose primary can't be read from their config are skipped. Zones this server is the primary for (`type master`/`primary`) are never touched.

## What happens to a stale zone

How the zone is removed depends on how it was added:

| The zone is... | What the script does |
|---|---|
| Added with `rndc addzone` (e.g. Plesk Slave DNS Manager) | `rndc delzone` |
| Defined in `named.conf` or an included file (older setups, own sync scripts) | Comments out the zone statement with `# `, checks the config, reloads BIND (see below) |
| Something that can't be done safely | Leaves it alone and reports it as **remove by hand**, in the output and in the mail report |

What happens to the **zone file** is your choice (`install --delete-files`, `--keep-files` or `--archive-files`, or `delete`, `keep` or `archive` on the command line):

| Setting | Zone file and `.jnl` journal |
|---|---|
| `delete` (default) | Deleted |
| `keep` | Left where they are |
| `archive` | Moved to `/var/backups/dns-zone-cleanup/<time>/zones/` |

### Zones in named.conf

On older nameservers the slave zones are often written straight into `named.conf` or a file it includes. Removing them from BIND isn't enough there: they come back at the next restart. So the script comments the zone statement out:

```
# [dns-zone-cleanup 2026-11-11 13:35] zone example.com removed: no primary serves it. To restore, remove the "# " in front of the lines below.
# zone "example.com" {
#     type slave;
#     file "slaves/example.com";
#     masters { 192.0.2.10; };
# };
```

To keep this safe:

1. The file is copied to `/var/backups/dns-zone-cleanup/<time>/config/` first
2. Only zone statements that have their own lines are touched. If a zone shares a line with other config (`zone "a" {...}; zone "b" {...};`), it is reported as remove by hand.
3. After the change, `named-checkconf` must pass. If it doesn't, **every** changed file is put back exactly as it was and the zones are reported as failed.
4. BIND is reloaded (`rndc reconfig`, or `systemctl reload named`/`bind9` without rndc) and the script checks that the zones are gone. The zone files are only touched after that.

Things to know:

- **Generated config is overwritten.** If the file is written by a tool (an old Slave DNS Manager, a sync script, Ansible), that tool will put the zone back. Fix it at the source, or use `--conf-zones skip`.
- **Comments are not removed.** Old commented-out zones stay in the file. That is on purpose, so you can see what was removed and undo it.
- **Don't want the script to edit config files at all?** `sudo dns-zone-cleanup install --conf-zones skip`. Such zones are then only reported as remove by hand.

### Old nameservers

The script adapts to what the server has:

| Missing | What happens instead |
|---|---|
| `rndc showzone` (BIND < 9.11) | The zone's primaries and file are read from `named.conf`, its includes and the `.nzf` file of `rndc addzone` |
| `rndc zonestatus` (BIND < 9.10) | `dig @127.0.0.1` checks whether BIND still serves the zone |
| `rndc delzone -clean` | `rndc delzone`, then the script handles the files itself |
| A working `rndc` | Only zones in config files can be removed; BIND is reloaded via systemd/init. Zones added with `rndc addzone` are reported as remove by hand. |
| `primaries` (BIND < 9.18 uses `masters`) | Both are understood, as are named lists (`masters plesk { 192.0.2.10; };`) |

Large logs are no problem: the log is searched as a stream and only the refresh errors are kept, so memory use stays at a few MB however big `/var/log/syslog` is.

BIND in a chroot (RHEL `named-chroot`, Plesk's `/var/named/run-root`) is found automatically; paths in its config are read inside the chroot. If `named.conf` is somewhere else, set `NAMED_CONF=/path/to/named.conf`.

## Requirements

- A BIND 9 secondary. Plesk Slave DNS Manager setups (`rndc addzone`) and older setups with zones in `named.conf` both work.
- Bash 4+, and systemd or cron
- `dig` and `logger`. `install` adds them if they are missing.
- A user with sudo. You don't need to log in as root; the script uses `sudo` when it needs to. Running as root also works.

Tested on Ubuntu. `install` also handles Debian, RHEL/AlmaLinux/Rocky/CentOS/Fedora (`dnf`/`yum`), openSUSE (`zypper`), Arch (`pacman`) and Alpine (`apk`, BusyBox cron).

## Installation

One command installs the script, any missing packages and an hourly schedule:

```bash
wget -qO- https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/dns-zone-cleanup/dns-zone-cleanup.sh | sudo bash -s install
```

If `wget` is missing, use `curl -fsSL` instead of `wget -qO-`.

`install` does the following:

1. Installs `dig` (`bind9-dnsutils`, `dnsutils`, `bind-utils`, `bind` or `bind-tools`, depending on the distro) and `logger` if they are missing
2. Puts the script in `/usr/local/sbin/dns-zone-cleanup`, writing it atomically so you never get a half-written file
3. Checks that `rndc` can talk to BIND, that `allow-new-zones` is on, and where named logs: `/var/log/syslog`, `/var/log/messages` or the systemd journal
4. Schedules the cleanup: a systemd timer where systemd is available, otherwise `/etc/cron.d`, or `/etc/crontabs/root` on Alpine
5. Saves the settings in `/etc/dns-zone-cleanup.conf` (readable by root only)

Then check what the first run would do:

```bash
dns-zone-cleanup dryrun
```

### Install options

```bash
sudo dns-zone-cleanup install --interval 30min    # how often (5min-24h, default 1h)
sudo dns-zone-cleanup install --delete-files      # delete zone files of removed zones (default)
sudo dns-zone-cleanup install --keep-files        # keep them
sudo dns-zone-cleanup install --archive-files     # move them to /var/backups/dns-zone-cleanup/
sudo dns-zone-cleanup install --conf-zones skip   # never edit named.conf, only report such zones
sudo dns-zone-cleanup install --conf-zones comment  # comment them out (default)
sudo dns-zone-cleanup install --delegation on       # delegation check removes MOVED/UNREG zones (default)
sudo dns-zone-cleanup install --delegation report   # only report them
sudo dns-zone-cleanup install --delegation-days 14  # wait longer before removing
sudo dns-zone-cleanup install --own-ips "198.51.100.53"  # this server's public addresses (NAT)
sudo dns-zone-cleanup install --exclude "example.se *.lab.example.se"  # never touch these
sudo dns-zone-cleanup install --auto-update       # update itself daily at ~04:00
sudo dns-zone-cleanup install --ref main          # follow VERSION on the main branch (default)
sudo dns-zone-cleanup install --ref latest        # follow GitHub releases instead
sudo dns-zone-cleanup install --ref v1.0.0        # stay on one release
```

Run `install` again at any time to change a setting. Settings you don't mention are kept.

### Daily mail report

Get a mail every morning when something has happened: zones removed, removals that failed, stale zones that need to be removed by hand, zones held back because a primary seems down, or the script updated. Nothing happened means no mail.

With an SMTP server (no local mail server needed):

```bash
sudo dns-zone-cleanup install --report-email ops@example.com \
    --smtp smtps://smtp.example.com:465 --smtp-user noreply@example.com
```

The script asks for the SMTP password. You can also give it as `SMTP_PASSWORD=... ` in front of the command when you script the install. The password is stored in `/etc/dns-zone-cleanup.conf`, which only root can read, and it is passed to `curl` through stdin so it never shows up in `ps`. Use `smtps://host:465` for TLS or `smtp://host:587` for STARTTLS. TLS is always required.

If the server already has a working local mail server (`sendmail`, e.g. Postfix), leave out `--smtp`:

```bash
sudo dns-zone-cleanup install --report-email ops@example.com
```

Then check that mail gets through:

```bash
sudo dns-zone-cleanup report --test     # send a test mail now
sudo dns-zone-cleanup report --print    # show the next report without sending it
```

| Option | Meaning |
|---|---|
| `--report-email a@example.com,b@example.com` | Where to send the report (comma separated) |
| `--report-time 07:00` | When to send it (default 07:00) |
| `--report-always` | Send a mail every day, also when nothing happened. A missing mail then tells you something is wrong. |
| `--report-changes` | Back to only mailing when something happened (default) |
| `--mail-from addr` | Sender. Default: the SMTP login if it is an address, otherwise `dns-zone-cleanup@<host>` |
| `--no-report` / `--no-smtp` | Turn the report or the SMTP server off |

Example report:

```
Subject: [ns3.example.com] dns-zone-cleanup: 2 removed, held back

Report from dns-zone-cleanup 1.0.0 on ns3.example.com
Period: 2026-11-11 07:00:02 - 2026-11-12 07:00:01

Held back - a primary did not answer (is it down?):
  2026-11-11 21:00:03 - 2026-11-11 23:00:02  11 zones of primary 192.0.2.30 held back: primary does not answer, may be down  (3 times)

Removed zones:
  2026-11-11 14:00:05  example.com, zone files deleted (DISABLED, primary 192.0.2.10)
  2026-11-11 14:00:05  example.net, zone files deleted (DISABLED, primary 192.0.2.10)
```

Every event is also written to `/var/log/dns-zone-cleanup.log`. `status` shows the latest events. If a report can't be sent, its events are kept and included in the next report.

### Updates

The script has its version at the top: `VERSION="1.0.0"`. `check` and `update` download the script from GitHub, read its `VERSION` and compare it with the installed one. Only a higher version is installed:

```bash
dns-zone-cleanup check          # installed version vs. GitHub (exit code 10 = update available)
sudo dns-zone-cleanup update    # install it if it is newer
```

To roll out a change: raise `VERSION` in the script and push to `main`. Servers with `--auto-update` pick it up the next night (around 04:00), and the others when you run `update`. A push that doesn't raise `VERSION` is not rolled out, so work in progress stays on GitHub.

Before replacing anything, `update` checks that the downloaded file really is this script (shebang, name, `bash -n`). A failed download or a broken file leaves the current version in place. It never downgrades unless you add `--force`.

GitHub releases work too, if you want them (see [Releases](../README.md#releases)):

| `--ref` | Looks at |
|---|---|
| `main` (default) | `VERSION` in the script on the main branch |
| `latest` | The newest published release of this script (tag `dns-zone-cleanup-vX.Y.Z`). Releases of other scripts are ignored. |
| `v1.0.0` | Only that release. Nothing changes until you pick another version with `install --ref`. |

### Status and removal

```bash
dns-zone-cleanup status          # settings, next run, last runs
dns-zone-cleanup version
dns-zone-cleanup check
sudo dns-zone-cleanup uninstall  # removes schedule, settings and script; BIND is untouched
```

## Usage

```bash
# Auto mode: find broken zones from every primary in the log
dns-zone-cleanup dryrun                   # show what would be removed
dns-zone-cleanup                          # remove zones (asks what to do with zone files)
dns-zone-cleanup delete                   # remove zones and delete zone files
dns-zone-cleanup keep                     # remove zones, keep zone files
dns-zone-cleanup archive                  # remove zones, move zone files to the backup folder
dns-zone-cleanup dryrun verbose           # also list log zones that are already gone
dns-zone-cleanup delegation                # show the delegation check, change nothing

# Only one primary
dns-zone-cleanup 192.0.2.10 dryrun
dns-zone-cleanup 192.0.2.10 delete

# Zone mode: remove specific zones
dns-zone-cleanup example.com dryrun
dns-zone-cleanup example.com example.net delete
dns-zone-cleanup example.com delete force # remove even if the primary still serves it
```

| Option | Meaning |
|---|---|
| `delete` / `keep` / `archive` | What to do with the zone file (`yes` = delete, `no` = keep also work). If left out, the script asks; without a terminal or with `dryrun` it uses the installed setting (default: delete). |
| `dryrun` | Only show what would be done, and how (`rndc delzone`, which lines are commented out where, what happens to the file). |
| `verbose` | Also list zones from the log that are already gone. By default they are only counted. |
| `force` | Zone mode only: remove the zone even if the primary still answers for it, e.g. when the domain is moving to another DNS. |

Options can be given in any order. You can't mix an IP address and zone names in the same run.

In zone mode the primary is read from the zone's config. If it can't be read, the zone is only removed with `force`. Zones this server is the primary for (`type master`/`primary`) are never touched, not even with `force`.

After each removal the script checks that the zone is really gone from BIND. With `delete` it also checks that the zone file and its `.jnl` journal are gone, and deletes any file BIND left behind.

To read a different log file:

```bash
LOGFILE=/var/log/named/named.log dns-zone-cleanup dryrun
```

## Running automatically

`install` sets this up for you (see above). You can also run the script from your own cron, Ansible, or over ssh. It never asks anything when there is no terminal:

- If `delete`/`keep`/`archive` is not given, the installed setting is used (default: delete).
- The "primary may be down" check (10+ zones of one primary that only time out) holds those zones back instead of asking, and the script exits with code 2.
- Only one run at a time. A second run started while one is going exits immediately.
- Every removal and failure is logged to `/var/log/dns-zone-cleanup.log` and to syslog with the tag `dns-zone-cleanup` (`journalctl -t dns-zone-cleanup`)

To remove a zone on every secondary from your workstation:

```bash
for ns in ns1.example.com ns2.example.com ns3.example.com; do
  echo "== $ns"; ssh "$ns" dns-zone-cleanup example.com delete
done
```

Exit codes: 0 = OK or nothing to do, 1 = error or a removal failed, 2 = zones held back by the safety check (see the log).

## Reading the output

```
ZONE                                     SOURCE    PRIMARY    ACTION
----                                     ------    -------    ------
example.com                              DISABLED  GONE       REMOVE
example.net                              DISABLED  ACTIVE     skip (active on primary again)
example.org                              RETRY     TIMEOUT    REMOVE
```

- **SOURCE**: why the zone was picked: `RETRY` or `DISABLED` from the log, or `MANUAL` when you named it.
- **PRIMARY**: the live answer from the primary: `ACTIVE`, `GONE`, `TIMEOUT`, `UNKNOWN` (primary not found) or `OTHER(<rcode>)`.
- **ACTION**: what the script does with the zone.

## Good to know

- **No `rndc reload` needed** for zones added with `rndc addzone`. `rndc delzone` takes effect immediately.
- **Run it on every secondary.** Each secondary has its own copy of the zones.
- **Check the log format first.** If your secondaries log disabled zones with other wording, they won't be found in log mode:
  `sudo grep -E "refresh: (unexpected rcode|non-authoritative)" /var/log/syslog | head`

## Moving from plesk-slave-zone-cleanup

This script used to be called `plesk-slave-zone-cleanup`. Servers that have it installed move over by themselves:

1. At its next `update` (nightly with `--auto-update`, or `sudo plesk-slave-zone-cleanup update`), the old script finds a small replacement at its old place in the repo and installs it
2. That replacement downloads `dns-zone-cleanup` and runs `install`
3. `install` takes over the settings (incl. mail report and SMTP), the event log and the report state, removes the old timers or cron jobs and installs its own
4. `plesk-slave-zone-cleanup` becomes a link to `dns-zone-cleanup`, so old commands and scripts keep working

The delegation check is turned on by the move. Run `dns-zone-cleanup delegation` afterwards to see what it finds. Old backups stay in `/var/backups/plesk-slave-zone-cleanup`.

## License

MIT
