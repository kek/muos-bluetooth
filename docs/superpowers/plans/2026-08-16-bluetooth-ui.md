# Bluetooth UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An on-device muOS app (`btui`) to scan, pair, connect and forget Bluetooth devices, and to choose the audio output sink.

**Architecture:** A single Zig executable cross-compiled to aarch64. Bluetooth is driven over D-Bus via `libdbus-1` — the same library `bluetoothctl` links — so there is no shelling out and no output parsing. Audio uses PipeWire's CLI tools through libc `popen`, reading state as JSON. Rendering uses the SDL2 already present in the muOS image. Nothing third-party is committed or installed.

**Tech Stack:** Zig 0.16.0, libdbus-1 3.32.4, SDL2 2.28.5 (+ SDL2_ttf, SDL2_image), PipeWire tools (`pw-dump`, `wpctl`, `pw-metadata`), BlueZ 5.72.

**Spec:** `docs/superpowers/specs/2026-08-16-bluetooth-ui-design.md`

## Global Constraints

Every task inherits these. All values were verified on an RG40XX V running muOS 2601.1.

- **Build target:** `aarch64-linux-gnu.2.38`. The device is aarch64 with glibc 2.38 (Buildroot).
- **Screen:** 640x480 visible, 32 bpp. SDL2 offers exactly **one** video driver: `mali`.
- **SDL headers:** `@cImport` of `SDL.h` MUST include `@cDefine("SDL_DISABLE_ARM_NEON_H", "1")` first. Without it Zig 0.16's bundled clang headers fail to parse the NEON `mfloat8_t` types and the import dies with "C import failed".
- **System libraries:** always `linkSystemLibrary(name, .{ .use_pkg_config = .no })`. With pkg-config enabled, the host's Homebrew `libSDL2main.a` leaks into the cross link and LLD errors with "neither ET_REL nor LLVM bitcode".
- **libc:** set `.link_libc = true` on the *module* in `createModule`. `exe.linkLibC()` does not exist in Zig 0.16.
- **`DBusError` is opaque** to translate-c because it contains bitfields. Never declare `var err: c.DBusError`. Use the `dbus.Error` extern struct from Task 2.
- **Zig 0.16 API notes** (these differ from every pre-0.16 example online):
  - `std.ArrayList` is unmanaged: `var l: std.ArrayList(T) = .empty;`, `try l.append(gpa, x)`, `l.deinit(gpa)`.
  - `std.fs.cwd()` and `std.posix.write` do not exist. File reads are `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))` where `io` comes from `var t: std.Io.Threaded = .init(gpa, .{}); const io = t.io();`.
  - `std.process.Child` has no `run`/`spawn`. **Use libc `popen`/`fgets`/`pclose`** for subprocesses. We link libc anyway.
  - `std.json.parseFromSlice` works as documented.
- **No committed binaries.** `sysroot/` and `third_party/` are gitignored and produced by `make`.
- **Licence:** repo is GPL-3.0. Each new source file opens with a one-line comment stating its responsibility.
- **muOS paths:** app installs to `/mnt/mmc/MUOS/application/Bluetooth/`; active theme name is in `/opt/muos/config/theme/active`; themes live at `/run/muos/storage/theme/<name>/`.
- **Device access:** `ssh root@<device-ip>`. `scp` is unreliable here; copy with `ssh root@<ip> 'cat > /path' < file`.

---

## File Structure

| File | Responsibility |
|---|---|
| `build.zig` | Cross-compile + host test steps |
| `Makefile` | `sysroot` (pull `.so` from device), `deploy`, `run` |
| `src/main.zig` | CLI entry, mode dispatch (`--dump`, `--version`, UI), tab state machine |
| `src/dbus.zig` | libdbus wrapper: connection, calls, variant readers, pump, exported objects. Only file with D-Bus C interop |
| `src/bluez.zig` | BlueZ domain: device list, scan, pair/connect/forget, agent |
| `src/audio.zig` | PipeWire: sink list via `pw-dump` JSON, set default, force quantum |
| `src/theme.zig` | Active theme font/glyph lookup + palette |
| `src/ui.zig` | SDL2 window, text, list rendering, input |
| `package/mux_launch.sh` | muOS app launcher |
| `tests/fixtures/pw-dump.json` | Captured PipeWire state for host tests |

---

### Task 1: Build scaffolding that produces a running device binary

**Files:**
- Create: `build.zig`, `Makefile`, `.gitignore` (modify), `src/main.zig`

**Interfaces:**
- Consumes: nothing
- Produces: `zig build -Dtarget=aarch64-linux-gnu.2.38 -Doptimize=ReleaseSmall` → `zig-out/bin/btui`; `zig build test` runs host unit tests

- [ ] **Step 1: Create `build.zig`**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Headers come from the host; the ABI comes from sysroot/, which holds the
    // device's own .so files. Anything newer than the device's libraries then
    // fails at link time here rather than at runtime on the handheld.
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/dbus-1.0" });
    mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/lib/dbus-1.0/include" });
    mod.addLibraryPath(b.path("sysroot"));
    mod.linkSystemLibrary("SDL2", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("SDL2_ttf", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("SDL2_image", .{ .use_pkg_config = .no });
    mod.linkSystemLibrary("dbus-1", .{ .use_pkg_config = .no });

    const exe = b.addExecutable(.{ .name = "btui", .root_module = mod });
    b.installArtifact(exe);

    // Host tests: pure parsing only, no device libraries.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "Run host unit tests").dependOn(&b.addRunArtifact(tests).step);
}
```

- [ ] **Step 2: Create `src/main.zig`**

```zig
// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("dbus/dbus.h");
    @cInclude("stdio.h");
});

pub const version = "0.1.0";

pub fn main() void {
    var sdl: c.SDL_version = undefined;
    c.SDL_GetVersion(&sdl);
    _ = c.printf("btui %s (SDL %d.%d.%d)\n", version.ptr, sdl.major, sdl.minor, sdl.patch);
}
```

- [ ] **Step 3: Create `src/test_all.zig`**

Host tests aggregate here. It must compile before `audio.zig` and `theme.zig`
exist, so it starts with only a self-check; Tasks 5 and 6 add their imports.

```zig
// Aggregates host-runnable unit tests. Modules that touch SDL or D-Bus are
// deliberately absent: those are verified on hardware via --dump.
const std = @import("std");

