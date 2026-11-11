# plesk-slave-zone-cleanup

Removes slave zones from a BIND secondary nameserver when the Plesk primary no longer serves them.

Run it on the **secondary nameservers** (the BIND servers that Plesk's Slave DNS Manager pushes zones to), not on the Plesk server itself.

When a domain is deleted in Plesk, or DNS is switched off for it, the zone often stays on the secondaries. BIND keeps trying to refresh it and fills the log with errors, and the secondary keeps answering for a zone that no longer exists on the primary. This script finds those zones and removes them with `rndc delzone`.

```bash
plesk-slave-zone-cleanup 192.0.2.10 dryrun
```

> **This script changes things.** Without `dryrun` it removes zones from BIND, and with `yes` it also deletes the zone files. Always run with `dryrun` first. A removed zone comes back if Plesk pushes it again (e.g. when DNS is switched back on for the domain).

## What it finds

In log mode the script reads `/var/log/syslog` (and `syslog.1`) and looks for two kinds of zones from the given primary:

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

In log mode, a zone whose primaries no longer include the IP you gave is skipped. That happens when the domain has been moved to another Plesk server and the zone was re-added from there; the old log lines then refer to the wrong server.

### The same domain on two Plesk servers

Say `example.com` is active on Plesk server A and switched off (or left over) on server B:

- **The secondary's zone points to A:** A answers authoritatively, so the zone is kept, whether you run the script for B's IP or name the zone.
- **The secondary's zone points to B:** B says it doesn't have the zone, so the zone is removed. That is correct, since it was stale, but A's zone is not on the secondary until A pushes it again. Use *Resync* in Slave DNS Manager on server A, or switch DNS off and on for the domain there.
- **The zone lists both A and B as primaries:** A answers, so the zone is kept.

Zones that no longer exist on the secondary are skipped, so the script can be run again safely.

If 10 or more zones would be removed only because the primary times out, the script asks you to type `YES` first. The primary may simply be down, and you don't want to wipe every zone because of that.

## Requirements

- BIND 9 secondary with `rndc` access and `allow-new-zones yes` (as set up by Plesk Slave DNS Manager)
- `dig` (package `bind9-dnsutils` or `dnsutils`)
- A user with sudo. The script doesn't need to be run as root; it uses `sudo` for `rndc` and for reading the log. Running as root also works.

## Installation

```bash
sudo wget -qO /usr/local/sbin/plesk-slave-zone-cleanup \
  https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-slave-zone-cleanup/plesk-slave-zone-cleanup.sh
sudo chmod 755 /usr/local/sbin/plesk-slave-zone-cleanup
```

If `wget` is missing: `sudo apt-get install -y wget`, or see [Installing a script](../README.md#installing-a-script) for the `curl` variant.

## Usage

```bash
# Log mode: find broken zones for a primary
plesk-slave-zone-cleanup 192.0.2.10 dryrun        # show what would be removed
plesk-slave-zone-cleanup 192.0.2.10 no            # remove zones, keep zone files
plesk-slave-zone-cleanup 192.0.2.10 yes           # remove zones and delete zone files

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

Options can be given in any order after the IP address or zone names. You can't mix an IP address and zone names in the same run.

In zone mode the primary is read from `rndc showzone <zone>`. If it can't be read, the zone is removed without a live check, since you named it explicitly.

After each removal the script checks that the zone is really gone from BIND. With `yes` it also checks that the zone file and its `.jnl` journal are gone, and deletes any file BIND left behind.

To read a different log file:

```bash
LOGFILE=/var/log/named/named.log plesk-slave-zone-cleanup 192.0.2.10 dryrun
```

## Running automatically

The script never asks anything when there is no terminal (cron, `ssh host command`, pipes):

- If `yes`/`no` is not given, zone files are deleted.
- The "primary may be down" check (10+ zones that only time out) aborts with exit code 2 instead of asking.
- Every removal and failure is logged to syslog with the tag `plesk-slave-zone-cleanup`:
  `sudo grep plesk-slave-zone-cleanup /var/log/syslog`

From your workstation, against every secondary:

```bash
for ns in ns1.example.com ns2.example.com ns3.example.com; do
  echo "== $ns"; ssh "$ns" plesk-slave-zone-cleanup example.com yes
done
```

Nightly from cron on each secondary (`sudo crontab -e`):

```cron
30 3 * * * /usr/local/sbin/plesk-slave-zone-cleanup 192.0.2.10 yes >/dev/null 2>&1
```

Exit codes: 0 = OK or nothing to do, 1 = error or a removal failed, 2 = aborted by the safety check.

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
