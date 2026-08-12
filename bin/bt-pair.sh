#!/bin/sh
# Pair, trust and connect a Bluetooth device from the shell.
# Run on the device (over SSH), after the stack is up.
#
#   bt-pair.sh scan [seconds]     list what is nearby (default 12s)
#   bt-pair.sh AA:BB:CC:DD:EE:FF  pair + trust + connect that address
#   bt-pair.sh list               show known/paired devices
#
# "trust" is the part that makes the device reconnect on its own later.

set -u

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
}

if ! bluetoothctl show >/dev/null 2>&1; then
	echo "bluetoothd is not reachable - run the bring-up hook first" >&2
	exit 1
fi

case "${1:-}" in
	"" | -h | --help)
		usage
		;;
	scan)
		SECS=${2:-12}
		echo "scanning for ${SECS}s ..."
		bluetoothctl --timeout "$SECS" scan on >/dev/null 2>&1
		bluetoothctl devices
		;;
	list)
		echo "-- known --"
		bluetoothctl devices
		echo "-- paired --"
		bluetoothctl devices Paired
		echo "-- connected --"
		bluetoothctl devices Connected
		;;
	*)
		MAC=$1
		case "$MAC" in
			[0-9A-Fa-f][0-9A-Fa-f]:*) ;;
			*) echo "not a MAC address: $MAC" >&2; usage ;;
		esac

		echo "put the device into pairing mode now, then press enter"
		read -r _

		bluetoothctl --timeout 12 scan on >/dev/null 2>&1

		echo "-- pair --"
		bluetoothctl pair "$MAC"
		echo "-- trust --"
		bluetoothctl trust "$MAC"
		echo "-- connect --"
		bluetoothctl connect "$MAC"

		echo "-- result --"
		bluetoothctl info "$MAC" | grep -E "Name|Paired|Trusted|Connected|Icon"
		;;
esac
