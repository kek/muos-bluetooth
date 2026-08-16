#!/bin/sh
# HELP: Manage Bluetooth devices and audio output
# ICON: bluetooth
# GRID: Bluetooth

. /opt/muos/script/var/func.sh

APP_BIN="btui"
SETUP_APP "$APP_BIN" ""

# -----------------------------------------------------------------------------

cd "$HOME" || exit

# Fix round 2, finding I4: nothing upstream of this script (SETUP_APP,
# SETUP_SDL_ENVIRONMENT) redirects btui's stdout or stderr anywhere - unlike
# SETUP_APP's own SDL apps, which redirect around their own binary invocation
# (see e.g. the reference 2048 Plus launcher's `> "$LOG_FILE" 2>&1`), a
# muOS-launched btui's diagnostics - both stdout (the agent-callback logging
# bluez.zig flushes explicitly) and stderr (SDL/TTF failures from ui.zig's
# std.debug.print) - would otherwise go nowhere at all, not just get
# buffered. Same log directory (and the same /tmp fallback) as the bring-up
# hook's own log, but its own file, since this app doesn't replace the hook.
LOG=/mnt/mmc/MUOS/log/btui.log
[ -d "$(dirname "$LOG")" ] || LOG=/tmp/btui.log

exec /mnt/mmc/MUOS/application/Bluetooth/bin/btui >>"$LOG" 2>&1