test "test harness runs" {
    try std.testing.expect(true);
}
```

- [ ] **Step 4: Create `Makefile`**

```makefile
DEVICE ?= root@192.168.100.180
TARGET := aarch64-linux-gnu.2.38

.PHONY: build sysroot deploy run clean

build:
	zig build -Dtarget=$(TARGET) -Doptimize=ReleaseSmall

# The device's own libraries are the link-time ABI reference. Not committed.
sysroot:
	mkdir -p sysroot
	for f in libSDL2-2.0.so.0 libSDL2_ttf-2.0.so.0 libSDL2_image-2.0.so.0 libdbus-1.so.3; do \
		ssh $(DEVICE) "cat /usr/lib/$$f" > sysroot/$$f; \
	done
	cd sysroot && ln -sf libSDL2-2.0.so.0 libSDL2.so \
		&& ln -sf libSDL2_ttf-2.0.so.0 libSDL2_ttf.so \
		&& ln -sf libSDL2_image-2.0.so.0 libSDL2_image.so \
		&& ln -sf libdbus-1.so.3 libdbus-1.so

deploy: build
	ssh $(DEVICE) 'mkdir -p /mnt/mmc/MUOS/application/Bluetooth/bin'
	ssh $(DEVICE) 'cat > /mnt/mmc/MUOS/application/Bluetooth/bin/btui && chmod +x /mnt/mmc/MUOS/application/Bluetooth/bin/btui' < zig-out/bin/btui

run: deploy
	ssh $(DEVICE) '/mnt/mmc/MUOS/application/Bluetooth/bin/btui --dump'

clean:
	rm -rf zig-out .zig-cache
```

- [ ] **Step 5: Add to `.gitignore`**

```
sysroot/
third_party/
zig-out/
.zig-cache/
```

- [ ] **Step 6: Populate sysroot and build**

Run: `make sysroot && make build`
Expected: `zig-out/bin/btui` exists; `file zig-out/bin/btui` reports `ELF 64-bit LSB executable, ARM aarch64 ... dynamically linked`.

- [ ] **Step 7: Verify it runs on the device**

Run: `make deploy && ssh root@<ip> '/mnt/mmc/MUOS/application/Bluetooth/bin/btui'`
Expected: `btui 0.1.0 (SDL 2.28.5)`

- [ ] **Step 8: Commit**

```bash
git add build.zig Makefile .gitignore src/main.zig
git commit -m "Cross-compiled Zig skeleton that runs on the handheld"
```

---

### Task 2: D-Bus wrapper

**Files:**
- Create: `src/dbus.zig`
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: Task 1 build
- Produces:
  - `dbus.Error` — extern struct, `.ptr()` → `*c.DBusError`, `.text()` → `[*c]const u8`
  - `dbus.Connection = struct { handle: ?*c.DBusConnection }`
  - `dbus.connectSystem(err: *Error) DBusFailure!Connection`
  - `Connection.call(dest, path, iface, method, err: *Error) DBusFailure!*c.DBusMessage`
  - `dbus.iterString(it: *c.DBusMessageIter) [*c]const u8`
  - `dbus.iterBool(it: *c.DBusMessageIter) bool`
  - `Connection.pump() void`

- [ ] **Step 1: Write `src/dbus.zig`**

```zig
// Thin wrapper over libdbus-1 - the same library bluetoothctl uses.
// This is the only file that knows about D-Bus C interop.
const std = @import("std");
pub const c = @cImport({
    @cInclude("dbus/dbus.h");
});

/// dbus.h's DBusError contains bitfields, so translate-c renders it opaque and
/// Zig cannot allocate one. Mirror the layout: two pointers, a flags word, and
/// a padding pointer = 32 bytes on 64-bit.
pub const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    bits: c_uint = 0,
    padding1: ?*anyopaque = null,

    pub fn ptr(self: *Error) *c.DBusError {
        return @ptrCast(self);
    }
    pub fn text(self: *Error) [*c]const u8 {
        return if (self.message) |m| m else "(no detail)";
    }
};

pub const DBusFailure = error{ ConnectFailed, CallFailed };

pub const Connection = struct {
    handle: ?*c.DBusConnection,

    pub fn call(
        self: Connection,
        dest: [*c]const u8,
        path: [*c]const u8,
        iface: [*c]const u8,
        method: [*c]const u8,
        err: *Error,
    ) DBusFailure!*c.DBusMessage {
        const msg = c.dbus_message_new_method_call(dest, path, iface, method);
        defer c.dbus_message_unref(msg);
        const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 5000, err.ptr());
        return reply orelse DBusFailure.CallFailed;
    }

    /// Non-blocking: process any pending incoming messages. Call once per frame.
    pub fn pump(self: Connection) void {
        _ = c.dbus_connection_read_write_dispatch(self.handle, 0);
    }
};

pub fn connectSystem(err: *Error) DBusFailure!Connection {
    c.dbus_error_init(err.ptr());
    const conn = c.dbus_bus_get(c.DBUS_BUS_SYSTEM, err.ptr());
    return .{ .handle = conn orelse return DBusFailure.ConnectFailed };
}

pub fn iterString(it: *c.DBusMessageIter) [*c]const u8 {
    var s: [*c]const u8 = undefined;
    c.dbus_message_iter_get_basic(it, @ptrCast(&s));
    return s;
}

pub fn iterBool(it: *c.DBusMessageIter) bool {
    var b: c.dbus_bool_t = 0;
    c.dbus_message_iter_get_basic(it, @ptrCast(&b));
    return b != 0;
}
```

- [ ] **Step 2: Prove the connection from `main.zig`**

Replace `main` in `src/main.zig`:

```zig
const dbus = @import("dbus.zig");

