# Bluetooth UI for muOS — design

Status: approved for planning
Date: 2026-08-16
Repo: `muos-bluetooth`

## Problem

The repo currently manages Bluetooth through shell helpers driven over SSH. That
works, but it is unusable from the handheld itself: pairing a new headset means
finding a computer. muOS builds before the native Bluetooth feature (2601.1 and
earlier) ship no UI for this at all.

We want an on-device app, in the style of muOS's own screens, that can scan,
pair, connect, forget, and choose the audio output.

## Goals

1. Scan for nearby Bluetooth devices.
2. Pair a device, including confirmation-type pairing, without an `expect` hack.
3. Connect and disconnect known devices.
4. Remove (forget) a device.
5. Select which audio sink plays — Bluetooth or internal — and route
   automatically when an audio device connects.
6. Ship no third-party binaries. Everything links against libraries already
   present in the muOS image.

## Non-goals (v1)

Device renaming, showing a *connected device's* battery level, per-device
volume, a settings screen, HFP/mic profile switching, and anything for non-audio
device classes beyond generic connect/disconnect. (The handheld's own battery
does appear in the header, as it does on muOS's own screens.)

## Constraints, established by measurement

Verified on an RG40XX V running muOS 2601.1:

| Fact | Value |
|---|---|
| Architecture / libc | aarch64, glibc 2.38 (Buildroot) |
| SDL2 | 2.28.5, plus `SDL2_ttf`, `SDL2_image`, `SDL2_mixer`, `SDL2_gfx` |
| SDL video drivers | exactly one: `mali` |
| Framebuffer | 640x480 visible, 640x960 virtual (double-buffered), 32 bpp |
| D-Bus | `libdbus-1.so.3` (3.32.4), system bus at `/run/dbus/system_bus_socket` |
| `bluetoothctl` links | `libdbus-1` — so libdbus *is* "the same method" |
| Toolchain | Zig 0.16.0 on the dev machine; **no compiler on the device** |

Two toolchain wrinkles, both already solved in a spike:

- `@cImport` of `SDL.h` fails because Zig 0.16's bundled clang headers cannot
  parse the newer NEON `mfloat8_t` types. Fix: `@cDefine("SDL_DISABLE_ARM_NEON_H", "1")`.
- `DBusError` contains bitfields, so translate-c renders it opaque and Zig
  refuses to allocate one. Fix: mirror its layout as an `extern struct`
  (`name`, `message`, `bits: c_uint`, `padding1` — 32 bytes) and pass a
  `@ptrCast` pointer to libdbus.

Linking against `.so` files pulled from the device gives a useful safety
property: any call newer than the device's library versions fails at **link
time** on the dev machine rather than at runtime on the handheld.

## Architecture

Six modules. Only `dbus.zig` touches C for Bluetooth; only `audio.zig` shells out.

### `src/dbus.zig` — libdbus wrapper

The single place that knows about C interop for D-Bus.

- `connectSystem() !Connection`
- `call(dest, path, iface, method, args) !Reply` — blocking, for calls that
  return promptly (property reads, `GetManagedObjects`, `StartDiscovery`)
- `callAsync(...) !PendingCall` — `dbus_connection_send_with_reply`, completed
  on the pump. Used for `Pair` and `Connect`, which can take many seconds
- variant readers: `readString`, `readBool`, `readU16` over `DBusMessageIter`
- `pump(timeout_ms)` — non-blocking `dbus_connection_read_write_dispatch`
- `exportObject(path, handler)` — for the pairing agent
- `DBusError` layout workaround, and `Error` translation into Zig errors

Depends on: libdbus. Knows nothing about BlueZ.

### `src/bluez.zig` — Bluetooth domain

- `Device`: `path`, `address`, `alias`, `icon`, `paired`, `trusted`,
  `connected`, `rssi`
- `list() ![]Device` — `ObjectManager.GetManagedObjects` on `org.bluez`,
  filtered to `org.bluez.Device1`
- `startScan()` / `stopScan()` — `Adapter1.StartDiscovery` / `StopDiscovery`
- `pair(dev)`, `connect(dev)`, `disconnect(dev)`, `forget(dev)` —
  `Device1.Pair` / `Connect` / `Disconnect`, `Adapter1.RemoveDevice`
- `setTrusted(dev, bool)` — set after successful pair, so the device
  reconnects on its own
- `powerOn()` — `Adapter1.Powered = true`
- `registerAgent()` — exports `org.bluez.Agent1` at `/muos/btui/agent` with
  capability `NoInputNoOutput`, then `AgentManager1.RegisterAgent` +
  `RequestDefaultAgent`. Auto-accepts `RequestConfirmation`,
  `RequestAuthorization` and `AuthorizeService`; returns `Rejected` for
  anything needing real input.
- `onChange(callback)` — matches on `InterfacesAdded`, `InterfacesRemoved`
  and `PropertiesChanged` so the list updates live during a scan

`Pair` and `Connect` are issued through `callAsync` and completed on the pump,
so the frame loop keeps rendering and the modal stays animated while BlueZ works.
Nothing in the UI thread ever blocks on a long call.

### `src/audio.zig` — PipeWire

PipeWire exposes no D-Bus interface, so this module uses its CLI tools — but
reads state as **JSON**, not scraped text.

- `sinks() ![]Sink` — runs `pw-dump`, parses with `std.json`, filters nodes
  with `media.class == "Audio/Sink"`, marking which is default
- `setDefault(sink)` — `wpctl set-default <id>`
- `setVolume(sink, f32)` — `wpctl set-volume`
- `forceQuantum(n)` — `pw-metadata -n settings 0 clock.force-quantum <n>`,
  applied as 512 when a Bluetooth sink becomes default and 0 when an internal
  sink does, matching `bin/bt-audio.sh`
- exports `XDG_RUNTIME_DIR` / `PIPEWIRE_RUNTIME_DIR` defaults before every
  invocation — without them the PipeWire tools report an empty graph rather
  than failing

### `src/theme.zig` — muOS look

Reads the active theme under `/run/muos/storage/theme/active/`: colour scheme,
TTF font, and glyphs. Every value has a built-in fallback so a missing or
unfamiliar theme degrades to a readable default rather than crashing. The exact
scheme file format is read from the device during implementation rather than
assumed.

### `src/ui.zig` — rendering

SDL2 render loop at 640x480: header (title, adapter state, clock/battery),
scrolling list with selection highlight and per-row status glyph, footer hint
bar, and a modal overlay for progress, confirmation and errors. Input via SDL's
joystick API — `muOS-Keys` enumerates as a joystick, so no `gptokeyb`
dependency — with keyboard fallback for development.

### `src/main.zig` — state machine

Tabs: `Devices` and `Audio`, switched with `L1`/`R1`.

```
Devices:  A connect/disconnect   X forget   Y scan on/off   B exit
Audio:    A set as output        B exit
```

States: `List → Scanning → Working(op) → List`, with `Error(msg)` reachable from
any operation and dismissed with `A`/`B`.

On launch: if `hci0` is absent, run the same bring-up sequence as
`init/10-bluetooth.sh` (module, `rtk_hciattach`, `bluetoothd`) so the app works
even when the boot hook is disabled. Then `powerOn()` and `registerAgent()`.

Connecting a device whose `icon` is audio-ish triggers `audio.setDefault()` on
the new sink once it appears, plus `forceQuantum(512)`.

## Error handling

- Every D-Bus call returns a Zig error carrying BlueZ's own message
  (`org.bluez.Error.AlreadyExists`, `AuthenticationFailed`, …), shown in the
  modal verbatim. BlueZ's messages are already user-legible.
- `br-connection-busy` / `InProgress` is treated as transient: the UI keeps the
  modal and retries once after a short delay rather than reporting failure.
- If `bluetoothd` is not on the bus, the app says so and offers to run bring-up
  rather than showing an empty list.
- PipeWire absence degrades the Audio tab to a message; the Devices tab still
  works.

## Testing

- `btui --dump` — headless mode printing devices and sinks as text. Lets
  `bluez.zig` and `audio.zig` be verified over SSH on real hardware without the
  UI, and is the main development feedback loop.
- Unit tests on the dev machine for `audio.zig`'s JSON parsing against captured
  `pw-dump` output, and for `theme.zig`'s scheme parsing against a captured
  theme. These run under `zig build test` on the Mac, no device needed.
- `dbus.zig` and `bluez.zig` are verified against the live bus via `--dump`;
  mocking libdbus is not worth the scaffolding for v1.
- UI verified manually on hardware; a photo goes in the README.

## Build and packaging

- `zig build -Dtarget=aarch64-linux-gnu.2.38 -Doptimize=ReleaseSmall`
- `make sysroot` pulls `libSDL2*`, `libSDL2_ttf`, `libSDL2_image` and
  `libdbus-1` from a device over SSH into `sysroot/`. Headers for SDL2 2.28.5
  and dbus are vendored under `third_party/` so builds are reproducible; no
  binaries are committed.
- Output: a single `btui` executable, ~50–100 KB, dynamically linked against
  libraries already on the device.
- Installed to `/mnt/mmc/MUOS/application/Bluetooth/` with a `mux_launch.sh`
  carrying `# HELP:` and `# ICON:` headers so it appears in muOS's Applications
  menu. The launch convention is copied from a stock muOS app on the device
  rather than invented.
- `install.sh` gains a step for the app; the existing hook and shell helpers
  stay, since they serve the headless/SSH workflow and the boot path.

## Risks

| Risk | Mitigation |
|---|---|
| SDL window creation under the `mali` driver may need specific flags while muOS's frontend is suspended | Establish early with a minimal window spike before building the UI; `mux_launch.sh` suspends the frontend the same way other muOS apps do |
| Theme scheme format is undocumented | Read the actual files on device; fall back to built-in colours on any parse failure |
| Pairing agent complexity in raw libdbus | Scope is four auto-accept methods; `NoInputNoOutput` needs no user input path |
| muOS ships native Bluetooth and this becomes redundant | `bin/bt-check.sh` already detects that; the README will say to prefer native when it lands |

## Relationship to existing work

The shell helpers stay as-is. The app is an addition, not a replacement: the
hook still brings Bluetooth up at boot and reconnects known devices without any
UI, which is what makes headphones work on a cold boot before you ever open an
app.
