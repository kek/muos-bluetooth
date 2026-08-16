# muOS Bluetooth bring-up

Turn on Bluetooth on Anbernic H700 handhelds running a muOS build that ships the
whole BlueZ stack but has no Bluetooth support wired into the frontend yet.

Nothing here installs any vendored or third-party binaries — `btui` is built
from the source in this repo, and every other piece of software involved is
already on the device. This repo is the glue muOS hasn't shipped yet.

Verified on an **RG40XX V** running **muOS 2601.1 "Funky Jacaranda"**.
Should apply to any `rg*` board with a Realtek combo chip (RG40XX H/V, the
RG35XX family, RGcube XX) on a pre-native-Bluetooth build.

## Is this for you?

Run the check first — it is read-only:

```sh
scp bin/bt-check.sh root@<device-ip>:/tmp/
ssh root@<device-ip> 'sh /tmp/bt-check.sh'
```

If the last section says *"this build HAS native Bluetooth"*, stop: use the
built-in feature instead (Settings → Connectivity → Bluetooth). If it says the
hook is still needed, carry on.

## What's already on the device, and what isn't

On a stock 2601.1 image, all of this is present, owned by the image build:

| Layer | What's there |
|---|---|
| Radio | RTL8821CS WiFi+BT combo; BT on UART1 (`uart@05000400` → `/dev/ttyS1`, status `okay`) |
| Firmware | `/lib/firmware/rtlbt/`, `rtl8821c_fw`, `rtl8821c_config` |
| Kernel | `bluetooth`, `hidp`, `rfcomm` built in; `rtl_btlpm.ko` on disk |
| BlueZ 5.72 | `bluetoothd`, `bluetoothctl`, `hciconfig`, `hcitool`, `libbluetooth.so.3` |
| D-Bus | running, with `/etc/dbus-1/system.d/bluetooth.conf` |
| Audio | PipeWire + WirePlumber running, `libspa-bluez5.so` plus sbc/opus/faststream codecs |

Missing, and that's all that's missing:

1. **Nothing brings the stack up at boot.** No `S75bluetooth.sh` in
   `/opt/muos/script/init/` (only `S00chrony S01entropy S02rgb S10udev S30dbus S99muos`).
2. **`/opt/muos/device/config/board/bluetooth` is `0`**, so the frontend hides
   its Bluetooth menu entry.
3. `bluetoothd` isn't on `PATH` — it lives in `/usr/libexec/bluetooth/`.

**Do not just flip `board/bluetooth` to `1` on such a build.** The flag gates a
menu entry whose screens are not in the binary. On 2601.1 the frontend has
`muxnetwork`, `muxconnect`, `muxdevice` and `muxtweakadv` but **zero** hits for
`muxbtall` / `muxbtcon` / `muxbtdev`. You would unhide a dead end.

## Install

```sh
./install.sh root@<device-ip>
```

That copies `init/10-bluetooth.sh` to `/mnt/mmc/MUOS/init/`, the helpers to
`/mnt/mmc/MUOS/bluetooth/`, the `btui` app to `/mnt/mmc/MUOS/application/Bluetooth/`,
and sets `user_init` to `1`. Reboot afterwards.

Doing it by hand is the same three steps:

1. Copy `init/10-bluetooth.sh` to `/mnt/mmc/MUOS/init/10-bluetooth.sh`.
   `user_init.sh` globs `$MUOS_STORE_DIR/init/*.sh` (that path is
   `/run/muos/storage/init`, the same exfat directory as `/mnt/mmc/MUOS/init`)
   and runs each with `sh "$SCRIPT" &` — so **no exec bit is needed** and a hang
   can't block boot. The numeric prefix only fixes glob order.
2. Enable the hook: **Advanced Settings → User Init Scripts**, or
   `printf 1 > /opt/muos/config/settings/advanced/user_init`
   (muOS config files are bare values with no trailing newline — use `printf`, not `echo`).
3. Reboot.

### Testing without installing

The hook is idempotent and safe to run by hand:

```sh
ssh root@<device-ip> 'sh /mnt/mmc/MUOS/init/10-bluetooth.sh; tail -20 /mnt/mmc/MUOS/log/bluetooth.log'
```

### `btui` development builds

Building `btui` at all (rather than just installing an already-built one)
needs `make sysroot && make build` on a machine with the Homebrew SDL2/dbus
headers (`brew install sdl2 sdl2_ttf dbus`) — `make sysroot` pulls the
device's own `.so` files over SSH as the link-time ABI reference (see
`build.zig`), and `make build` cross-compiles against them. A bare `zig
build` with no `-Dtarget` fails on a Mac: the pulled `.so` files are aarch64
stubs a native-target build can't parse as valid libraries.