pub fn main() void {
    var err = dbus.Error{};
    const conn = dbus.connectSystem(&err) catch {
        _ = c.printf("bus connect failed: %s\n", err.text());
        return;
    };
    _ = conn;
    _ = c.printf("connected to system bus\n");
}
```

- [ ] **Step 3: Build and run on device**

Run: `make run` (ignore the `--dump` flag for now; the binary ignores arguments)
Expected: `connected to system bus`

- [ ] **Step 4: Commit**

```bash
git add src/dbus.zig src/main.zig
git commit -m "libdbus wrapper with the DBusError bitfield workaround"
```

---

### Task 3: Enumerate Bluetooth devices

**Files:**
- Create: `src/bluez.zig`
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `dbus.Connection`, `dbus.iterString`, `dbus.iterBool`
- Produces:
  - `bluez.Device = struct { path: [:0]u8, address: [:0]u8, alias: [:0]u8, icon: [:0]u8, paired: bool, trusted: bool, connected: bool }`
  - `bluez.list(gpa, conn) ![]Device`
  - `bluez.freeList(gpa, devices) void`
  - `bluez.Device.isAudio(self) bool`

- [ ] **Step 1: Write `src/bluez.zig`**

```zig
// BlueZ domain model over D-Bus: device enumeration and operations.
const std = @import("std");
const dbus = @import("dbus.zig");
const c = dbus.c;

pub const Device = struct {
    path: [:0]u8,
    address: [:0]u8,
    alias: [:0]u8,
    icon: [:0]u8,
    paired: bool = false,
    trusted: bool = false,
    connected: bool = false,

    /// Audio devices get their sink routed automatically on connect.
    pub fn isAudio(self: Device) bool {
        return std.mem.startsWith(u8, self.icon, "audio");
    }
};

fn dupz(gpa: std.mem.Allocator, s: [*c]const u8) ![:0]u8 {
    return gpa.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(s))));
}

/// Reads org.bluez's whole object tree and returns every org.bluez.Device1.
/// Reply signature is a{oa{sa{sv}}}: path -> interface -> property -> variant.
pub fn list(gpa: std.mem.Allocator, conn: dbus.Connection) ![]Device {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", "/", "org.freedesktop.DBus.ObjectManager", "GetManagedObjects", &err);
    defer c.dbus_message_unref(reply);

    var out: std.ArrayList(Device) = .empty;
    errdefer out.deinit(gpa);

    var top: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_init(reply, &top);
    var objects: c.DBusMessageIter = undefined;
    c.dbus_message_iter_recurse(&top, &objects);

    while (c.dbus_message_iter_get_arg_type(&objects) != c.DBUS_TYPE_INVALID) {
        var obj: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&objects, &obj);
        const path = dbus.iterString(&obj);
        _ = c.dbus_message_iter_next(&obj);

        var ifaces: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&obj, &ifaces);
        while (c.dbus_message_iter_get_arg_type(&ifaces) != c.DBUS_TYPE_INVALID) {
            var ie: c.DBusMessageIter = undefined;
            c.dbus_message_iter_recurse(&ifaces, &ie);
            const iname = dbus.iterString(&ie);
            _ = c.dbus_message_iter_next(&ie);

            if (c.strcmp(iname, "org.bluez.Device1") == 0) {
                var d = Device{
                    .path = try dupz(gpa, path),
                    .address = try dupz(gpa, ""),
                    .alias = try dupz(gpa, ""),
                    .icon = try dupz(gpa, ""),
                };
                var props: c.DBusMessageIter = undefined;
                c.dbus_message_iter_recurse(&ie, &props);
                try readProps(gpa, &props, &d);
                try out.append(gpa, d);
            }
            _ = c.dbus_message_iter_next(&ifaces);
        }
        _ = c.dbus_message_iter_next(&objects);
    }
    return out.toOwnedSlice(gpa);
}

fn readProps(gpa: std.mem.Allocator, props: *c.DBusMessageIter, d: *Device) !void {
    while (c.dbus_message_iter_get_arg_type(props) != c.DBUS_TYPE_INVALID) {
        var entry: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(props, &entry);
        const key = dbus.iterString(&entry);
        _ = c.dbus_message_iter_next(&entry);

        var variant: c.DBusMessageIter = undefined;
        c.dbus_message_iter_recurse(&entry, &variant);
        const vtype = c.dbus_message_iter_get_arg_type(&variant);

        if (vtype == c.DBUS_TYPE_STRING) {
            const v = dbus.iterString(&variant);
            if (c.strcmp(key, "Address") == 0) {
                gpa.free(d.address);
                d.address = try dupz(gpa, v);
            } else if (c.strcmp(key, "Alias") == 0) {
                gpa.free(d.alias);
                d.alias = try dupz(gpa, v);
            } else if (c.strcmp(key, "Icon") == 0) {
                gpa.free(d.icon);
                d.icon = try dupz(gpa, v);
            }
        } else if (vtype == c.DBUS_TYPE_BOOLEAN) {
            const v = dbus.iterBool(&variant);
            if (c.strcmp(key, "Paired") == 0) d.paired = v;
            if (c.strcmp(key, "Trusted") == 0) d.trusted = v;
            if (c.strcmp(key, "Connected") == 0) d.connected = v;
        }
        _ = c.dbus_message_iter_next(props);
    }
}

pub fn freeList(gpa: std.mem.Allocator, devices: []Device) void {
    for (devices) |d| {
        gpa.free(d.path);
        gpa.free(d.address);
        gpa.free(d.alias);
        gpa.free(d.icon);
    }
    gpa.free(devices);
}
```

Add `@cInclude("string.h");` to the `@cImport` in `src/dbus.zig` so `c.strcmp` resolves.

- [ ] **Step 2: Add `--dump` to `src/main.zig`**

```zig
const bluez = @import("bluez.zig");

fn dumpMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);
    _ = c.printf("devices: %d\n", @as(c_int, @intCast(devices.len)));
    for (devices) |d| {
        _ = c.printf("  %-18s %-24s paired=%d connected=%d icon=%s\n", d.address.ptr, d.alias.ptr, @as(c_int, @intFromBool(d.paired)), @as(c_int, @intFromBool(d.connected)), d.icon.ptr);
    }
}
```

Dispatch on `--dump` by reading `std.os.argv` (available without an allocator):

```zig
fn hasFlag(name: []const u8) bool {
    for (std.os.argv[1..]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), name)) return true;
    }
    return false;
}
```

- [ ] **Step 3: Verify against the live bus**

Run: `make run`
Expected: at least the known headset, e.g.
`  4C:87:5D:FD:3E:42  Constantin  paired=1 connected=1 icon=audio-headphones`

- [ ] **Step 4: Commit**

```bash
git add src/bluez.zig src/dbus.zig src/main.zig
git commit -m "Enumerate BlueZ devices over D-Bus"
```

---

### Task 4: Bluetooth operations and the pairing agent

**Files:**
- Modify: `src/bluez.zig`, `src/dbus.zig`, `src/main.zig`

**Interfaces:**
- Consumes: Task 3 `Device`
- Produces:
  - `bluez.startScan(conn) !void` / `bluez.stopScan(conn) !void`
  - `bluez.connectAsync(conn, dev) !dbus.Pending`, `bluez.pairAsync(conn, dev) !dbus.Pending`
  - `dbus.Pending.done() bool`, `dbus.Pending.take() ?*c.DBusMessage`, `dbus.errorName(reply) ?[*c]const u8`
  - `bluez.disconnect(conn, dev) !void`, `bluez.setTrusted(conn, dev, bool) !void`
  - `bluez.forget(conn, dev) !void`
  - `bluez.powerOn(conn) !void`
  - `bluez.registerAgent(conn) !void`

- [ ] **Step 1: Add device operations to `src/bluez.zig`**

```zig
pub const adapter_path = "/org/bluez/hci0";

