# F5-NTP-Key-Restore-Script

This process installs a startup script on the Big-IP that restores the NTP symmetric authentication key after a TMOS upgrade. The `/etc/ntp/keys` file is not included in the UCS archive; a TMOS upgrade installs a clean `/etc` on the new boot volume and loads only the UCS into it, so the key line is lost on every upgrade and the unit reverts to unauthenticated time sync. F5 documents this as expected behavior. The script runs from F5's supported customer startup hook, lives under `/config` so it is carried in the UCS, checks the keys file once per boot, and only when the key is missing writes it back and restarts ntpd.

## References

- [K000139030: Changes made to the /etc/ntp/keys file are lost after an upgrade](https://my.f5.com/manage/s/article/K000139030)
- [K11948: Configuring the BIG-IP system to run commands or scripts upon system startup](https://my.f5.com/manage/s/article/K11948)
- [K4422: Viewing and modifying the files that are configured for inclusion in a UCS archive](https://my.f5.com/manage/s/article/K4422)
- ntp_auth(5) man page: format of the ntp.keys file

## Requirements

- TMOS version 17.1 or greater
- NTP authentication already configured and working on the Big-IP
- Root shell access to each Big-IP unit
- The NTP key line as it appears in `/etc/ntp/keys`, in the form `<id> M <passphrase>`

## Procedure

### 1. Confirm the current NTP authentication state

Log into the Big-IP as root and confirm the key line is present and authentication is working.

```
more /etc/ntp/keys
ntpq -c as
```

- The keys file shows the key line below F5's three comment lines.
- In the `ntpq -c as` output, the real time server shows `ok` in the `auth` column. The Big-IP's own local clock (127.127.1.0) always shows `none`; that is expected.

### 2. Create the restore script

Create `/config/startup_ntp-key-restore.sh` with the content below.

Set `NTP_KEYS` to the exact key line from `/etc/ntp/keys`. Multiple keys are comma separated with no spaces after the commas. This is the only line in the script that should ever need editing.

```bash
#!/bin/bash
# NTP Key Restore: Restores NTP symmetric keys after TMOS upgrades; see K000139030
# Version: 1.0
# Author: Eric Haupt
# Released under the MIT License.
#
# Multiple keys are comma separated with no spaces after commas.
# Format: "<id> M <passphrase>"
# "1 M examplekey,2 M examplekey2"
NTP_KEYS="1 M examplekey"
source /usr/lib/bigstart/bigip-ready-functions 2>/dev/null
wait_bigip_ready 2>/dev/null
for i in $(seq 1 30); do
    [ "$(tmsh show sys mcp-state field-fmt 2>/dev/null | awk '/phase/{print $2}')" = running ] \
        && pgrep -x ntpd >/dev/null && break
    sleep 10
done
restored=""
IFS=',' read -ra keys <<< "$NTP_KEYS"
for key in "${keys[@]}"; do
    if ! grep -qxF "$key" /etc/ntp/keys 2>/dev/null; then
        ( umask 077; echo "$key" >> /etc/ntp/keys )
        restored="$restored ${key%% *}"
    fi
done
if [ -n "$restored" ]; then
    bigstart restart ntpd
    logger -p local0.notice -t ntp_key_restore "NTP key(s)$restored found missing and were reinstalled; ntpd has been restarted."
fi
logger -p local0.notice -t ntp_key_restore "NTP key restore exiting."
```

Set the permissions so the file is executable by root only.

```
chmod 700 /config/startup_ntp-key-restore.sh
```

### 3. Add the launch line to the F5 startup hook

Append one line to `/config/startup`. Do not overwrite the file; it contains F5's header and may contain other site additions. The `&` runs the new script in the background so its wait does not delay the rest of system startup.

```
echo '/config/startup_ntp-key-restore.sh &' >> /config/startup
```

Verify the result.

```
cat /config/startup
```

- F5's header comments are intact and the launch line is the last line.

### 4. Test the restore on the unit

Remove the key line and reboot. This reproduces the post-upgrade state, in which F5's comment lines remain and only the key line is gone.

```
sed -i '/^[0-9]/d' /etc/ntp/keys
reboot
```

After the unit is back, confirm the script ran, the key was restored, and NTP authenticated synchronization is occurring.

```
grep ntp_key_restore /var/log/ltm
more /etc/ntp/keys
ntpq -c as
```

- Two `ntp_key_restore` lines appear: the restore and the exit. Both carry the unit's real hostname, not `localhost`.
- The key line is back in `/etc/ntp/keys`.
- Within a few polls the time server shows `auth ok` and becomes `sys.peer`. Immediately after the restart it may briefly show `reject` or `candidate` while ntpd collects samples; that resolves on its own.

### 5. Repeat on the peer unit

The script and the launch line are files, not configuration objects, so they do not config-sync. Perform steps 2 through 4 on each unit of the device group.

## Verification after an upgrade

After the first boot on the new volume, run the same checks as in step 4. One `exiting` log entry in `/var/log/ltm` means the script ran and found the key present; a restore log entry followed by the `exiting` entry means the script repaired the keys file. No log entries at all means the script did not run: check that the file is executable and that the launch line is present in `/config/startup`.

The `auth` column in `ntpq -c as` is the definitive check. Unauthenticated sync looks healthy in `ntpq -p`; only `ntpq -c as` shows whether the key exchange is working. `none` on the time server's line means the server entry lacks `key N`; `bad` means the passphrase or key ID does not match the server, or `NTP_KEYS` was entered incorrectly.

## Notes

- The script runs once at boot and exits. It does not run on a timer and does not touch anything else on the system. On an ordinary reboot it finds the key present, logs the exit line, and does nothing.
- `wait_bigip_ready` returns when the configuration is loaded and has no time limit of its own; a unit whose configuration never loads leaves the script waiting. The loop that follows is capped at five minutes: it waits for mcpd to report `running` and for an `ntpd` process to exist, then proceeds regardless.
- The script only adds key lines. If a passphrase is rotated, edit `NTP_KEYS` and remove the old line from `/etc/ntp/keys` on each unit.
- The script does not validate `NTP_KEYS`. A mistyped entry is written to the keys file as-is and shows as `auth bad` in `ntpq -c as`.

## Appendix A: Script breakdown

| Script | What it does |
|---|---|
| `#!/bin/bash` | Declares the file as a bash script. |
| `NTP_KEYS="1 M examplekey"` | The only line that should ever need editing. It holds the key line, or several separated by commas, exactly as it must appear in `/etc/ntp/keys`: the key ID, the letter `M` for MD5, and the passphrase, separated by single spaces. A site with two keys writes `"1 M firstkey,2 M secondkey"` with no spaces after the commas. |
| `source /usr/lib/bigstart/bigip-ready-functions 2>/dev/null` | Loads a set of helper functions that F5 ships with the Big-IP. `2>/dev/null` discards any error so the script continues even if the helper file is absent on some build. |
| `wait_bigip_ready 2>/dev/null` | One of those helper functions. It pauses, checking once a second, until the Big-IP reports that its configuration is loaded, its modules are provisioned and its license is valid, then returns. This is where the script absorbs most of the difference between fast-booting and slow-booting units. It has no time limit of its own. |
| `for i in $(seq 1 30); do`<br>`    [ "$(tmsh show sys mcp-state field-fmt 2>/dev/null \| awk '/phase/{print $2}')" = running ] \`<br>`        && pgrep -x ntpd >/dev/null && break`<br>`    sleep 10`<br>`done` | A bounded wait of up to 30 passes at 10 seconds each, five minutes in total. Each pass makes two checks and stops the loop as soon as both pass.<br><br>The first runs `tmsh show sys mcp-state field-fmt`, whose output includes the line `phase running` once mcpd has finished loading and is serving the configuration; `awk` prints the word after `phase` and the script compares it with `running`. During boot the phase passes through other values first.<br><br>The second, `pgrep -x ntpd`, succeeds only if a process named exactly `ntpd` exists, confirming the time service has been started by the system so the later restart is not racing the system's own startup.<br><br>If both checks never pass, the loop ends after the 30th pass and the script continues regardless. |
| `restored=""`<br>`IFS=',' read -ra keys <<< "$NTP_KEYS"` | `restored` starts empty and will collect the IDs of any keys written back. The second line splits `NTP_KEYS` at the commas into a list named `keys`, one entry per key line. |
| `for key in "${keys[@]}"; do`<br>`    if ! grep -qxF "$key" /etc/ntp/keys 2>/dev/null; then` | For each key line in the list, searches `/etc/ntp/keys` for a line that is exactly that text. `-q` suppresses output, `-x` requires the whole line to match, and `-F` treats the key as literal text so passphrase characters such as `. * [ ^ $` are not read as a pattern. The leading `!` reverses the result, so the block that follows runs only when the line is not found.<br><br>A healthy keys file has F5's three comment lines followed by the key line. After a TMOS upgrade the comment lines are present but the key line is not; the file is never truly empty, which is why the script checks for the exact key line rather than for an empty file. |
| `        ( umask 077; echo "$key" >> /etc/ntp/keys )`<br>`        restored="$restored ${key%% *}"`<br>`    fi`<br>`done` | Appends the missing key line to the file. `umask 077` ensures that if the file has to be created it is readable by root only; the parentheses confine that setting to these two commands. `${key%% *}` takes everything before the first space, which is the key ID, and adds it to `restored`. That is how the log line later can name which keys were written without exposing a passphrase. |
| `if [ -n "$restored" ]; then`<br>`    bigstart restart ntpd`<br>`    logger -p local0.notice -t ntp_key_restore "NTP key(s)$restored found missing and were reinstalled; ntpd has been restarted."`<br>`fi` | Runs only if at least one key was written. Restarts the time service, because ntpd reads the keys file only at start, and writes one line to the system log. `-p local0.notice` places it in `/var/log/ltm` at informational severity and `-t ntp_key_restore` tags it for searching. On an ordinary reboot where every key is present this block is skipped and ntpd is not touched. |
| `logger -p local0.notice -t ntp_key_restore "NTP key restore exiting."` | Always runs. It is the proof that the script ran to the end on this boot: one `ntp_key_restore` line in the log means the script ran and found the keys present; a restore line followed by this line means it repaired the file; no line means it did not run. |
