#!/bin/bash
# NTP Key Restore: Restores NTP symmetric keys after TMOS upgrades; see K000139030
# Version: 1.1
# Author: Eric Haupt
# Released under the MIT License.
# https://github.com/hauptem/F5-NTP-Key-Restore-Script
#
# One key per line inside the single quotes.
# Format: <id> M <passphrase>
# A single quote in a passphrase is written as '\''
NTP_KEYS='1 M examplekey1
2 M examplekey2'

source /usr/lib/bigstart/bigip-ready-functions 2>/dev/null
wait_bigip_ready 2>/dev/null
for i in $(seq 1 30); do
    [ "$(tmsh show sys mcp-state field-fmt 2>/dev/null | awk '/phase/{print $2}')" = running ] \
        && pgrep -x ntpd >/dev/null && break
    sleep 10
done
restored=""
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if ! grep -qxF "$key" /etc/ntp/keys 2>/dev/null; then
        ( umask 077; echo "$key" >> /etc/ntp/keys )
        restored="$restored ${key%% *}"
    fi
done <<< "$NTP_KEYS"
if [ -n "$restored" ]; then
    bigstart restart ntpd
    logger -p local0.notice -t ntp_key_restore "NTP key(s)$restored found missing and were reinstalled; ntpd has been restarted."
fi
logger -p local0.notice -t ntp_key_restore "NTP key restore exiting."