fn deviceCall(conn: dbus.Connection, dev: Device, method: [*c]const u8) !void {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", dev.path.ptr, "org.bluez.Device1", method, &err);
    c.dbus_message_unref(reply);
}

pub fn connect(conn: dbus.Connection, dev: Device) !void {
    return deviceCall(conn, dev, "Connect");
}
pub fn disconnect(conn: dbus.Connection, dev: Device) !void {
    return deviceCall(conn, dev, "Disconnect");
}
pub fn pair(conn: dbus.Connection, dev: Device) !void {
    return deviceCall(conn, dev, "Pair");
}

pub fn startScan(conn: dbus.Connection) !void {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StartDiscovery", &err);
    c.dbus_message_unref(reply);
}

pub fn stopScan(conn: dbus.Connection) !void {
    var err = dbus.Error{};
    const reply = try conn.call("org.bluez", adapter_path, "org.bluez.Adapter1", "StopDiscovery", &err);
    c.dbus_message_unref(reply);
}
```

- [ ] **Step 2: Add `callWithArgs` to `src/dbus.zig`** (needed for `RemoveDevice`, `Set`, and agent registration)

```zig
pub const Arg = union(enum) {
    str: [*c]const u8,
    obj: [*c]const u8,
    boolean: bool,
};

pub fn callArgs(
    self: Connection,
    dest: [*c]const u8,
    path: [*c]const u8,
    iface: [*c]const u8,
    method: [*c]const u8,
    args: []const Arg,
    err: *Error,
) DBusFailure!*c.DBusMessage {
    const msg = c.dbus_message_new_method_call(dest, path, iface, method);
    defer c.dbus_message_unref(msg);
    var it: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &it);
    for (args) |a| switch (a) {
        .str => |s| _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&s)),
        .obj => |s| _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_OBJECT_PATH, @ptrCast(&s)),
        .boolean => |b| {
            var v: c.dbus_bool_t = if (b) 1 else 0;
            _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_BOOLEAN, @ptrCast(&v));
        },
    };
    const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 30000, err.ptr());
    return reply orelse DBusFailure.CallFailed;
}
```

Move `callArgs` inside the `Connection` struct alongside `call`.

- [ ] **Step 3: Add `forget`, `setTrusted`, `powerOn` to `src/bluez.zig`**

```zig
pub fn forget(conn: dbus.Connection, dev: Device) !void {
    var err = dbus.Error{};
    const reply = try conn.callArgs("org.bluez", adapter_path, "org.bluez.Adapter1", "RemoveDevice", &.{.{ .obj = dev.path.ptr }}, &err);
    c.dbus_message_unref(reply);
}
```

For `setTrusted` and `powerOn` the value is a variant, which `Arg` cannot express. Add a dedicated helper in `src/dbus.zig`:

```zig
pub fn setBoolProperty(
    self: Connection,
    path: [*c]const u8,
    iface: [*c]const u8,
    name: [*c]const u8,
    value: bool,
    err: *Error,
) DBusFailure!void {
    const msg = c.dbus_message_new_method_call("org.bluez", path, "org.freedesktop.DBus.Properties", "Set");
    defer c.dbus_message_unref(msg);
    var it: c.DBusMessageIter = undefined;
    c.dbus_message_iter_init_append(msg, &it);
    _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&iface));
    _ = c.dbus_message_iter_append_basic(&it, c.DBUS_TYPE_STRING, @ptrCast(&name));
    var variant: c.DBusMessageIter = undefined;
    _ = c.dbus_message_iter_open_container(&it, c.DBUS_TYPE_VARIANT, "b", &variant);
    var v: c.dbus_bool_t = if (value) 1 else 0;
    _ = c.dbus_message_iter_append_basic(&variant, c.DBUS_TYPE_BOOLEAN, @ptrCast(&v));
    _ = c.dbus_message_iter_close_container(&it, &variant);
    const reply = c.dbus_connection_send_with_reply_and_block(self.handle, msg, 5000, err.ptr());
    if (reply) |r| c.dbus_message_unref(r) else return DBusFailure.CallFailed;
}
```

Then in `bluez.zig`:

```zig
pub fn setTrusted(conn: dbus.Connection, dev: Device, on: bool) !void {
    var err = dbus.Error{};
    try conn.setBoolProperty(dev.path.ptr, "org.bluez.Device1", "Trusted", on, &err);
}

pub fn powerOn(conn: dbus.Connection) !void {
    var err = dbus.Error{};
    try conn.setBoolProperty(adapter_path, "org.bluez.Adapter1", "Powered", true, &err);
}
```

- [ ] **Step 4: Add non-blocking Pair and Connect**

`Pair` and `Connect` can take many seconds. Blocking on them freezes the frame
loop and the modal stops animating, so they go through a pending call that the
frame loop polls. Add to `src/dbus.zig`:

```zig
pub const Pending = struct {
    call: ?*c.DBusPendingCall,

    pub fn done(self: Pending) bool {
        return c.dbus_pending_call_get_completed(self.call) != 0;
    }

    /// Consumes the pending call. Returns the reply, which may itself be an
    /// error message - check with `errorName`.
    pub fn take(self: Pending) ?*c.DBusMessage {
        const reply = c.dbus_pending_call_steal_reply(self.call);
        c.dbus_pending_call_unref(self.call);
        return reply;
    }
};

