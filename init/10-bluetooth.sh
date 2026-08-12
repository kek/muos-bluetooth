#!/bin/sh
# muOS user_init hook - bring up the Bluetooth radio on builds that ship the
# BlueZ stack but have no native Bluetooth support wired into the frontend.
#
# Install to:  /mnt/mmc/MUOS/init/10-bluetooth.sh
# Then enable: Advanced Settings -> User Init Scripts
#
# Derived from MustardOS/internal script/init/S75bluetooth.sh (GPL-3.0), rg* branch.
# Differences: no dependency on the unreleased bt_device.sh / bt_monitor.sh helpers,
# no LOG_* helpers from func.sh, bluetoothd without -d, and the wlan module is
# waited for by name from the device config instead of calling S02network.sh.

set -u

DEV_CFG=/opt/muos/device/config
RUN_DIR=/run/muos

BT_DAEMON=/usr/libexec/bluetooth/bluetoothd
BTLPM_KO=/lib/modules/4.9.170/kernel/drivers/bluetooth/rtl_btlpm.ko
HCI_TTY=/dev/ttyS1
HCI_SPEED=115200
HCI_PROTO=rtk_h5

LOG=/mnt/mmc/MUOS/log/bluetooth.log
[ -d "$(dirname "$LOG")" ] || LOG=/tmp/bluetooth.log
exec >>"$LOG" 2>&1

say() { echo "[$(date '+%F %T')] $*"; }

say "=== bring-up starting ==="

BOARD=$(cat "$DEV_CFG/board/name" 2>/dev/null || echo unknown)
case "$BOARD" in
	rg*) ;;
	*)
		say "board '$BOARD' is not a Realtek rg* variant - not attempting"
		exit 0
		;;
esac

# The Bluetooth radio shares silicon with WiFi on these combo chips (RTL8821CS
# and friends), so the wlan driver has to be loaded before the HCI UART answers.
# At boot this is a race against muOS loading it itself, hence the wait.
NET_NAME=$(cat "$DEV_CFG/network/name" 2>/dev/null || echo "")
if [ -n "$NET_NAME" ]; then
	i=0
	while [ "$i" -lt 50 ]; do
		grep -q "^$NET_NAME " /proc/modules && break
		modprobe -q "$NET_NAME"
		sleep 0.2
		i=$((i + 1))
	done

	if ! grep -q "^$NET_NAME " /proc/modules; then
		say "wlan module '$NET_NAME' never loaded - aborting"
		exit 1
	fi
	say "wlan module '$NET_NAME' present"
fi

rfkill unblock all 2>/dev/null
[ -f "$BTLPM_KO" ] && modprobe "$BTLPM_KO" 2>/dev/null

if pgrep rtk_hciattach >/dev/null 2>&1; then
	say "rtk_hciattach already running"
else
	rtk_hciattach -n -s "$HCI_SPEED" "$HCI_TTY" "$HCI_PROTO" >/dev/null 2>&1 &
	printf "%s" "$!" >"$RUN_DIR/hciattach.pid" 2>/dev/null
	say "attached HCI on $HCI_TTY ($HCI_PROTO @ $HCI_SPEED)"
fi

i=0
while [ "$i" -lt 50 ]; do
	[ -d /sys/class/bluetooth/hci0 ] && break
	sleep 0.1
	i=$((i + 1))
done

if [ ! -d /sys/class/bluetooth/hci0 ]; then
	say "hci0 never appeared - giving up"
	exit 1
fi

hciconfig hci0 up 2>/dev/null
say "hci0 is up"

if [ ! -x "$BT_DAEMON" ]; then
	say "no bluetoothd at $BT_DAEMON - stopping here"
	exit 1
fi

mkdir -p /var/lib/bluetooth

if pgrep bluetoothd >/dev/null 2>&1; then
	say "bluetoothd already running"
else
	"$BT_DAEMON" -n >/dev/null 2>&1 &
	printf "%s" "$!" >"$RUN_DIR/bluetoothd.pid" 2>/dev/null
	say "started bluetoothd"
fi

i=0
while [ "$i" -lt 50 ]; do
	bluetoothctl show >/dev/null 2>&1 && break
	sleep 0.1
	i=$((i + 1))
done

bluetoothctl power on >/dev/null 2>&1
say "controller: $(bluetoothctl show 2>/dev/null | head -1)"
say "=== bring-up complete ==="
