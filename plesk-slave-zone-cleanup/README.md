# plesk-slave-zone-cleanup → dns-zone-cleanup

This script has been renamed to **[dns-zone-cleanup](../dns-zone-cleanup/)**. It now works on any BIND secondary nameserver, not only with Plesk.

Existing installations move over by themselves: at its next `update`, `plesk-slave-zone-cleanup` installs the small script in this folder. That script installs `dns-zone-cleanup`, which takes over the settings, schedule, mail report and logs. The old command name keeps working.

To move over right away:

```bash
sudo plesk-slave-zone-cleanup update
```

New installs: see [dns-zone-cleanup](../dns-zone-cleanup/).
