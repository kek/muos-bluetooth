#!/bin/sh
# HELP: Manage Bluetooth devices and audio output
# ICON: bluetooth
# GRID: Bluetooth

. /opt/muos/script/var/func.sh

APP_BIN="btui"
SETUP_APP "$APP_BIN" ""

# -----------------------------------------------------------------------------

cd "$HOME" || exit

exec /mnt/mmc/MUOS/application/Bluetooth/bin/btui
