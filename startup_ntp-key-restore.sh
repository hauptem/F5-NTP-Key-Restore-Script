#!/bin/bash
# NTP Key Restore: Restores NTP symmetric keys after TMOS upgrades; see K000139030
# Version: 1.0
# Author: Eric Haupt
# Released under the MIT License.
#
# Multiple keys are comma separated with no spaces after commas.
# Format: "<id> M <passphrase>"
# "1 M examplekey1,2 M examplekey2"
NTP_KEYS="1 M examplekey1"

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
