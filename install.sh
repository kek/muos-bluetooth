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

	# Best-effort app icon: muOS ships no "bluetooth" glyph under any
	# theme's glyph/muxapp/ (the set Applications-menu icons resolve
	# from), so btui's `# ICON: bluetooth` launcher line has nothing to
	# find there. Borrow each theme's own Bluetooth artwork instead -
	# on the device tested, only the active theme had a muxapp icon set
	# at all, and it also shipped a Bluetooth glyph under
	# muxdevice/muxconnect/header (see README for details and caveats).
	# Runs entirely on-device in one ssh call; failure here must never
	# abort the install, so the whole step is guarded.
	echo "-> app icon       -> best-effort, from each theme's own glyphs"
	ssh "$TARGET" '
		theme_dir=/run/muos/storage/theme
		installed=0
		skipped=0
		for t in "$theme_dir"/*; do
			[ -d "$t" ] || continue
			name=$(basename "$t")
			case "$name" in
				active|override) continue ;;
			esac
			dest="$t/glyph/muxapp"
			[ -d "$dest" ] || { skipped=$((skipped + 1)); continue; }
			[ -f "$dest/bluetooth.png" ] && { skipped=$((skipped + 1)); continue; }
			src=""
			for rel in glyph/muxdevice/bluetooth.png glyph/muxconnect/bluetooth.png glyph/header/bluetooth.png; do
				if [ -f "$t/$rel" ]; then
					src="$t/$rel"
					break
				fi
			done
			if [ -n "$src" ] && cp "$src" "$dest/bluetooth.png" 2>/dev/null; then
				installed=$((installed + 1))
			else
				skipped=$((skipped + 1))
			fi
		done
		echo "   icon added for $installed theme(s), skipped $skipped (no Bluetooth glyph to borrow, or already set)"
	' || echo "   icon step failed - btui still works without one, see README"
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
