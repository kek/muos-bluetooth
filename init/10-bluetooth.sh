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

# The PipeWire tools used at the end need these to find the daemon socket.
# muOS exports them from script/var/func.sh, so they are normally inherited at
# boot - set them anyway so the script also works when run by hand over ssh.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run}"

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

# Reconnect paired devices. BlueZ will not initiate this by itself, and on a
# build without native Bluetooth there is nothing else to do it either -
# upstream muOS calls `bt_device.sh autoconnect` at exactly this point.
CONNECTED=0
for MAC in $(bluetoothctl devices Paired 2>/dev/null | awk '{ print $2 }'); do
	if bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"; then
		say "$MAC already connected"
		CONNECTED=1
		continue
	fi

	n=0
	while [ "$n" -lt 3 ]; do
		bluetoothctl connect "$MAC" >/dev/null 2>&1
		sleep 2
		if bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"; then
			say "connected $MAC"
			CONNECTED=1
			break
		fi
		n=$((n + 1))
	done

	[ "$n" -ge 3 ] && say "could not connect $MAC (powered off or out of range)"
done

# muOS keeps the default sink on the internal card - it has no idea Bluetooth
# exists here - so a connected headset otherwise ends up with a working sink
# that nothing plays to. Waiting for the sink also waits for PipeWire itself.
if [ "$CONNECTED" -eq 1 ]; then
	BT_SINK=""
	n=0
	while [ "$n" -lt 20 ]; do
		BT_SINK=$(pw-cli ls Node 2>/dev/null | awk '
			/^[[:space:]]*id [0-9]+,/ { gsub(/,/, "", $2); id = $2 }
			/node.name = "bluez_output/ { print id; exit }')
		[ -n "$BT_SINK" ] && break
		sleep 1
		n=$((n + 1))
	done

	if [ -n "$BT_SINK" ]; then
		if wpctl set-default "$BT_SINK" 2>/dev/null; then
			say "default sink -> node $BT_SINK (bluetooth)"
		else
			say "could not set node $BT_SINK as default"
		fi
	else
		say "device connected but no bluetooth sink appeared"
	fi
fi

say "=== bring-up complete ==="
