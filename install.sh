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

# Fix round 2, finding M10: aligned to the same check the Makefile's
# `check-device` uses (grep /etc/os-release for MustardOS) rather than the
# weaker `test -d /mnt/mmc/MUOS` this used to be - on the path that installs
# more (hook, helpers, and the app), the stronger check belongs here too.
echo "-> checking device"
ssh "$TARGET" 'grep -q MustardOS /etc/os-release 2>/dev/null' ||
	{ echo "that does not look like a muOS device (no MustardOS in /etc/os-release)" >&2; exit 1; }

ssh "$TARGET" 'mkdir -p /mnt/mmc/MUOS/init /mnt/mmc/MUOS/bluetooth /mnt/mmc/MUOS/application/Bluetooth/bin'

echo "-> bring-up hook  -> /mnt/mmc/MUOS/init/10-bluetooth.sh"
put "$HERE/init/10-bluetooth.sh" /mnt/mmc/MUOS/init/10-bluetooth.sh

echo "-> helpers        -> /mnt/mmc/MUOS/bluetooth/"
put "$HERE/bin/bt-check.sh" /mnt/mmc/MUOS/bluetooth/bt-check.sh
put "$HERE/bin/bt-pair.sh" /mnt/mmc/MUOS/bluetooth/bt-pair.sh
put "$HERE/bin/bt-audio.sh" /mnt/mmc/MUOS/bluetooth/bt-audio.sh

# Fix round 2, finding I2: this step used to be a hard `exit 1` before
# anything at all was installed - a user who only wants the hook and shell
# helpers (this repo's original, most hardware-proven value) could no longer
# get them without a Zig cross-compile toolchain, the Homebrew SDL2/dbus
# headers build.zig hardcodes, and a sysroot pulled from a live device.
# Installing the app is now conditional on it already being built instead,
# so the hook and helpers above always land regardless.
app_installed=0
if [ -x "$HERE/zig-out/bin/btui" ]; then
	echo "-> app            -> /mnt/mmc/MUOS/application/Bluetooth/"
	put "$HERE/zig-out/bin/btui" /mnt/mmc/MUOS/application/Bluetooth/bin/btui
	put "$HERE/package/mux_launch.sh" /mnt/mmc/MUOS/application/Bluetooth/mux_launch.sh
	ssh "$TARGET" 'chmod +x /mnt/mmc/MUOS/application/Bluetooth/bin/btui /mnt/mmc/MUOS/application/Bluetooth/mux_launch.sh'
	app_installed=1
else
	# Fix round 2, finding I3(b): this previously said "run 'zig build'
	# first", but a bare `zig build` fails on a dev machine with no
	# `-Dtarget` (the sysroot's .so files are aarch64 stubs a native build
	# can't parse) - `make build` is the actual entry point, and it needs
	# `make sysroot` (device libraries) to exist first.
	echo "-> app            -> skipped (zig-out/bin/btui not built)"
	echo "   build it first with: make sysroot && make build"
fi

echo "-> enabling user init scripts"
ssh "$TARGET" 'printf 1 > /opt/muos/config/settings/advanced/user_init'

cat <<EOF

Done. Reboot the device, then:

  ssh $TARGET 'tail -20 /mnt/mmc/MUOS/log/bluetooth.log'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-check.sh'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-pair.sh scan'
  ssh $TARGET 'sh /mnt/mmc/MUOS/bluetooth/bt-audio.sh use'

EOF

if [ "$app_installed" -eq 1 ]; then
	echo "The Bluetooth app should now also appear in muOS's Applications menu."
else
	echo "The btui app was not installed (see above) - re-run this script after building it."
fi