/// Null unless the reply is a D-Bus error, e.g. "org.bluez.Error.AuthenticationFailed".
pub fn errorName(reply: *c.DBusMessage) ?[*c]const u8 {
    if (c.dbus_message_get_type(reply) != c.DBUS_MESSAGE_TYPE_ERROR) return null;
    return c.dbus_message_get_error_name(reply);
}
```

and as a method on `Connection`:

```zig
pub fn callAsync(
    self: Connection,
    dest: [*c]const u8,
    path: [*c]const u8,
    iface: [*c]const u8,
    method: [*c]const u8,
) DBusFailure!Pending {
    const msg = c.dbus_message_new_method_call(dest, path, iface, method);
    defer c.dbus_message_unref(msg);
    var pending: ?*c.DBusPendingCall = null;
    if (c.dbus_connection_send_with_reply(self.handle, msg, &pending, 60000) == 0)
        return DBusFailure.CallFailed;
    return .{ .call = pending orelse return DBusFailure.CallFailed };
}
```

Then in `src/bluez.zig`, replace the blocking `connect` and `pair` with:

```zig
pub fn connectAsync(conn: dbus.Connection, dev: Device) !dbus.Pending {
    return conn.callAsync("org.bluez", dev.path.ptr, "org.bluez.Device1", "Connect");
}

pub fn pairAsync(conn: dbus.Connection, dev: Device) !dbus.Pending {
    return conn.callAsync("org.bluez", dev.path.ptr, "org.bluez.Device1", "Pair");
}
```

`disconnect`, `forget`, `setTrusted`, `powerOn` and the scan calls stay blocking:
they return promptly.

- [ ] **Step 5: Add the pairing agent to `src/bluez.zig`**

`NoInputNoOutput` means BlueZ never asks for a PIN or confirmation — it auto-accepts just-works pairing, which is what every gamepad and headset uses. The agent must still exist, or `Pair` fails with `org.bluez.Error.AuthenticationFailed`.

```zig
pub const agent_path = "/muos/btui/agent";

