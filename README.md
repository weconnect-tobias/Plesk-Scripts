# Plesk-Scripts

Small, standalone scripts for running and troubleshooting Plesk servers and the nameservers around them. Each script lives in its own folder with its own README, and can be installed with a single command.

## Scripts

| Script | What it does |
|---|---|
| [plesk-triage](plesk-triage/) | Finds out what is loading a slow Plesk server: CPU per PHP pool, traffic per domain, and flags for bots, AI agents, auth loops, brute force and broken crontabs. Read-only. |
| [plesk-compromise-check](plesk-compromise-check/) | Looks for signs of a break-in: webshells, PHP in upload folders, prepend backdoors, shells spawned by PHP, malware in temp folders, rogue accounts and WordPress admins, modified core files. Read-only. |
| [plesk-wp-integrity](plesk-wp-integrity/) | Checks every WordPress installation's core and wordpress.org plugins against official checksums via WP Toolkit, flags suspicious code, and can repair them. Check only by default; `--fix` asks first and saves everything for `--restore`. |
| [plesk-cron-cleanup](plesk-cron-cleanup/) | Finds orphaned and wrong-owner crontabs left behind by deleted subscriptions, and moves them aside safely. Dry run by default. |
| [dns-zone-cleanup](dns-zone-cleanup/) | Runs on BIND secondary nameservers, with any primary (Plesk or not) and old BIND versions too. Removes stale secondary zones: zones the primary no longer serves (from the log, checked live against every primary) and domains no longer delegated to the server (after 7 days). Handles `rndc addzone` zones and zones in `named.conf`. Has its own `install` with a systemd timer or cron job, self-update and an optional daily mail report. Formerly `plesk-slave-zone-cleanup`. |

## Installing a script

Every script installs the same way. Replace `SCRIPT` with the script name from the table above:

```bash
sudo wget -qO /usr/local/sbin/SCRIPT \
  https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/SCRIPT/SCRIPT.sh
sudo chmod 755 /usr/local/sbin/SCRIPT
```

Example:

```bash
sudo wget -qO /usr/local/sbin/plesk-triage \
  https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-triage/plesk-triage.sh
sudo chmod 755 /usr/local/sbin/plesk-triage
```

Run the same command again to update. Read a script before you install it; they run with sudo.

`wget` is present on most minimal installs. If it is missing, install it with `sudo apt-get install -y wget`, or use `curl` instead:

```bash
sudo curl -fsSL https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/SCRIPT/SCRIPT.sh \
  -o /usr/local/sbin/SCRIPT
```

## Releases

Releases are optional. Scripts with an `update` command compare the `VERSION` in the script on `main` with the installed one, so raising `VERSION` and pushing is enough to roll out a change.

If you do want GitHub releases, each script has its own versions and releases. Tags are named after the script:

```
dns-zone-cleanup-v1.0.0
plesk-triage-v1.2.0
```

A release contains only the notes and the file of that script. GitHub always adds a source zip of the whole repo, but that can be ignored. Scripts with their own `update` command (such as `dns-zone-cleanup`) look for the newest release with their own prefix and ignore the rest.

To make a release:

1. Raise `VERSION="x.y.z"` in the script, commit and push to `main`
2. On GitHub: **Releases → Draft a new release**
3. **Choose a tag** → type `<script>-vX.Y.Z` → **Create new tag on publish**, target `main`
4. Title: `<script> vX.Y.Z`. Write what changed.
5. Drag the script file into **Attach binaries**
6. **Publish release**

Or with the GitHub CLI:

```bash
gh release create dns-zone-cleanup-v1.0.0 --target main \
  --title "dns-zone-cleanup v1.0.0" --notes-file notes.md \
  dns-zone-cleanup/dns-zone-cleanup.sh
```

The tag must match `VERSION` in the script. Otherwise `update` sees the wrong version.

## Principles

All scripts in this repo follow the same rules:

- **No root login required.** Scripts are run as a regular sudo user (e.g. `ubuntu`) and elevate themselves with `sudo` when needed.
- **Read-only by default.** A script that only diagnoses never changes anything. A script that does change something says so clearly in its README, asks before acting, and never deletes: files are moved or saved so the change can be undone.
- **One file, no dependencies.** Each script is a single Bash file that uses tools already present on a standard Plesk server.
- **No customer data.** Examples use `example.com`. Never commit log excerpts, IP addresses, domain names or credentials.

## Requirements

- Plesk Obsidian on Linux (tested on Ubuntu 24.04)
- Bash 4+

Individual scripts may have extra requirements, listed in their own README.

## Adding a script

1. Create a folder named after the script: `my-script/`
2. Add `my-script.sh` and a `README.md` describing what it does, its options and how to read the output
3. Add a row to the table above
4. Test it on a non-production server first

## License

[MIT](LICENSE)