The Zig Bluetooth UI (`src/`, `Makefile`) also reaches the device over SSH —
`make sysroot` / `make deploy` / `make run`. Every one of those checks
`/etc/os-release` for `MustardOS` before touching anything (`check-device` in
the `Makefile`), because a Nerves/Elixir device answered the handheld's IP
for an unknown window during development. Before this check existed, `deploy`
would have written the built binary to that stranger with no complaint, and
`sysroot` would have filled the build's link-time ABI reference with its
libraries instead of the handheld's. If a device-facing `make` target aborts
with "does not look like muOS," `$(DEVICE)` is pointing at the wrong box —
fix that before retrying, don't bypass the check.

## The `btui` app

Once installed, `btui` also shows up in muOS's **Applications** menu (icon:
Bluetooth) as a handheld alternative to the SSH workflow above. It talks to
the same BlueZ/PipeWire stack the hook brings up, so the app and the shell
helpers can be used interchangeably — the app doesn't replace the hook, it
just gives you a menu-driven front end for the parts of the shell helpers
that are otherwise SSH-only (scanning, pairing, connect/disconnect/forget,
and choosing the audio sink).

**`btui` does not bring the Bluetooth stack up by itself.** It only calls
`Adapter1.Powered = true` on launch (best-effort) - if `bluetoothd` isn't on
the bus at all (radio never attached, daemon never started), the Devices tab
just fails every action with that reason rather than running the bring-up
sequence itself. Make sure the boot hook has run (or bring the stack up by
hand - see [Testing without installing](#testing-without-installing)) before
opening the app.

There are two tabs, switched with `L1`/`R1`:

| Tab | Purpose |
|---|---|
| Devices | Scan, pair, connect, disconnect, forget |
| Audio | See and pick the active PipeWire sink |

Controls:

| Button | Action |
|---|---|
| D-pad up/down | Move selection |
| `A` | Devices: connect (or pair, then connect, if not yet paired). Audio: set the selected sink as default |
| `B` | Quit `btui`, back to muOS (during a pair/connect: cancel it instead) |
| `X` | Forget the selected device (Devices tab only) — press again within ~3s to confirm; anything else cancels it |
| `Y` | Start/stop a scan (Devices tab only) |
| `L1` / `R1` | Switch tab |

**Security note, read this before leaving it running unattended.** While
`btui` is open it registers a `NoInputNoOutput` BlueZ pairing agent, and that
agent auto-accepts `RequestConfirmation` and `AuthorizeService` for *any*
initiator — not just a device you're actively trying to pair. In practice
this means that for as long as the app is on screen, anything within radio
range can pair with the handheld with no prompt and no confirmation, and
have every service it asks for authorized. This is intentional: it is what
lets pairing work at all from the handheld's own screen without an `expect`
script driving `bluetoothctl` (the approach bltMuos takes — see
[Why not bltMuos?](#why-not-bltmuos)). The tradeoff is that `btui` should be
treated like any other "discoverable and pairable" state — open it to pair
what you mean to pair, then back out with `B` rather than leaving it running
in the background.

**Typeface.** No muOS theme ships a TrueType font — the theme's own font
files are LVGL's binary `.bin` format, which `SDL_ttf` cannot load. `btui`
looks for a `.ttf` under the active theme's font directory anyway, but on
every theme currently shipping it falls through to a system font that's
already on the device — Inconsolata, the copy muOS's own PPSSPP install
carries — rather than anything this repo installs. Its colour palette is
also its own — a fixed dark background with the MustardOS yellow accent —
not read from the active theme's colour scheme. So don't expect `btui` to
match a given theme's look beyond coincidence; it has a look of its own.

**Testing over SSH: the frontend-suspend gotcha.** If you drive `btui` over
SSH while it's meant to be the foreground app, the usual `killall -STOP
muxfrontend` trick to freeze muOS's frontend often silently does nothing.
muOS renames the frontend process per screen (`{muxlaunch}` on the main
menu, `{muxapp}` on the app list, etc.) even though the binary on disk is
still `/opt/muos/frontend/muxfrontend` — `killall` matches by the process's
current name, not its path, so it misses. When that happens the frontend
keeps both the display and the input, so your keypresses land on muOS's menu
instead of the app you're testing, and nothing about `btui` looks broken
because it never got the input in the first place. The reliable form
matches by path instead of name:

```sh
FPID=$(pgrep -f "/opt/muos/frontend/muxfrontend" | head -1)
kill -STOP "$FPID"
# ... drive/observe btui ...
kill -CONT "$FPID"
```

This cost two wasted test sessions before the cause was found — worth
knowing before you conclude the app itself is unresponsive.

## Pairing

```sh
ssh root@<device-ip>
sh /mnt/mmc/MUOS/bluetooth/bt-pair.sh scan
sh /mnt/mmc/MUOS/bluetooth/bt-pair.sh AA:BB:CC:DD:EE:FF
```

Or by hand, which is worth knowing:

```
bluetoothctl
  agent on
  default-agent
  scan on            # note the MAC, then:
  scan off
  pair  AA:BB:CC:DD:EE:FF
  trust AA:BB:CC:DD:EE:FF
  connect AA:BB:CC:DD:EE:FF
```

`trust` is what lets the device reconnect on its own afterwards. Keys are stored
under `/var/lib/bluetooth/<controller-mac>/` on the **ext4 rootfs**, so pairings
survive reboots. Most gamepads and headsets use just-works SSP, so no pairing
confirmation is needed; if one does prompt, `agent on` in an interactive
`bluetoothctl` answers it.

## Audio

**Connecting a headset is not enough to hear anything.** WirePlumber creates a
working sink for it, but muOS keeps the *default* sink on the internal card — it
has no idea Bluetooth exists on these builds — so audio keeps going to the
speaker while a perfectly healthy Bluetooth sink sits idle. The symptom is
"connected, no sound":

```
Sinks:   33. Built-in Audio Stereo   [vol: 0.40]
      *  34. Built-in Audio Stereo   [vol: 0.00]   <- default, and silent
         49. LE-Constantin           [vol: 0.24]   <- your headset, unused
Streams: retroarch -> Stereo:playback_FL/FR        <- pinned to the built-in
```

The bring-up hook now handles this at boot: it reconnects paired devices and
points the default sink at the Bluetooth one. For anything that connects later,
or to switch back and forth:

```sh
sh /mnt/mmc/MUOS/bluetooth/bt-audio.sh            # what is default right now
sh /mnt/mmc/MUOS/bluetooth/bt-audio.sh use 0.6    # default -> Bluetooth, volume 0.6
sh /mnt/mmc/MUOS/bluetooth/bt-audio.sh internal   # default -> built-in speaker
```

Changing the default also moves streams that are already playing, so you don't
have to restart the emulator.

If you ever need to route by hand, note which object you're addressing:

| Command | Target | Decides |
|---|---|---|
| `wpctl set-profile <device-id> <idx>` | the bluez5 **card** (`device.api = bluez5`) | *which nodes exist* — A2DP (stereo, no mic) vs HSP/HFP (mono + mic) |
| `wpctl set-default <sink-id>` | the **sink node** (`media.class = Audio/Sink`) | *which existing sink plays* |

`set-default` only takes a node — passing it the card id is a category error.
The sink lists its parent as `device.id`, so the two are easy to tell apart in
`wpctl inspect`. Node IDs change on every reconnect, so never hardcode them.

Caveat: muOS's own volume control targets the internal card
(`/opt/muos/device/config/audio/*`), so the hardware volume keys may not follow a
Bluetooth sink. Likewise nothing in a pre-native build knows a Bluetooth
*controller* exists — RetroArch has autoconfigs for several and SDL will
enumerate it, but the frontend's input mapping is built around the internal pad.
Those two gaps are exactly what the native feature fixes.

## Troubleshooting

**Connected, but no sound.** The default sink is still the internal card — see
[Audio](#audio). `bt-audio.sh use` fixes it.

**No Bluetooth sink exists at all.** Then nothing is actually connected, whatever
the headset's own indicator says. `bluetoothctl devices Connected` is the truth.
Paired is not connected: after a cold boot the handheld has to *initiate* the
reconnect, which is what the hook's autoconnect step does.

**The tools report nothing / every sink looks missing.** `wpctl` and `pw-dump`
need `PIPEWIRE_RUNTIME_DIR` and `XDG_RUNTIME_DIR`, which muOS exports from
`script/var/func.sh`. Run them over a plain `ssh device 'command'` without those
and PipeWire looks empty rather than erroring. The scripts here set both
defensively; if you poke at PipeWire by hand, use `ssh device` interactively or
prefix `XDG_RUNTIME_DIR=/run PIPEWIRE_RUNTIME_DIR=/run`.

**Audio breaks up during play.** muOS allows a quantum up to 2048
(`default.clock.max-quantum` in its `pipewire.conf`) and the bluez sink takes the
maximum, so the A2DP transport gets one ~46 ms burst per period. Bluetooth and
WiFi share a single 2.4 GHz front end on these Realtek combo chips, and a burst
that big is much likelier to miss its transmission window than four small ones.
The hook and `bt-audio.sh use` therefore force the quantum down:

```sh
pw-metadata -n settings 0 clock.force-quantum 512   # what we set
pw-metadata -n settings 0 clock.force-quantum 0     # back to muOS's default
```

Measured on an RG40XX V with a Bose NC 700: SNES emulation broke up
intermittently at 2048, was clean at 512, and broke up again on switching back
to 2048 — a reversal test, not a single observation. `pw-top` reported `ERR 0`
(no xruns) in *every* case, so the dropouts were on the radio link, not in the
audio pipeline. Latency improved only marginally; stability was the win.
Set `BT_QUANTUM=0` to opt out, or raise it if emulators start crackling.

**Check the hook actually ran.** `tail /mnt/mmc/MUOS/log/bluetooth.log`. It is
idempotent, so you can re-run it any time:
`sh /mnt/mmc/MUOS/init/10-bluetooth.sh`.

## Verify

```sh
ssh root@<device-ip> 'tail -20 /mnt/mmc/MUOS/log/bluetooth.log'
ssh root@<device-ip> 'sh /mnt/mmc/MUOS/bluetooth/bt-check.sh'
```

## Undo

```sh
ssh root@<device-ip> 'rm -f /mnt/mmc/MUOS/init/10-bluetooth.sh'
ssh root@<device-ip> 'printf 0 > /opt/muos/config/settings/advanced/user_init'
# optional, drops all pairings:
ssh root@<device-ip> 'rm -rf /var/lib/bluetooth/*'
```

## When this becomes obsolete

muOS is actively building native Bluetooth. First commit **2026-05-20**,
"Added preliminary BT module support":

- `MustardOS/frontend` — `module/muxbtall.c`, `module/muxbtcon.c`,
  `module/muxbtdev.c`, `common/bluetooth.c` (~1,770 lines together)
- `MustardOS/internal` — `script/init/S75bluetooth.sh`, `script/mux/bt_device.sh`,
  `script/mux/bt_monitor.sh`, `script/mux/bt_diag.sh`

Commit `1b9b9f44` (2026-05-22) already flipped
`device/rg40xx-v/config/board/bluetooth` and the `rg40xx-h` one from `0` to `1`.
As of August 2026 it is still unreleased — 2601.1 remains the current stable
build — and still churning (scan strategy was reverted a day after landing).

When a release ships with it, `bin/bt-check.sh` will tell you, and you should
remove the hook rather than run both.

## Why not bltMuos?

[bltMuos](https://github.com/nvcuong1312/bltMuos) is the popular option and it
works, but on this device its ~17 MB of vendored aarch64 binaries — BlueZ,
`expect`, the PipeWire bluez5 codecs, an OpenSSL 1.1.1f from Ubuntu 20.04 — are
all redundant: newer copies are already in the muOS image. Its installer also
pulls an unpinned `main.zip` at install time and runs it as root at every boot.
This repo takes the opposite approach: no vendored or third-party binaries —
`btui` is built from the source here, everything else is already there.

## Deviations from the design spec

Fix round 2, finding M14 — recorded here as explicit, intentional gaps
against `docs/superpowers/specs/2026-08-16-bluetooth-ui-design.md` rather
than left silently dropped:

- **No clock/battery in the header.** The spec's header called for "title,
  adapter state, clock/battery", matching muOS's own screens. `btui`'s header
  is just the title and a state line (`Ready`/`Scanning...`/etc.).
- **No `bluez.onChange` signal matching.** The spec called for a
  `PropertiesChanged`/`InterfacesAdded`/`InterfacesRemoved` D-Bus signal
  matcher so the device list updates live during a scan. `btui` instead polls
  `bluez.list()` on a fixed interval while scanning (`scan_refresh_ms`) -
  works, but isn't event-driven, and adds up to that interval's worth of
  latency before a newly-discovered device shows up.
- **No `Device.rssi`.** The spec's `Device` struct includes signal strength;
  it isn't read, stored, or shown anywhere in this implementation.
- **No vendored `third_party/` headers.** The spec called for the SDL2/dbus
  headers to be vendored under `third_party/` so builds are reproducible.
  `build.zig` instead points at hardcoded Homebrew include paths
  (`/opt/homebrew/include` etc.), so a build only works on a machine with
  those installed at those paths - see [`btui` development
  builds](#btui-development-builds).
- **No photo in this README.** The spec's testing section called for a photo
  of the UI running on hardware. None is included - interactive on-device
  verification of the finished UI is still pending as of this writing (the
  dev machine's network access to the handheld has been intermittent; see
  the task reports under `.superpowers/sdd/2026-08-16-bluetooth-ui/` for the
  current state of hardware verification).

## Credits

`init/10-bluetooth.sh` is derived from
[MustardOS/internal](https://github.com/MustardOS/internal)
`script/init/S75bluetooth.sh` (GPL-3.0) — the `rg*` attach sequence, the readiness
waits and the pidfile handling are theirs. `bin/bt-check.sh` is modelled on their
`script/mux/bt_diag.sh`. Licensed GPL-3.0 to match.