fn agentMessage(_: ?*c.DBusConnection, msg: ?*c.DBusMessage, _: ?*anyopaque) callconv(.c) c.DBusHandlerResult {
    const member = c.dbus_message_get_member(msg);
    // Every method we accept returns an empty reply; rejecting is never needed
    // for NoInputNoOutput pairing.
    if (c.strcmp(member, "RequestConfirmation") == 0 or
        c.strcmp(member, "RequestAuthorization") == 0 or
        c.strcmp(member, "AuthorizeService") == 0 or
        c.strcmp(member, "Release") == 0 or
        c.strcmp(member, "Cancel") == 0)
    {
        const reply = c.dbus_message_new_method_return(msg);
        _ = c.dbus_connection_send(c.dbus_message_get_connection(msg), reply, null);
        c.dbus_message_unref(reply);
        return c.DBUS_HANDLER_RESULT_HANDLED;
    }
    return c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

var agent_vtable = c.DBusObjectPathVTable{
    .unregister_function = null,
    .message_function = agentMessage,
};

pub fn registerAgent(conn: dbus.Connection) !void {
    _ = c.dbus_connection_register_object_path(conn.handle, agent_path, &agent_vtable, null);
    var err = dbus.Error{};
    const r1 = try conn.callArgs("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent", &.{ .{ .obj = agent_path }, .{ .str = "NoInputNoOutput" } }, &err);
    c.dbus_message_unref(r1);
    const r2 = try conn.callArgs("org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RequestDefaultAgent", &.{.{ .obj = agent_path }}, &err);
    c.dbus_message_unref(r2);
}
```

`c.dbus_message_get_connection` does not exist in libdbus. Capture the connection in a file-scope `var agent_conn: ?*c.DBusConnection = null;` set by `registerAgent`, and send the reply on that.

- [ ] **Step 6: Add test flags to `src/main.zig`**

Support `--scan`, `--connect <MAC>`, `--forget <MAC>`, matching a device from `bluez.list` by address. Print the resulting state by re-listing after the operation.

- [ ] **Step 7: Verify each operation on hardware**

```
make build && make deploy
ssh root@<ip> '/mnt/mmc/MUOS/application/Bluetooth/bin/btui --scan'
```
Expected: new addresses appear that were not in `--dump` before.

```
ssh root@<ip> '/mnt/mmc/MUOS/application/Bluetooth/bin/btui --connect 4C:87:5D:FD:3E:42'
```
Expected: `connected=1` in the re-listed output.

- [ ] **Step 8: Commit**

```bash
git add src/bluez.zig src/dbus.zig src/main.zig
git commit -m "Scan, pair, connect, forget and a NoInputNoOutput agent"
```

---

### Task 5: Audio sinks via PipeWire

**Files:**
- Create: `src/audio.zig`, `src/test_all.zig`, `tests/fixtures/pw-dump.json`
- Modify: `build.zig` is already prepared for `test_all.zig`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `audio.Sink = struct { id: u32, name: []const u8, description: []const u8, is_bluetooth: bool, is_default: bool }`
  - `audio.parseSinks(gpa, json_text) ![]Sink` — pure, host-testable
  - `audio.sinks(gpa) ![]Sink` — runs `pw-dump`
  - `audio.freeSinks(gpa, sinks) void`
  - `audio.setDefault(sink: Sink) void` — best-effort, never fails the UI
  - `audio.forceQuantum(frames: u32) void`

- [ ] **Step 1: Write the failing test**

Create `src/test_all.zig`:

```zig
test {
    _ = @import("audio.zig");
}
```

Append to `src/audio.zig`:

```zig
test "parseSinks finds sinks and marks the default" {
    const gpa = std.testing.allocator;
    const json_text =
        \\[
        \\ {"id":33,"type":"PipeWire:Interface:Node",
        \\  "info":{"props":{"media.class":"Audio/Sink","node.name":"alsa_output.internal","node.description":"Built-in Audio"}}},
        \\ {"id":49,"type":"PipeWire:Interface:Node",
        \\  "info":{"props":{"media.class":"Audio/Sink","node.name":"bluez_output.4C_87_5D_FD_3E_42.1","node.description":"Constantin"}}},
        \\ {"id":21,"type":"PipeWire:Interface:Metadata",
        \\  "metadata":[{"key":"default.audio.sink","value":{"name":"bluez_output.4C_87_5D_FD_3E_42.1"}}]}
        \\]
    ;
    const sinks = try parseSinks(gpa, json_text);
    defer freeSinks(gpa, sinks);

    try std.testing.expectEqual(@as(usize, 2), sinks.len);
    try std.testing.expect(!sinks[0].is_bluetooth);
    try std.testing.expect(sinks[1].is_bluetooth);
    try std.testing.expect(sinks[1].is_default);
    try std.testing.expectEqualStrings("Constantin", sinks[1].description);
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `zig build test`
Expected: FAIL — `parseSinks` is not defined.

- [ ] **Step 3: Implement `src/audio.zig`**

```zig
// PipeWire audio routing. State is read as JSON from pw-dump; changes go
// through wpctl and pw-metadata. Zig 0.16 has no process spawning API yet, so
// subprocesses use libc popen - we link libc regardless.
const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
});

pub const Sink = struct {
    id: u32,
    name: []const u8,
    description: []const u8,
    is_bluetooth: bool,
    is_default: bool,
};

/// muOS exports these from script/var/func.sh. Without them the PipeWire tools
/// report an empty graph instead of failing, which looks exactly like "no
/// sinks exist" and is extremely misleading.
const env_prefix = "XDG_RUNTIME_DIR=/run PIPEWIRE_RUNTIME_DIR=/run ";

pub fn parseSinks(gpa: std.mem.Allocator, json_text: []const u8) ![]Sink {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();

    var default_name: []const u8 = "";
    for (parsed.value.array.items) |obj| {
        const md = obj.object.get("metadata") orelse continue;
        for (md.array.items) |e| {
            const key = e.object.get("key") orelse continue;
            if (!std.mem.eql(u8, key.string, "default.audio.sink")) continue;
            const val = e.object.get("value") orelse continue;
            if (val.object.get("name")) |n| default_name = n.string;
        }
    }

    var out: std.ArrayList(Sink) = .empty;
    errdefer out.deinit(gpa);

    for (parsed.value.array.items) |obj| {
        const info = obj.object.get("info") orelse continue;
        const props = info.object.get("props") orelse continue;
        const class = props.object.get("media.class") orelse continue;
        if (!std.mem.eql(u8, class.string, "Audio/Sink")) continue;

        const name = (props.object.get("node.name") orelse continue).string;
        const desc = if (props.object.get("node.description")) |d| d.string else name;
        try out.append(gpa, .{
            .id = @intCast((obj.object.get("id") orelse continue).integer),
            .name = try gpa.dupe(u8, name),
            .description = try gpa.dupe(u8, desc),
            .is_bluetooth = std.mem.startsWith(u8, name, "bluez_output"),
            .is_default = std.mem.eql(u8, name, default_name),
        });
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeSinks(gpa: std.mem.Allocator, sinks: []Sink) void {
    for (sinks) |s| {
        gpa.free(s.name);
        gpa.free(s.description);
    }
    gpa.free(sinks);
}

fn runCapture(gpa: std.mem.Allocator, cmd: [*c]const u8) ![]u8 {
    const f = c.popen(cmd, "r") orelse return error.PopenFailed;
    defer _ = c.pclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (c.fgets(&buf, buf.len, f) != null) {
        try out.appendSlice(gpa, std.mem.span(@as([*:0]const u8, @ptrCast(&buf))));
    }
    return out.toOwnedSlice(gpa);
}

pub fn sinks(gpa: std.mem.Allocator) ![]Sink {
    const text = try runCapture(gpa, env_prefix ++ "pw-dump");
    defer gpa.free(text);
    return parseSinks(gpa, text);
}

fn runQuiet(cmd: [*c]const u8) void {
    _ = c.system(cmd);
}

pub fn setDefault(sink: Sink) void {
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, env_prefix ++ "wpctl set-default {d} >/dev/null 2>&1", .{sink.id}) catch return;
    runQuiet(cmd.ptr);
    // Matches bin/bt-audio.sh: a 2048 quantum makes the A2DP transport miss
    // radio windows shared with WiFi, which breaks audio up during play.
    forceQuantum(if (sink.is_bluetooth) 512 else 0);
}

pub fn forceQuantum(frames: u32) void {
    var buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&buf, env_prefix ++ "pw-metadata -n settings 0 clock.force-quantum {d} >/dev/null 2>&1", .{frames}) catch return;
    runQuiet(cmd.ptr);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Extend `--dump` to print sinks and verify on device**

Run: `make run`
Expected: the two built-in sinks plus the Bluetooth sink, with `*` on the default.

- [ ] **Step 6: Commit**

```bash
git add src/audio.zig src/test_all.zig
git commit -m "Read PipeWire sinks as JSON and switch the default"
```

---

### Task 6: Theme lookup

**Files:**
- Create: `src/theme.zig`
- Modify: `src/test_all.zig`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `theme.Palette = struct { bg: u32, fg: u32, accent: u32, dim: u32, bar: u32 }`
  - `theme.activeName(gpa) ![]u8` — from `/opt/muos/config/theme/active`
  - `theme.fontPath(gpa, name) ![:0]u8` — NUL-terminated, because
    `ui.init` passes it straight to `TTF_OpenFont`
  - `theme.palette() Palette`

- [ ] **Step 1: Write the failing test**

Append to `src/theme.zig`:

```zig
test "activeNameFrom trims whitespace and newlines" {
    const gpa = std.testing.allocator;
    const got = try activeNameFrom(gpa, "MustardOS\n");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("MustardOS", got);
}
```

Add `_ = @import("theme.zig");` to `src/test_all.zig`.

- [ ] **Step 2: Run it and watch it fail**

Run: `zig build test`
Expected: FAIL — `activeNameFrom` is not defined.

- [ ] **Step 3: Implement `src/theme.zig`**

The 640x480 scheme files on this build contain only grid geometry (5 lines each, `[grid]` / `COLUMN_COUNT` / `ROW_COUNT`) — no colours. So v1 takes the font and glyphs from the active theme and uses a fixed palette matching muOS's default look. Colour parsing is deliberately out of scope until a theme is found that actually carries colours.

```zig
// Locates the active muOS theme's font and glyphs. Colours are built in: the
// 640x480 scheme files in muOS 2601.1 carry grid geometry only.
const std = @import("std");

pub const Palette = struct {
    bg: u32 = 0x1A1A1A,
    fg: u32 = 0xEBEBEB,
    accent: u32 = 0xFFC629, // MustardOS yellow
    dim: u32 = 0x7A7A7A,
    bar: u32 = 0x101010,
};

pub fn palette() Palette {
    return .{};
}

pub fn activeNameFrom(gpa: std.mem.Allocator, contents: []const u8) ![]u8 {
    return gpa.dupe(u8, std.mem.trim(u8, contents, " \t\r\n"));
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(64 * 1024));
}

pub fn activeName(gpa: std.mem.Allocator) ![]u8 {
    const raw = readFile(gpa, "/opt/muos/config/theme/active") catch
        return gpa.dupe(u8, "MustardOS");
    defer gpa.free(raw);
    return activeNameFrom(gpa, raw);
}

/// First .ttf under the active theme's font directory, else a known-present
/// system font so the UI always has something to draw with.
pub fn fontPath(gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const fallback = "/opt/muos/share/emulator/ppsspp/Inconsolata-Medium.ttf";
    const dir_path = try std.fmt.allocPrint(gpa, "/run/muos/storage/theme/{s}/font", .{name});
    defer gpa.free(dir_path);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return gpa.dupeZ(u8, fallback);
    defer dir.close(io);

    var it = dir.iterate(io);
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".ttf")) {
            return std.fmt.allocPrintZ(gpa, "{s}/{s}", .{ dir_path, entry.name });
        }
    }
    return gpa.dupeZ(u8, fallback);
}
```

If `Dir.iterate`'s signature differs in 0.16, fall back to the fixed system font path and open an issue — the UI must not block on theme discovery.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test`
Expected: PASS

