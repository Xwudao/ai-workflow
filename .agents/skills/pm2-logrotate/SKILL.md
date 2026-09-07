---
name: pm2-logrotate
description: Install and configure PM2's pm2-logrotate module on a remote Linux server. Use to rotate PM2 stdout/stderr logs on a cron schedule, compress archives, retain a bounded number of rotations, persist the module across reboot, and safely verify or roll back the change.
allowed-tools: Bash(*)
---

# PM2 Log Rotation

Use this skill when a server runs Node.js processes under PM2 and needs automatic
rotation of `~/.pm2/logs/*.log`. The `pm2-logrotate` module runs inside PM2; it
is not an `/etc/logrotate.d` rule.

## Safety rules

1. Discover the PM2 user first. PM2 state is per user (`$PM2_HOME`, normally
   `~/.pm2`); configuring root does not configure another deploy user.
2. Before editing module configuration, back up `module_conf.json` and
   `dump.pm2` if they exist. Do not put server credentials in this skill or its
   output.
3. Use the actual PM2 environment. For `fnm`, a non-interactive SSH shell must
   load `fnm env` before invoking `pm2`.
4. Always run `pm2 save --force` after installing/configuring a module, then
   verify the module is `online`. For reboot persistence, PM2 itself must have
   an enabled startup service.

## 1. Inspect prerequisites

Replace `<host>` and `<user>` as needed.

```bash
ssh <host> 'set -e
whoami
printf "PM2_HOME=%s\\n" "${PM2_HOME:-$HOME/.pm2}"
command -v pm2 || true
pm2 --version 2>/dev/null || true
pm2 ls 2>/dev/null || true
systemctl is-enabled pm2-$(whoami).service 2>/dev/null || true'
```

For a PM2 installation managed by fnm, use this prologue in each remote command:

```bash
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)"
```

If PM2 is not installed, install Node.js/PM2 first. If no PM2 startup service
exists, configure it before declaring reboot persistence:

```bash
pm2 startup systemd -u "$(whoami)" --hp "$HOME"
pm2 save --force
systemctl enable "pm2-$(whoami).service"
```

## 2. Back up and install the module

```bash
ssh <host> 'set -euo pipefail
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)"
backup_dir="$HOME/.config-backups/$(date +%Y%m%d-%H%M%S)-pm2-logrotate"
mkdir -p "$backup_dir"
for file in "$HOME/.pm2/module_conf.json" "$HOME/.pm2/dump.pm2"; do
  [ -e "$file" ] && cp -a "$file" "$backup_dir/"
done
printf "Backup: %s\\n" "$backup_dir"
pm2 install pm2-logrotate'
```

Installing an existing module is normally safe; nevertheless, preserve the
configuration first because `pm2 set` restarts the module.

## 3. Configure rotation

`rotateInterval` is a five-field cron expression:

```text
minute hour day-of-month month day-of-week
```

For rotation every 12 hours at midnight and noon, use **`0 */12 * * *`**:

```bash
ssh <host> 'set -e
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)"
pm2 set pm2-logrotate:rotateInterval "0 */12 * * *"
pm2 set pm2-logrotate:compress true
pm2 set pm2-logrotate:retain 3
pm2 save --force
pm2 conf pm2-logrotate
pm2 ls'
```

Important interpretation:

- `* * */12 * *` is **not** every 12 hours. It runs every minute on days 1,
  13, and 25 of each month.
- `retain 3` keeps three rotated files, not three hours of logs. With a clean
  12-hour schedule that is roughly 36 hours; size-based rotation can shorten it.
- The module defaults `max_size` to `10M`. Set it explicitly if the service's
  log volume demands a different threshold, for example:

  ```bash
  pm2 set pm2-logrotate:max_size 50M
  pm2 save --force
  ```

## 4. Verify persistence

```bash
ssh <host> 'set -e
export PATH="$HOME/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)"
pm2 conf pm2-logrotate
pm2 ls | grep -F pm2-logrotate
test -s "$HOME/.pm2/dump.pm2" && echo PM2_DUMP_SAVED
systemctl is-enabled "pm2-$(whoami).service"
systemctl is-active "pm2-$(whoami).service"'
```

Expected: the module is `online`, a PM2 dump exists, and the corresponding
`pm2-<user>.service` is enabled and active.

## Rollback

To remove only the log-rotation module:

```bash
pm2 uninstall pm2-logrotate
pm2 save --force
```

To restore the previous PM2 state, copy the pre-change files from the recorded
backup directory back to `~/.pm2/`, then restart the PM2 systemd service:

```bash
systemctl restart "pm2-$(whoami).service"
```

Verify with `pm2 ls` and `pm2 conf pm2-logrotate` (the latter should no longer
show the module after uninstall).
