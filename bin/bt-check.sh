#!/bin/sh
# Layer-by-layer check of the Bluetooth stack on a muOS device.
# Run it on the device (over SSH). Read-only: it changes nothing.
#
# Inspired by MustardOS/internal script/mux/bt_diag.sh, which ships with the
# native Bluetooth feature and is therefore absent on builds that predate it.

DEV_CFG=/opt/muos/device/config
BT_DAEMON=/usr/libexec/bluetooth/bluetoothd

pass=0
fail=0
warn=0

ok()   { printf "  [ OK ] %s\n" "$1"; pass=$((pass + 1)); }
no()   { printf "  [FAIL] %s\n" "$1"; fail=$((fail + 1)); }
note() { printf "  [ ?? ] %s\n" "$1"; warn=$((warn + 1)); }
head_() { printf "\n%s\n" "$1"; }

printf "muOS Bluetooth check - %s\n" "$(date '+%F %T')"
printf "board: %s   muOS: %s\n" \
	"$(cat "$DEV_CFG/board/name" 2>/dev/null || echo unknown)" \
	"$(grep -o 'VERSION_ID=.*' /etc/os-release 2>/dev/null | cut -d= -f2 || echo unknown)"

head_ "Hardware and kernel"
[ -c /dev/ttyS1 ] && ok "/dev/ttyS1 exists (HCI UART)" || no "/dev/ttyS1 missing - BT UART not enabled in the device tree"
[ -d /sys/module/bluetooth ] && ok "kernel bluetooth core" || no "kernel bluetooth core missing"
[ -d /sys/module/hidp ] && ok "kernel hidp (BT input devices)" || note "kernel hidp missing - BT gamepads/keyboards will not work"
[ -d /sys/module/rfcomm ] && ok "kernel rfcomm" || note "kernel rfcomm missing"
[ -f /lib/modules/"$(uname -r)"/kernel/drivers/bluetooth/rtl_btlpm.ko ] &&
	ok "rtl_btlpm.ko present" || note "rtl_btlpm.ko not found for kernel $(uname -r)"
grep -q "^rtl_btlpm " /proc/modules 2>/dev/null && ok "rtl_btlpm loaded" || note "rtl_btlpm not loaded yet"

NET_NAME=$(cat "$DEV_CFG/network/name" 2>/dev/null || echo "")
if [ -n "$NET_NAME" ]; then
	grep -q "^$NET_NAME " /proc/modules 2>/dev/null &&
		ok "wlan module '$NET_NAME' loaded (combo chip must be powered)" ||
		no "wlan module '$NET_NAME' NOT loaded - BT will not attach"
fi

head_ "Firmware and userland"
[ -d /lib/firmware/rtlbt ] && ok "/lib/firmware/rtlbt present" || note "/lib/firmware/rtlbt missing"
command -v rtk_hciattach >/dev/null && ok "rtk_hciattach" || no "rtk_hciattach missing"
command -v bluetoothctl >/dev/null && ok "bluetoothctl" || no "bluetoothctl missing"
command -v hciconfig >/dev/null && ok "hciconfig" || note "hciconfig missing"
[ -x "$BT_DAEMON" ] && ok "bluetoothd at $BT_DAEMON" || no "bluetoothd missing - BlueZ not installed"
[ -e /usr/lib/libbluetooth.so.3 ] && ok "libbluetooth.so.3" || note "libbluetooth.so.3 missing"
[ -f /etc/dbus-1/system.d/bluetooth.conf ] && ok "D-Bus policy for BlueZ" || no "D-Bus policy missing - bluetoothd will be refused"
pgrep dbus-daemon >/dev/null 2>&1 && ok "dbus-daemon running" || no "dbus-daemon not running"

head_ "Runtime"
[ -d /sys/class/bluetooth/hci0 ] && ok "hci0 registered" || no "hci0 absent - run the bring-up hook"
if [ -d /sys/class/bluetooth/hci0 ]; then
	hciconfig hci0 2>/dev/null | grep -q "UP RUNNING" &&
		ok "hci0 UP RUNNING" || note "hci0 present but DOWN"
fi
pgrep rtk_hciattach >/dev/null 2>&1 && ok "rtk_hciattach running" || note "rtk_hciattach not running"
pgrep bluetoothd >/dev/null 2>&1 && ok "bluetoothd running" || note "bluetoothd not running"
bluetoothctl show >/dev/null 2>&1 && ok "bluetoothctl can talk to the daemon" || note "bluetoothctl cannot reach bluetoothd"

head_ "Audio path"
pgrep pipewire >/dev/null 2>&1 && ok "pipewire running" || note "pipewire not running"
pgrep wireplumber >/dev/null 2>&1 && ok "wireplumber running" || note "wireplumber not running"
[ -f /usr/lib/spa-0.2/bluez5/libspa-bluez5.so ] && ok "spa bluez5 plugin" || no "spa bluez5 plugin missing - no BT audio"
ls /usr/share/wireplumber/bluetooth.lua.d >/dev/null 2>&1 &&
	ok "wireplumber bluetooth config" || note "wireplumber bluetooth config missing"

head_ "Native muOS support (is this repo obsolete yet?)"
FLAG=$(cat "$DEV_CFG/board/bluetooth" 2>/dev/null || echo "?")
NATIVE=0
for f in /opt/muos/frontend/muxfrontend /opt/muos/frontend/lib/libmuxmod.so /opt/muos/frontend/lib/libmuxcom.so; do
	[ -f "$f" ] || continue
	strings "$f" 2>/dev/null | grep -q "muxbtdev" && NATIVE=1
done
[ -f /opt/muos/script/init/S75bluetooth.sh ] && NATIVE=$((NATIVE + 1))

if [ "$NATIVE" -ge 1 ]; then
	ok "this build HAS native Bluetooth (muxbt* modules and/or S75bluetooth.sh)"
	printf "         -> retire the user_init hook and set board/bluetooth to 1\n"
else
	note "no native Bluetooth in this build (board/bluetooth=$FLAG) - the hook is still needed"
fi

printf "\n%s ok, %s failed, %s to look at\n" "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
