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

Create `/config/startup_ntp-key-restore.sh` with the content of [startup_ntp-key-restore.sh](startup_ntp-key-restore.sh).

Set `NTP_KEYS` to the exact key line from `/etc/ntp/keys`. Multiple keys are comma separated with no spaces after the commas. This is the only line in the script that should ever need editing.

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

- The script runs once at boot and exits. It does not run on a timer and does not touch anything else on the system. On an ordinary reboot it finds the key(s) present, logs the exit line, and does nothing.
- The script only adds key lines, it doesnt delete them. If a passphrase is rotated, edit `NTP_KEYS` and remove the old line from `/etc/ntp/keys` on each unit.
- The script does not validate `NTP_KEYS`. A mistyped entry is written to the keys file as-is and shows as `auth bad` in `ntpq -c as`.

