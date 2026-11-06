# plesk-wp-integrity

Checks every WordPress installation on a Plesk server against the official checksums from wordpress.org, and can repair what doesn't match. It uses the wp-cli that ships with WP Toolkit, so nothing extra needs to be installed.

```bash
plesk-wp-integrity
```

By default it only checks. Nothing changes until you add `--fix`, and even then nothing is deleted: everything that is replaced or moved is saved first and can be put back with `--restore`.

## What it checks

| Check | What it finds |
|---|---|
| **Core files** | Modified files in WordPress core, files that should not be there (in `wp-admin`, `wp-includes` and the root), and missing files |
| **Plugins** | Modified, added and missing files in plugins from the wordpress.org directory |
| **Suspicious code** | Modified or extra PHP files are searched for typical backdoor code (`eval(base64_decode(...))`, request data run as code or commands, etc.) and marked `SUSPICIOUS CODE` |
| **Stale entries** | WP Toolkit installations whose folder no longer exists |

The output is cleaned up: WP Toolkit's own error log lines, the PHP deprecation warnings from its bundled wp-cli and duplicate lines are removed, and only installations with findings are listed.

Example:

```
=== https://www.example.com (instance 122, WordPress 7.1.4, /var/www/vhosts/example.com/httpdocs)
  core modified  wp-includes/functions.php  SUSPICIOUS CODE
  core extra     wp-includes/old_functions.php (148555 bytes, changed 2015-01-20 17:27:52)
  plugin contact-form: 1 modified, 1 added, 0 missing, 2 PHP
    SUSPICIOUS CODE contact-form.php
  plugin lightbox-plus: 26 modified, 0 added, 0 missing, 10 PHP (non-PHP files differ too: probably a different version)
  not on wordpress.org, not checked: revslider, flow-flow
```

## Reading the result

| Finding | Usually means | What to do |
|---|---|---|
| `core modified` + `SUSPICIOUS CODE` | Compromised core file | Treat as an incident: keep a copy, find how they got in, then `--fix` |
| `core modified` | Someone edited core by hand, or a compromise | Look at the file, then `--fix` |
| `core extra` | Leftovers from old WordPress versions (`wp-atom.php`), empty files, or a dropped backdoor | Check the size and date shown; `--fix` moves them to quarantine |
| `core missing` | Usually harmless if it's `readme.html` or `license.txt` (those are ignored) | `--fix` puts them back |
| plugin with a few PHP files modified | Possible backdoor in the plugin | Look at the files listed |
| plugin where **non-PHP files differ too** | A different version than wordpress.org has checksums for (old or abandoned plugin) | Not a compromise; consider updating or replacing the plugin |
| `not on wordpress.org, not checked` | Premium or custom plugins | Can't be checked this way; use `plesk-compromise-check` |

## Repair (`--fix`)

| Problem | Repair |
|---|---|
| Modified or missing core files | WordPress core is reinstalled from wordpress.org, same version. Modified files are copied to quarantine first. |
| Extra core files | Moved to quarantine |
| wordpress.org plugin with modified files | Plugin reinstalled from wordpress.org, same version. The old plugin folder is archived first. |
| Files a plugin should not have | Moved to quarantine after the reinstall |

Never touched: plugins that are not on wordpress.org, single-file plugins, themes, `wp-content/uploads` and `wp-config.php`.

`--fix` shows the plan for each site and asks before doing anything. Quarantine and backups go to `/var/backups/plesk-wp-integrity/<time>/` (root only), together with a `manifest.tsv` listing every file. Undo with:

```bash
plesk-wp-integrity --restore /var/backups/plesk-wp-integrity/<time>
```

Repair one site at a time with `-d`, and check the site afterwards.

## Requirements

- Plesk on Linux with WP Toolkit (tested on Ubuntu 24.04)
- A user with sudo. The script doesn't need to be run as root; it re-runs itself with `sudo`.
- Outbound HTTPS to wordpress.org for checksums and downloads

## Installation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/weconnect-tobias/Plesk-Scripts/main/plesk-wp-integrity/plesk-wp-integrity.sh \
  -o /usr/local/sbin/plesk-wp-integrity
sudo chmod 755 /usr/local/sbin/plesk-wp-integrity
```

## Usage

```bash
plesk-wp-integrity                       # check all installations
plesk-wp-integrity -d example.com        # only installations whose URL contains example.com
plesk-wp-integrity -i 122                # only WP Toolkit instance 122
plesk-wp-integrity --core-only           # skip plugins (faster)
plesk-wp-integrity --fix -d example.com  # repair one site, asks first
plesk-wp-integrity --fix --yes           # repair everything without asking
plesk-wp-integrity --restore DIR         # undo a repair
```

Exit code: 0 when nothing was found, 1 when there were findings.

## Good to know

- **Checking takes time.** Each installation needs two wp-cli runs and a download of checksums from wordpress.org; count on 5–15 seconds per site.
- **A clean result is not proof the site is clean.** Backdoors are often placed in `wp-content/uploads`, in themes or in premium plugins, which this check can't verify against an official copy. Run `plesk-compromise-check` as well.
- **Fix the cause, not only the files.** If a file was changed by an attacker, reinstalling it doesn't close the hole they came in through. Update everything and change passwords.

## License

MIT
