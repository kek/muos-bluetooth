#!/bin/sh
# Point audio at a connected Bluetooth sink, or back at the internal card.
# Run on the device (over SSH).
#
#   bt-audio.sh              show sinks and which one is default
#   bt-audio.sh use [vol]    make the Bluetooth sink default (vol 0.0-1.0)
#   bt-audio.sh internal     put the default back on the built-in card
#
# Needed because muOS's own audio setup keeps the default sink on the internal
# card - it has no idea Bluetooth exists on builds without native BT support.
# Connecting a headset therefore creates a working sink that nothing plays to.

set -u

# The PipeWire tools need these to find the daemon socket. muOS exports them
# from script/var/func.sh, which is not in scope when this is run directly
# (e.g. `ssh device 'sh bt-audio.sh'`) - without them pw-dump silently fails
# and every sink looks missing.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run}"
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run}"

# Node id of the first bluez_output.* sink, empty if none.
bt_sink_id() {
	if command -v jq >/dev/null 2>&1; then
		pw-dump 2>/dev/null | jq -r '
			.[] | select(.type == "PipeWire:Interface:Node")
			| select((.info.props["node.name"] // "") | startswith("bluez_output"))
			| .id' 2>/dev/null | head -1
	else
		pw-cli ls Node 2>/dev/null | awk '
			/^[[:space:]]*id [0-9]+,/ { gsub(/,/, "", $2); id = $2 }
			/node.name = "bluez_output/ { print id; exit }'
	fi
}

# Node id of the first alsa_output.* sink, empty if none.
alsa_sink_id() {
	if command -v jq >/dev/null 2>&1; then
		pw-dump 2>/dev/null | jq -r '
			.[] | select(.type == "PipeWire:Interface:Node")
			| select((.info.props["node.name"] // "") | startswith("alsa_output"))
			| .id' 2>/dev/null | head -1
	else
		pw-cli ls Node 2>/dev/null | awk '
			/^[[:space:]]*id [0-9]+,/ { gsub(/,/, "", $2); id = $2 }
			/node.name = "alsa_output/ { print id; exit }'
	fi
}

show() {
	# Scope to the Audio section - "Sinks:" also appears under Video.
	wpctl status 2>/dev/null | sed -n '/^Audio/,/^Video/p' |
		sed -n '/Sinks:/,/Sink endpoints/p' | grep -v "Sink endpoints"
	echo "streams:"
	wpctl status 2>/dev/null | sed -n '/Streams:/,$p' |
		grep -E "output_|input_" || echo "  (none)"
}

case "${1:-status}" in
	status)
		show
		BT=$(bt_sink_id)
		[ -n "$BT" ] && echo "bluetooth sink: node $BT" || echo "bluetooth sink: none (nothing connected?)"
		;;
	use)
		BT=$(bt_sink_id)
		if [ -z "$BT" ]; then
			echo "no Bluetooth sink - is a device connected? try: bluetoothctl devices Connected" >&2
			exit 1
		fi
		wpctl set-default "$BT"
		[ -n "${2:-}" ] && wpctl set-volume "$BT" "$2"
		sleep 1
		echo "default is now node $BT"
		show
		;;
	internal)
		AL=$(alsa_sink_id)
		if [ -z "$AL" ]; then
			echo "no internal sink found" >&2
			exit 1
		fi
		wpctl set-default "$AL"
		sleep 1
		echo "default is now node $AL (internal)"
		show
		;;
	*)
		sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