- [ ] **Step 5: Verify font discovery on device**

Add `--dump` output for the resolved theme name and font path.
Run: `make run`
Expected: `theme: MustardOS  font: /run/muos/storage/theme/MustardOS/font/<something>.ttf`

- [ ] **Step 6: Commit**

```bash
git add src/theme.zig src/test_all.zig
git commit -m "Resolve the active theme's font, with fallbacks"
```

---

### Task 7: SDL window and list rendering

**Risk task.** No spike has opened a window under the `mali` driver yet. Do Step 1 first and stop if it fails; everything after depends on it.

**Files:**
- Create: `src/ui.zig`
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `theme.Palette`, `theme.fontPath`
- Produces:
  - `ui.Ui = struct { window, renderer, font }`
  - `ui.init(font_path) !Ui`, `ui.deinit(self)`
  - `ui.beginFrame(self, pal)`, `ui.endFrame(self)`
  - `ui.text(self, x, y, str, colour)`
  - `ui.listRow(self, index, selected, left, right, pal)`
  - `ui.Button = enum { up, down, a, b, x, y, l1, r1, quit }`
  - `ui.poll(self) ?Button`

- [ ] **Step 1: Prove a window opens under `mali`**

Minimal `src/ui.zig` that opens 640x480, clears to the accent colour, delays 2 s, quits. Wire it to a `--window-test` flag.

```zig
pub fn windowTest() !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK) != 0) return error.SdlInit;
    defer c.SDL_Quit();
    const win = c.SDL_CreateWindow("btui", 0, 0, 640, 480, c.SDL_WINDOW_SHOWN) orelse return error.SdlWindow;
    defer c.SDL_DestroyWindow(win);
    const ren = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse return error.SdlRenderer;
    defer c.SDL_DestroyRenderer(ren);
    _ = c.SDL_SetRenderDrawColor(ren, 0xFF, 0xC6, 0x29, 0xFF);
    _ = c.SDL_RenderClear(ren);
    c.SDL_RenderPresent(ren);
    c.SDL_Delay(2000);
}
```

Run on device **with the frontend stopped**, the way muOS apps run:

```
ssh root@<ip> 'killall -STOP muxfrontend; /mnt/mmc/MUOS/application/Bluetooth/bin/btui --window-test; killall -CONT muxfrontend'
```
Expected: the screen turns yellow for two seconds, then muOS returns.
If `SDL_CreateWindow` fails, print `c.SDL_GetError()` and try `SDL_WINDOW_FULLSCREEN`, then `SDL_VIDEODRIVER=mali` explicitly. Do not proceed until a window appears.

- [ ] **Step 2: Add font loading and `text`**

```zig
pub fn init(font_path: [:0]const u8) !Ui {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_JOYSTICK) != 0) return error.SdlInit;
    if (c.TTF_Init() != 0) return error.TtfInit;
    const win = c.SDL_CreateWindow("btui", 0, 0, 640, 480, c.SDL_WINDOW_SHOWN) orelse return error.SdlWindow;
    const ren = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse return error.SdlRenderer;
    const font = c.TTF_OpenFont(font_path.ptr, 18) orelse return error.FontOpen;
    _ = c.SDL_JoystickOpen(0);
    return .{ .window = win, .renderer = ren, .font = font };
}

pub fn text(self: Ui, x: c_int, y: c_int, s: [:0]const u8, colour: u32) void {
    const col = c.SDL_Color{
        .r = @intCast((colour >> 16) & 0xFF),
        .g = @intCast((colour >> 8) & 0xFF),
        .b = @intCast(colour & 0xFF),
        .a = 0xFF,
    };
    const surf = c.TTF_RenderUTF8_Blended(self.font, s.ptr, col) orelse return;
    defer c.SDL_FreeSurface(surf);
    const tex = c.SDL_CreateTextureFromSurface(self.renderer, surf) orelse return;
    defer c.SDL_DestroyTexture(tex);
    var dst = c.SDL_Rect{ .x = x, .y = y, .w = surf.*.w, .h = surf.*.h };
    _ = c.SDL_RenderCopy(self.renderer, tex, null, &dst);
}
```

- [ ] **Step 3: Add input polling**

```zig
pub const Button = enum { up, down, a, b, x, y, l1, r1, quit };

pub fn poll(_: Ui) ?Button {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev) != 0) {
        switch (ev.type) {
            c.SDL_QUIT => return .quit,
            c.SDL_JOYHATMOTION => {
                if (ev.jhat.value == c.SDL_HAT_UP) return .up;
                if (ev.jhat.value == c.SDL_HAT_DOWN) return .down;
            },
            c.SDL_JOYBUTTONDOWN => return switch (ev.jbutton.button) {
                0 => .a, 1 => .b, 2 => .x, 3 => .y, 4 => .l1, 5 => .r1,
                else => null,
            },
            c.SDL_KEYDOWN => return switch (ev.key.keysym.sym) {
                c.SDLK_UP => .up, c.SDLK_DOWN => .down,
                c.SDLK_RETURN => .a, c.SDLK_ESCAPE => .b,
                else => null,
            },
            else => {},
        }
    }
    return null;
}
```

