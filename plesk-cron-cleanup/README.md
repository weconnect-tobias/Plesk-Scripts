# plesk-cron-cleanup

Finds and cleans up broken user crontabs on a Plesk server.

When subscriptions are deleted, their crontab files can be left behind. Later a new system user may get the same UID and suddenly "own" someone else's crontab. cron refuses to load such files, so their jobs silently stop running. In the worst case the cron daemon starts re-reading its spool in a tight loop and uses a full CPU core, keeping systemd busy as well.

```bash
plesk-cron-cleanup
```

By default the script only shows what is wrong. Nothing is changed until you add `--apply`, and nothing is ever deleted: files are moved to a backup folder and can be put back with `--restore`.

## What it finds

| Problem | What it means | What `--apply` does |
|---|---|---|
| **Orphaned crontab** | The user in the file name no longer exists. cron never runs it. | Moves it to `/var/backups/plesk-cron-cleanup/<time>/` |
| **Wrong owner** | The user exists, but the file is owned by someone else (usually a reused UID). cron skips it. | Nothing, unless you add `--fix-owner` |
| **Wrong permissions** | The file is not mode 600. | Sets mode 600 and the correct group |

For orphaned crontabs the script also checks whether they still refer to a site on the server. Those jobs have not been running; if they are still needed, recreate them under the right subscription in Plesk (*Websites & Domains → Scheduled Tasks*).

For wrong-owner crontabs it shows the first lines of each file, so you can check that the file really belongs to the user in its name before giving it back.

## Requirements

- Plesk on Linux. Debian/Ubuntu (`/var/spool/cron/crontabs`) and RHEL-based systems (`/var/spool/cron`) are both supported.
- A user with sudo. The script doesn't need to be run as root; it re-runs itself with `sudo`.

## Installation

```bash
sudo wget -qO /usr/local/sbin/plesk-cron-cleanup \
  https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-cron-cleanup/plesk-cron-cleanup.sh
sudo chmod 755 /usr/local/sbin/plesk-cron-cleanup
```

## Usage

```bash
plesk-cron-cleanup                  # dry run: show problems, change nothing
plesk-cron-cleanup --apply          # move orphaned crontabs, fix permissions, restart cron
plesk-cron-cleanup --fix-owner      # same as --apply, and give wrong-owner crontabs back to their user
plesk-cron-cleanup --restore DIR    # put crontabs from a backup folder back
```

After `--apply` the script restarts cron and shows the cron daemon's CPU use, so you can see whether a spool loop is gone. It also prints the exact `--restore` command to undo the change.

Exit code: 0 when everything is fine, 1 when the dry run found problems. Handy for monitoring.

## Good to know

- **Jobs start running again with `--fix-owner`.** Some of them may have been stopped for months, and a backlog (e.g. `artisan schedule:run` or wp-cron) can run all at once. Tell the customer if it matters.
- **Why this happens in Plesk:** deleting a subscription removes the system user, but not always its crontab. When Plesk later creates a new user with the same UID, the old file appears to belong to the new user. `plesk-triage` also reports these crontabs.

## License

MIT
