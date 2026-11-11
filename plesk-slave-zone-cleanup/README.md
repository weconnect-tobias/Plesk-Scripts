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

Log lines can be old, so every zone is checked live against the primary with `dig +norec SOA` before anything is removed:

| Primary answer | Action |
|---|---|
| Authoritative answer (`aa` flag) | Skip: the zone is active again |
| `REFUSED`, `NOTAUTH`, `NXDOMAIN`, or no `aa` flag | Remove |
| Timeout | Remove RETRY zones (the original behaviour); skip DISABLED zones, since a sudden timeout suggests a network problem |
| Anything else (e.g. `SERVFAIL`) | Skip: the zone exists on the primary but is broken there, check manually |

Zones that no longer exist on the secondary are skipped, so the script can be run again safely.

If 10 or more zones would be removed only because the primary times out, the script asks you to type `YES` first. The primary may simply be down, and you don't want to wipe every zone because of that.

## Requirements

- BIND 9 secondary with `rndc` access and `allow-new-zones yes` (as set up by Plesk Slave DNS Manager)
- `dig` (package `bind9-dnsutils` or `dnsutils`)
- A user with sudo. The script doesn't need to be run as root; it uses `sudo` for `rndc` and for reading the log.

## Installation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-slave-zone-cleanup/plesk-slave-zone-cleanup.sh \
  -o /usr/local/sbin/plesk-slave-zone-cleanup
sudo chmod 755 /usr/local/sbin/plesk-slave-zone-cleanup
```

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
| `yes` / `no` | Also delete the zone file (`rndc delzone -clean`). If left out, the script asks (default: yes). |
| `dryrun` | Only show what would be done. |
| `force` | Zone mode only: remove the zone even if the primary still answers for it, e.g. when the domain is moving to another DNS. |

Options can be given in any order after the IP address or zone names. You can't mix an IP address and zone names in the same run.

In zone mode the primary is read from `rndc showzone <zone>`. If it can't be read, the zone is removed without a live check, since you named it explicitly.

To read a different log file:

```bash
LOGFILE=/var/log/named/named.log plesk-slave-zone-cleanup 192.0.2.10 dryrun
```

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
