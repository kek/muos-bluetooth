#!/bin/sh
# Install the bring-up hook and helpers onto a muOS device over SSH.
#
#   ./install.sh root@<device-ip>
#
# Files are piped over an ssh session rather than copied with scp, so nothing
# on the device side is required beyond a shell - no sftp-server, no scp binary.
#
# Afterwards the device needs a reboot. To undo, see "Undo" in the README.

set -eu

TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: $0 root@<device-ip>" >&2; exit 1; }

HERE=$(dirname "$0")

put() { # put <local file> <remote path>
	ssh "$TARGET" "cat > '$2'" <"$1"
}

echo "-> checking device"
ssh "$TARGET" 'test -d /mnt/mmc/MUOS' ||
	{ echo "that does not look like a muOS device (/mnt/mmc/MUOS missing)" >&2; exit 1; }

[ -x "$HERE/zig-out/bin/btui" ] ||
	{ echo "zig-out/bin/btui is missing - run 'zig build' first" >&2; exit 1; }

ssh "$TARGET" 'mkdir -p /mnt/mmc/MUOS/init /mnt/mmc/MUOS/bluetooth /mnt/mmc/MUOS/application/Bluetooth/bin'

echo "-> bring-up hook  -> /mnt/mmc/MUOS/init/10-bluetooth.sh"
put "$HERE/init/10-bluetooth.sh" /mnt/mmc/MUOS/init/10-bluetooth.sh

echo "-> helpers        -> /mnt/mmc/MUOS/bluetooth/"
put "$HERE/bin/bt-check.sh" /mnt/mmc/MUOS/bluetooth/bt-check.sh
put "$HERE/bin/bt-pair.sh" /mnt/mmc/MUOS/bluetooth/bt-pair.sh
put "$HERE/bin/bt-audio.sh" /mnt/mmc/MUOS/bluetooth/bt-audio.sh

echo "-> app            -> /mnt/mmc/MUOS/application/Bluetooth/"
put "$HERE/zig-out/bin/btui" /mnt/mmc/MUOS/application/Bluetooth/bin/btui
put "$HERE/package/mux_launch.sh" /mnt/mmc/MUOS/application/Bluetooth/mux_launch.sh
ssh "$TARGET" 'chmod +x /mnt/mmc/MUOS/application/Bluetooth/bin/btui /mnt/mmc/MUOS/application/Bluetooth/mux_launch.sh'

echo "-> enabling user init scripts"
ssh "$TARGET" 'printf 1 > /opt/muos/config/settings/advanced/user_init'

cat <<EOF

Done. Reboot the device, then:

  ssh $TARGET 'tail -20 /mnt/mmc/MUOS/log/bluetooth.log'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-check.sh'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-pair.sh scan'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-audio.sh use'

The Bluetooth app should now also appear in muOS's Applications menu.

EOF
