# plesk-slave-zone-cleanup

Removes slave zones from a BIND secondary nameserver when the Plesk primary no longer serves them.

Run it on the **secondary nameservers** (the BIND servers that Plesk's Slave DNS Manager pushes zones to), not on the Plesk server itself.

When a domain is deleted in Plesk, or DNS is switched off for it, the zone often stays on the secondaries. BIND keeps trying to refresh it and fills the log with errors, and the secondary keeps answering for a zone that no longer exists on the primary. This script finds those zones and removes them with `rndc delzone`.

```bash
plesk-slave-zone-cleanup dryrun
```

> **This script changes things.** Without `dryrun` it removes zones from BIND, and with `yes` it also deletes the zone files. Always run with `dryrun` first. A removed zone comes back if Plesk pushes it again (e.g. when DNS is switched back on for the domain).

## What it finds

The script reads named's log (`/var/log/syslog`, `/var/log/messages` or the systemd journal, plus the newest rotated file) and looks for two kinds of zones. By default it looks at every primary; give an IP address to only look at one:

| Source | Log message | What it means |
|---|---|---|
| **RETRY** | `refresh: retry limit for primary <IP>#53 exceeded` | The primary does not answer for the zone at all. |
| **DISABLED** | `refresh: unexpected rcode (REFUSED)` / `(NOTAUTH)`, or `refresh: non-authoritative answer` | The primary answers but no longer has the zone, e.g. DNS switched off for the domain in Plesk. |

Both `primary` (BIND 9.18+) and `master` (older BIND) are matched.

## Safety checks

Log lines can be old, and the same domain can exist on more than one Plesk server. So before anything is removed, the script reads the zone's **current** primaries from `rndc showzone` and checks **every** one of them live with `dig +norec SOA`:

| Primary answers | Action |
|---|---|
| At least one primary answers authoritatively (`aa` flag) | Skip: the zone is active somewhere |
| All primaries answer `REFUSED`, `NOTAUTH`, `NXDOMAIN`, or without the `aa` flag | Remove |
| No primary answers (timeout) | Remove RETRY zones (the original behaviour); skip DISABLED and named zones, since a sudden timeout suggests a network problem (`force` overrides for named zones) |
| Some say gone, others time out (`MIXED`) | Skip: can't be sure |
| Anything else (e.g. `SERVFAIL`) | Skip: the zone exists on a primary but is broken there, check manually |

When you give an IP address, a zone whose primaries no longer include that IP is skipped. That happens when the domain has been moved to another Plesk server and the zone was re-added from there; the old log lines then refer to the wrong server.

### The same domain on two Plesk servers

Say `example.com` is active on Plesk server A and switched off (or left over) on server B:

- **The secondary's zone points to A:** A answers authoritatively, so the zone is kept, whether you run the script for B's IP or name the zone.
- **The secondary's zone points to B:** B says it doesn't have the zone, so the zone is removed. That is correct, since it was stale, but A's zone is not on the secondary until A pushes it again. Use *Resync* in Slave DNS Manager on server A, or switch DNS off and on for the domain there.
- **The zone lists both A and B as primaries:** A answers, so the zone is kept.

Zones that no longer exist on the secondary are skipped, so the script can be run again safely.

If 10 or more zones of the same primary would be removed only because it times out, the script asks you to type `YES` first. Without a terminal it holds those zones back, removes the rest and exits with code 2. The primary may simply be down, and you don't want to wipe all its zones because of that. Other primaries are not affected.

In auto mode, zones whose primary can't be read from `rndc showzone` are skipped.

## Requirements

- A BIND 9 secondary with working `rndc` and `allow-new-zones yes` (as set up by Plesk Slave DNS Manager)
- Bash 4+, and systemd or cron
- `dig` and `logger`. `install` adds them if they are missing.
- A user with sudo. You don't need to log in as root; the script uses `sudo` when it needs to. Running as root also works.

Tested on Ubuntu. `install` also handles Debian, RHEL/AlmaLinux/Rocky/CentOS/Fedora (`dnf`/`yum`), openSUSE (`zypper`), Arch (`pacman`) and Alpine (`apk`, BusyBox cron).

## Installation

One command installs the script, any missing packages and an hourly schedule:

```bash
wget -qO- https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-slave-zone-cleanup/plesk-slave-zone-cleanup.sh | sudo bash -s install
```

If `wget` is missing, use `curl -fsSL` instead of `wget -qO-`.

`install` does the following:

1. Installs `dig` (`bind9-dnsutils`, `dnsutils`, `bind-utils`, `bind` or `bind-tools`, depending on the distro) and `logger` if they are missing
2. Puts the script in `/usr/local/sbin/plesk-slave-zone-cleanup`, writing it atomically so you never get a half-written file
3. Checks that `rndc` can talk to BIND, that `allow-new-zones` is on, and where named logs: `/var/log/syslog`, `/var/log/messages` or the systemd journal
4. Schedules the cleanup: a systemd timer where systemd is available, otherwise `/etc/cron.d`, or `/etc/crontabs/root` on Alpine
5. Saves the settings in `/etc/plesk-slave-zone-cleanup.conf` (readable by root only)

Then check what the first run would do:

```bash
plesk-slave-zone-cleanup dryrun
```

### Install options

```bash
sudo plesk-slave-zone-cleanup install --interval 30min    # how often (5min-24h, default 1h)
sudo plesk-slave-zone-cleanup install --keep-files        # remove zones but keep zone files
sudo plesk-slave-zone-cleanup install --delete-files      # remove zones and zone files (default)
sudo plesk-slave-zone-cleanup install --auto-update       # update itself daily at ~04:00
sudo plesk-slave-zone-cleanup install --ref v1.0.0        # branch or tag to install and update from
```

Run `install` again at any time to change a setting. Settings you don't mention are kept.

### Daily mail report

Get a mail every morning when something has happened: zones removed, removals that failed, zones held back because a primary seems down, or the script updated. Nothing happened means no mail.

With an SMTP server (no local mail server needed):

```bash
sudo plesk-slave-zone-cleanup install --report-email ops@example.com \
    --smtp smtps://smtp.example.com:465 --smtp-user noreply@example.com
```

The script asks for the SMTP password. You can also give it as `SMTP_PASSWORD=... ` in front of the command when you script the install. The password is stored in `/etc/plesk-slave-zone-cleanup.conf`, which only root can read, and it is passed to `curl` through stdin so it never shows up in `ps`. Use `smtps://host:465` for TLS or `smtp://host:587` for STARTTLS. TLS is always required.

If the server already has a working local mail server (`sendmail`, e.g. Postfix), leave out `--smtp`:

```bash
sudo plesk-slave-zone-cleanup install --report-email ops@example.com
```

Then check that mail gets through:

```bash
sudo plesk-slave-zone-cleanup report --test     # send a test mail now
sudo plesk-slave-zone-cleanup report --print    # show the next report without sending it
```

| Option | Meaning |
|---|---|
| `--report-email a@example.com,b@example.com` | Where to send the report (comma separated) |
| `--report-time 07:00` | When to send it (default 07:00) |
| `--report-always` | Send a mail every day, also when nothing happened. A missing mail then tells you something is wrong. |
| `--report-changes` | Back to only mailing when something happened (default) |
| `--mail-from addr` | Sender. Default: the SMTP login if it is an address, otherwise `plesk-slave-zone-cleanup@<host>` |
| `--no-report` / `--no-smtp` | Turn the report or the SMTP server off |

Example report:

```
Subject: [ns3.example.com] plesk-slave-zone-cleanup: 2 removed, held back

Report from plesk-slave-zone-cleanup 1.0.0 on ns3.example.com
Period: 2026-11-11 07:00:02 - 2026-11-12 07:00:01

Held back - a primary did not answer (is it down?):
  2026-11-11 21:00:03 - 2026-11-11 23:00:02  11 zones of primary 192.0.2.30 held back: primary does not answer, may be down  (3 times)

Removed zones:
  2026-11-11 14:00:05  example.com, zone files deleted (DISABLED, primary 192.0.2.10)
  2026-11-11 14:00:05  example.net, zone files deleted (DISABLED, primary 192.0.2.10)
```

Every event is also written to `/var/log/plesk-slave-zone-cleanup.log`. `status` shows the latest events. If a report can't be sent, its events are kept and included in the next report.

### Updates

```bash
sudo plesk-slave-zone-cleanup update
```

This downloads the script from the configured `--ref` and checks that it really is this script (shebang, name, `bash -n`). Only then does it replace the installed copy. A failed download or a broken file leaves the current version in place.

With `--auto-update` this runs every day. **Think before turning it on:** everything that lands in the branch then runs as root on all your nameservers within a day, and this script deletes zones. The safer setup is to tag releases and install from a tag (`--ref v1.0.0`). Your servers then only change when you run `install --ref <new tag>`.

### Status and removal

```bash
plesk-slave-zone-cleanup status          # settings, next run, last runs
plesk-slave-zone-cleanup version
sudo plesk-slave-zone-cleanup uninstall  # removes schedule, settings and script; BIND is untouched
```

## Usage

```bash
# Auto mode: find broken zones from every primary in the log
plesk-slave-zone-cleanup dryrun                   # show what would be removed
plesk-slave-zone-cleanup                          # remove zones (asks about zone files)
plesk-slave-zone-cleanup yes                      # remove zones and delete zone files
plesk-slave-zone-cleanup no                       # remove zones, keep zone files

# Only one primary
plesk-slave-zone-cleanup 192.0.2.10 dryrun
plesk-slave-zone-cleanup 192.0.2.10 yes

# Zone mode: remove specific zones
plesk-slave-zone-cleanup example.com dryrun
plesk-slave-zone-cleanup example.com example.net yes
plesk-slave-zone-cleanup example.com yes force    # remove even if the primary still serves it
```

| Option | Meaning |
|---|---|
| `yes` / `no` | Also delete the zone file (`rndc delzone -clean`). If left out, the script asks (default: yes); without a terminal or with `dryrun` it uses yes without asking. |
| `dryrun` | Only show what would be done. |
| `force` | Zone mode only: remove the zone even if the primary still answers for it, e.g. when the domain is moving to another DNS. |

Options can be given in any order. You can't mix an IP address and zone names in the same run.

In zone mode the primary is read from `rndc showzone <zone>`. If it can't be read, the zone is removed without a live check, since you named it explicitly.

After each removal the script checks that the zone is really gone from BIND. With `yes` it also checks that the zone file and its `.jnl` journal are gone, and deletes any file BIND left behind.

To read a different log file:

```bash
LOGFILE=/var/log/named/named.log plesk-slave-zone-cleanup dryrun
```

## Running automatically

`install` sets this up for you (see above). You can also run the script from your own cron, Ansible, or over ssh. It never asks anything when there is no terminal:

- If `yes`/`no` is not given, zone files are deleted.
- The "primary may be down" check (10+ zones of one primary that only time out) holds those zones back instead of asking, and the script exits with code 2.
- Only one run at a time. A second run started while one is going exits immediately.
- Every removal and failure is logged to `/var/log/plesk-slave-zone-cleanup.log` and to syslog with the tag `plesk-slave-zone-cleanup` (`journalctl -t plesk-slave-zone-cleanup`)

To remove a zone on every secondary from your workstation:

```bash
for ns in ns1.example.com ns2.example.com ns3.example.com; do
  echo "== $ns"; ssh "$ns" plesk-slave-zone-cleanup example.com yes
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

- **No `rndc reload` needed.** `rndc delzone` takes effect immediately.
- **Run it on every secondary.** Each secondary has its own copy of the zones.
- **Check the log format first.** If your secondaries log disabled zones with other wording, they won't be found in log mode:
  `sudo grep -E "refresh: (unexpected rcode|non-authoritative)" /var/log/syslog | head`

## License

MIT