Button indices are a guess. Verify with a `--input-test` flag that prints `ev.jbutton.button` for each press, run it on the device, press A/B/X/Y/L1/R1 in order, and correct the mapping from the observed numbers before continuing.

- [ ] **Step 4: Add `beginFrame`, `endFrame`, `listRow`**

`listRow` draws a full-width row: selection background in `pal.accent` when selected, left-aligned label at x=24, right-aligned status at x=616, row height 28, list origin y=64.

- [ ] **Step 5: Verify on device**

Run a `--ui-test` that renders five dummy rows with row 2 selected.
Expected: readable themed list at 640x480, selection highlighted.

- [ ] **Step 6: Commit**

```bash
git add src/ui.zig src/main.zig
git commit -m "SDL2 window, themed text and list rows"
```

---

### Task 8: Devices tab

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: everything from Tasks 2-7
- Produces: `App` struct owning `conn`, `devices`, `selected`, `mode`, `status`

- [ ] **Step 1: Implement the state machine**

```zig
const Mode = enum { list, scanning, working, err };
const Tab = enum { devices, audio };

const App = struct {
    gpa: std.mem.Allocator,
    conn: dbus.Connection,
    ui: ui.Ui,
    pal: theme.Palette,
    tab: Tab = .devices,
    mode: Mode = .list,
    devices: []bluez.Device = &.{},
    selected: usize = 0,
    status: [128:0]u8 = std.mem.zeroes([128:0]u8),
};
```

- [ ] **Step 2: Implement the frame loop**

Each frame: `conn.pump()`, poll input, act, refresh the device list every 500 ms while scanning, render.

Actions on the devices tab:
- `up`/`down` — move selection
- `a` — if connected, `bluez.disconnect` (blocking, returns at once); else `bluez.connectAsync`, store the `Pending` in `App`, set `mode = .working`. Each frame, if `pending.done()`, `take()` the reply, check `dbus.errorName`, and on success with `dev.isAudio()` run the routing from Task 9
- `x` — `bluez.forget`, then refresh
- `y` — toggle `bluez.startScan`/`stopScan`, `mode = .scanning`
- `b` — exit
- `r1` — `tab = .audio`

- [ ] **Step 3: Render devices**

Header: `Bluetooth` plus adapter state. Rows: alias (or address when the alias is empty) on the left; `connected` / `paired` / blank on the right. Footer: `A connect  X forget  Y scan  B exit`.

- [ ] **Step 4: Show errors**

Every `bluez.*` call returning an error sets `status` to `err.text()` and `mode = .err`. Any button dismisses it. BlueZ's own messages (`org.bluez.Error.AuthenticationFailed`) are already legible; show them verbatim.

- [ ] **Step 5: Verify on device**

Stop the frontend, run `btui`, scan, connect and disconnect the headset.
Expected: list updates live during a scan; connect toggles the right-hand status.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "Devices tab: scan, connect, forget from the handheld"
```

---

### Task 9: Audio tab and automatic routing

**Files:**
- Modify: `src/main.zig`

**Interfaces:**
- Consumes: `audio.Sink`, `audio.sinks`, `audio.setDefault`
- Produces: sink list state in `App`

- [ ] **Step 1: Add sinks to `App` and refresh on tab entry**

- [ ] **Step 2: Render the audio tab**

Rows: sink description; right-hand marker `← output` on the default. Footer: `A set as output  L1 devices  B exit`.

- [ ] **Step 3: `a` calls `audio.setDefault(sink)` then refreshes**

`setDefault` already forces quantum 512 for Bluetooth sinks and 0 for internal ones.

- [ ] **Step 4: Auto-route on connect**

In the devices tab, after a successful `connect` of a device where `isAudio()` is true, poll `audio.sinks` for up to 5 s until a sink with `is_bluetooth` appears, then `setDefault` it. This is the behaviour that stops "connected but silent".

- [ ] **Step 5: Verify on device**

Connect the headset from the devices tab with the internal speaker as default.
Expected: audio moves to the headset without visiting the audio tab; the audio tab then shows the marker on the Bluetooth sink; selecting the internal sink moves it back and resets the quantum.

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "Audio tab and automatic routing on headset connect"
```

---

### Task 10: Package as a muOS app

**Files:**
- Create: `package/mux_launch.sh`
- Modify: `install.sh`, `README.md`

- [ ] **Step 1: Read a stock app's launcher to copy the convention exactly**

Run: `ssh root@<ip> 'cat "/opt/muos/share/application/Dingux Commander/mux_launch.sh"'`
Use its structure — do not invent one.

- [ ] **Step 2: Write `package/mux_launch.sh`**

Must carry `# HELP: Manage Bluetooth devices and audio output` and `# ICON: bluetooth` headers, source `/opt/muos/script/var/func.sh`, set the foreground process, and exec `bin/btui`.

- [ ] **Step 3: Extend `install.sh`**

Add a step that creates `/mnt/mmc/MUOS/application/Bluetooth/`, pipes `zig-out/bin/btui` to `bin/btui`, pipes `mux_launch.sh` alongside it, and `chmod +x` both. Keep the existing hook and helper installation untouched.

- [ ] **Step 4: Verify from the muOS menu**

Reboot, open Applications, launch Bluetooth.
Expected: the app appears with the Bluetooth glyph and runs; `B` returns to muOS with the frontend intact.

- [ ] **Step 5: Update `README.md`**

Add an app section: what it does, a photo of it running, the controls table, and a note that the shell helpers remain for the headless/SSH workflow.

- [ ] **Step 6: Commit**

```bash
git add package/mux_launch.sh install.sh README.md
git commit -m "Package btui as a muOS application"
```

---

## Notes for the executor

- **Verify on hardware constantly.** `make run` after every task. This codebase cannot be meaningfully tested on the dev machine beyond the two parsing modules.
- **The device is the source of truth for muOS conventions.** Where this plan describes a muOS path or file format, check it on the device before relying on it; muOS versions differ.
- **If SDL window creation fails in Task 7**, stop and report. Everything from Task 7 onward depends on it, and the fallback (direct framebuffer rendering to `/dev/fb0`, 640x960 virtual, 32 bpp) is a different design that needs its own spec revision.
