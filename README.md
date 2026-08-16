# muOS Bluetooth bring-up

Turn on Bluetooth on Anbernic H700 handhelds running a muOS build that ships the
whole BlueZ stack but has no Bluetooth support wired into the frontend yet.

Nothing here installs any binaries. Every piece of software involved is already
on the device — this repo is the ~90 lines of glue muOS hasn't shipped yet.

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
`/mnt/mmc/MUOS/bluetooth/`, and sets `user_init` to `1`. Reboot afterwards.

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
This repo takes the opposite approach: no binaries, use what's already there.

## Credits

`init/10-bluetooth.sh` is derived from
[MustardOS/internal](https://github.com/MustardOS/internal)
`script/init/S75bluetooth.sh` (GPL-3.0) — the `rg*` attach sequence, the readiness
waits and the pidfile handling are theirs. `bin/bt-check.sh` is modelled on their
`script/mux/bt_diag.sh`. Licensed GPL-3.0 to match.
