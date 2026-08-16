// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("stdio.h");
    @cInclude("unistd.h");
});
const dbus = @import("dbus.zig");
const bluez = @import("bluez.zig");
const audio = @import("audio.zig");
const theme = @import("theme.zig");
const ui = @import("ui.zig");

pub const version = "0.1.0";

// Zig 0.16's start.zig hands `main` the process args directly when it takes
// a `std.process.Init.Minimal` parameter; there is no more `std.os.argv`.
fn hasFlag(args: std.process.Args, name: []const u8) bool {
    for (args.vector[1..]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), name)) return true;
    }
    return false;
}

/// Returns the value following `name` in argv, e.g. the MAC after `--connect`.
fn flagValue(args: std.process.Args, name: []const u8) ?[]const u8 {
    const v = args.vector[1..];
    for (v, 0..) |a, i| {
        if (std.mem.eql(u8, std.mem.span(a), name) and i + 1 < v.len) {
            return std.mem.span(v[i + 1]);
        }
    }
    return null;
}

fn printDevices(devices: []const bluez.Device) void {
    _ = c.printf("devices: %d\n", @as(c_int, @intCast(devices.len)));
    for (devices) |d| {
        _ = c.printf("  %-18s %-24s paired=%d connected=%d icon=%s\n", d.address.ptr, d.alias.ptr, @as(c_int, @intFromBool(d.paired)), @as(c_int, @intFromBool(d.connected)), d.icon.ptr);
    }
}

fn findByAddress(devices: []bluez.Device, address: []const u8) ?bluez.Device {
    for (devices) |d| {
        if (std.mem.eql(u8, d.address, address)) return d;
    }
    return null;
}

fn printSinks(gpa: std.mem.Allocator) void {
    const list = audio.sinks(gpa) catch |e| {
        _ = c.printf("sinks failed: %s\n", @errorName(e).ptr);
        return;
    };
    defer audio.freeSinks(gpa, list);

    // s.name/description come from parseSinks' gpa.dupe, so they are plain
    // slices with no null terminator: %.*s (length from the argument) rather
    // than %s (which would read past the allocation looking for one).
    _ = c.printf("sinks: %d\n", @as(c_int, @intCast(list.len)));
    for (list) |s| {
        _ = c.printf("  %-4d %.*s (%.*s) bt=%d%s\n", s.id, @as(c_int, @intCast(s.name.len)), s.name.ptr, @as(c_int, @intCast(s.description.len)), s.description.ptr, @as(c_int, @intFromBool(s.is_bluetooth)), @as([*:0]const u8, if (s.is_default) " *" else ""));
    }
}

fn printTheme(gpa: std.mem.Allocator) void {
    const name = theme.activeName(gpa) catch |e| {
        _ = c.printf("theme lookup failed: %s\n", @errorName(e).ptr);
        return;
    };
    defer gpa.free(name);

    const font = theme.fontPath(gpa, name) catch |e| {
        _ = c.printf("theme: %.*s  font lookup failed: %s\n", @as(c_int, @intCast(name.len)), name.ptr, @errorName(e).ptr);
        return;
    };
    defer gpa.free(font);

    _ = c.printf("theme: %.*s  font: %s\n", @as(c_int, @intCast(name.len)), name.ptr, font.ptr);
}

/// `--dump` is the project's main development feedback loop: it prints the
/// device list over SSH with no UI involved.
fn dumpMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    var err = dbus.Error{};
    defer err.deinit();
    const devices = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, devices);
    printDevices(devices);
    printSinks(gpa);
    printTheme(gpa);
}

/// Starts discovery, gives the adapter a few seconds to hear back from
/// nearby devices, then stops and prints the device list like `--dump`.
fn scanMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    var err = dbus.Error{};
    defer err.deinit();

    bluez.startScan(conn, &err) catch |e| {
        _ = c.printf("scan failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    _ = c.sleep(8);
    bluez.stopScan(conn, &err) catch |e| {
        _ = c.printf("scan failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };

    const devices = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, devices);
    printDevices(devices);
}

/// Registers the NoInputNoOutput pairing agent (see `bluez.registerAgent`)
/// and holds the bus connection open for a few seconds, pumping it, so the
/// registration round-trip actually runs once on real hardware. Exercising
/// this from a real pairing is Task 8's job; this only proves registration
/// itself - the two-argument `RegisterAgent` marshalling, the vtable wiring,
/// and `agentMessage`'s reply path - has run at all. Self-reverting: BlueZ
/// releases the agent when this process exits and the connection drops.
fn agentMode(conn: dbus.Connection) !void {
    try bluez.registerAgent(conn);
    _ = c.printf("agent registered at %s\n", @as([*c]const u8, bluez.agent_path));
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        conn.pump();
        _ = c.sleep(1);
    }
    _ = c.printf("agent mode done\n");
}

/// Non-blocking connect: polls the `Pending` from `bluez.connectAsync` on the
/// bus connection, the same way the frame loop will in the real UI.
fn connectMode(gpa: std.mem.Allocator, conn: dbus.Connection, address: []const u8) !void {
    var err = dbus.Error{};
    defer err.deinit();
    const devices = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, devices);

    const dev = findByAddress(devices, address) orelse {
        _ = c.printf("no device with address %s\n", address.ptr);
        return;
    };

    var pending = try bluez.connectAsync(conn, dev);
    while (!pending.done()) {
        conn.pump();
        _ = c.usleep(10_000);
    }
    if (pending.take()) |reply| {
        defer dbus.c.dbus_message_unref(reply);
        if (dbus.errorName(reply)) |name| {
            _ = c.printf("connect failed: %s\n", name);
        }
    }

    const after = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, after);
    printDevices(after);
}

/// Implemented and code-reviewed but deliberately never run against a real
/// address: see Ruling B in the task-4 brief - the device's paired headset
/// can only be re-paired with physical access we don't have.
fn forgetMode(gpa: std.mem.Allocator, conn: dbus.Connection, address: []const u8) !void {
    var err = dbus.Error{};
    defer err.deinit();
    const devices = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, devices);

    const dev = findByAddress(devices, address) orelse {
        _ = c.printf("no device with address %s\n", address.ptr);
        return;
    };

    bluez.forget(conn, dev, &err) catch |e| {
        _ = c.printf("forget failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };

    const after = bluez.list(gpa, conn, &err) catch |e| {
        _ = c.printf("list failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };
    defer bluez.freeList(gpa, after);
    printDevices(after);
}

/// Loads the active theme's font path for a UI test mode, printing and
/// bailing out on failure rather than propagating - these modes are manual,
/// on-device checks, not something another mode calls into.
fn testFontPath(gpa: std.mem.Allocator) ?[:0]u8 {
    const name = theme.activeName(gpa) catch |e| {
        _ = c.printf("theme lookup failed: %s\n", @errorName(e).ptr);
        return null;
    };
    defer gpa.free(name);
    return theme.fontPath(gpa, name) catch |e| {
        _ = c.printf("font lookup failed: %s\n", @errorName(e).ptr);
        return null;
    };
}

const Mode = enum { list, scanning, working, err };
const Tab = enum { devices, audio };

/// Which async D-Bus call `App.pending` is currently carrying. `a` on an
/// unpaired device pairs first, then chains straight into a connect on
/// success (see `beginAsync`/`updatePending`) - a third async step the
/// original devices-tab design didn't have, since the plan's Task 8 action
/// list omitted pairing entirely.
const PendingKind = enum { pair, connect };

const scan_refresh_ms: u32 = 500;
const connect_retry_delay_ms: u32 = 1000;

// Task 9 auto-route: how often `pollAutoRoute` actually shells out to
// `pw-dump` while waiting for a just-connected audio device's sink to
// appear, and how long it waits in total before giving up. 500ms keeps the
// subprocess count low (at most ~10 over the wait) without making the
// route feel laggy once the sink does show up; 5s matches the task-9 brief.
const audio_poll_interval_ms: u32 = 500;
const audio_route_timeout_ms: u32 = 5000;

// Fix round 2, finding I5 (team-lead ruling): how long a second `X` has to
// arrive after the first before a forget is actually committed.
const forget_confirm_window_ms: u32 = 3000;

/// Owns the bus connection, SDL/font state, the current device list, and
/// where the user is in the UI. `pending`/`pending_*`/`retry_*` exist so a
/// `Connect` in flight (see `bluez.connectAsync`) never blocks the frame
/// loop: they carry just enough state (which device, whether it's audio,
/// whether a retry has already been spent) across frames without holding a
/// `bluez.Device` whose pointers could be invalidated by a list refresh.
const App = struct {
    gpa: std.mem.Allocator,
    conn: dbus.Connection,
    ui: ui.Ui,
    pal: theme.Palette,
    tab: Tab = .devices,
    mode: Mode = .list,
    resume_mode: Mode = .list,
    devices: []bluez.Device = &.{},
    selected: usize = 0,
    status: [128:0]u8 = std.mem.zeroes([128:0]u8),

    // Wall-clock (SDL_GetTicks) of the last scan-driven list refresh.
    last_refresh_ms: u32 = 0,

    // Audio tab: same ownership shape as `devices`/`selected` above (see
    // `refreshSinks`) - a fresh slice from `audio.sinks` on every reload,
    // freed before being replaced.
    sinks: []audio.Sink = &.{},
    sinks_selected: usize = 0,

    pending: ?dbus.Pending = null,
    pending_kind: PendingKind = .connect,
    pending_index: usize = 0,
    pending_is_audio: bool = false,
    // Task 9 fix round 1, finding I3: the connecting device's own address
    // (e.g. "AA:BB:CC:DD:EE:FF"), copied - not referenced - at `beginAsync`
    // time, same reasoning as `pending_is_audio` in the doc comment above:
    // `app.devices` can be reallocated by a refresh before the connect
    // finishes, and `pollAutoRoute` needs this well after that can happen.
    pending_address: [32:0]u8 = std.mem.zeroes([32:0]u8),
    pending_retried: bool = false,
    retry_scheduled: bool = false,
    retry_at_ms: u32 = 0,

    // Task 9 auto-route: set by `updatePending` right after a successful
    // connect to an `isAudio()` device. Polled once per frame by
    // `pollAutoRoute` (never blocks): tries to match `pending_address`
    // against a Bluetooth sink until `audio_route_timeout_ms` has elapsed
    // since `awaiting_sink_started_ms`, at which point it falls back to any
    // Bluetooth sink once (fix round 1, finding I3) before giving up.
    awaiting_sink: bool = false,
    awaiting_sink_started_ms: u32 = 0,
    awaiting_sink_last_poll_ms: u32 = 0,

    // Set by `fail` when it fires mid-`.working`; cleared by the frame loop,
    // which refreshes once at the top of the next iteration when it's set.
    // See `fail`'s doc comment (final review, finding I2).
    needs_refresh: bool = false,

    // Task 9 fix round 1, finding I1: the audio tab's analogue of
    // `needs_refresh` above. `pollAutoRoute` runs every frame regardless of
    // which tab is open and must not refresh `app.sinks` (or route a
    // failure through `fail`) directly from the background - it just flags
    // this, and the frame loop refreshes at the top of its next iteration,
    // same as `needs_refresh` does for devices.
    needs_sink_refresh: bool = false,

    // Fix round 2, finding I5 (team-lead ruling): `X` no longer forgets on
    // one press. The first press arms this (with the device's own address,
    // same copy-not-reference reasoning as `pending_address` - the list can
    // reorder underneath `selected` every ~500ms during a scan) and shows a
    // confirmation prompt; only a second `X` on the *same* device within
    // `forget_confirm_window_ms` actually commits. Any other button, a
    // mismatched address, or letting the window lapse all disarm it instead.
    forget_armed: bool = false,
    forget_armed_at_ms: u32 = 0,
    forget_armed_address: [32:0]u8 = std.mem.zeroes([32:0]u8),

    quit: bool = false,
};

/// Copies a (possibly null) C string into `app.status`, truncating to fit
/// rather than failing - a truncated error is still more useful on screen
/// than none at all. Safe against a null `msg` (some libdbus paths could
/// hand back one) by substituting a fixed fallback before spanning it.
fn setStatus(app: *App, msg: [*c]const u8) void {
    const text_c: [*:0]const u8 = if (msg) |m| @ptrCast(m) else "(no detail)";
    const s = std.mem.span(text_c);
    const n = @min(s.len, app.status.len - 1);
    @memcpy(app.status[0..n], s[0..n]);
    app.status[n] = 0;
}

/// Copies `address` into `dst`, truncating to fit - same shape as
/// `setStatus`. Used for both `pending_address` (Task 9 auto-route) and
/// `forget_armed_address` (fix round 2, finding I5): both need a `Device`'s
/// address to remain valid across a frame boundary, after which
/// `app.devices` may have been reallocated or reordered - so both copy it
/// rather than re-reading it later from `app.devices[some saved index]`.
fn copyAddress(dst: *[32:0]u8, address: [:0]const u8) void {
    const n = @min(address.len, dst.len - 1);
    @memcpy(dst[0..n], address[0..n]);
    dst[n] = 0;
}

/// Extracts the first string argument from a D-Bus error reply's body -
/// BlueZ's own errors carry a human-legible detail string there (e.g. the
/// "br-connection-busy" text behind `org.bluez.Error.InProgress`), which is
/// what actually needs to be shown, not just the bare `errorName`.
fn replyErrorText(reply: *dbus.c.DBusMessage) [*c]const u8 {
    var it: dbus.c.DBusMessageIter = undefined;
    if (dbus.c.dbus_message_iter_init(reply, &it) == 0) return "(no detail)";
    if (dbus.c.dbus_message_iter_get_arg_type(&it) != dbus.c.DBUS_TYPE_STRING) return "(no detail)";
    return dbus.iterString(&it);
}

/// `org.bluez.Error.InProgress` (surfaced by BlueZ as "br-connection-busy")
/// means another operation on the same device is still settling - transient,
/// not a real failure. Checked by name first since that's exact; the detail
/// text is a fallback in case BlueZ ever reorders/renames the error itself.
fn isTransient(name: [*c]const u8, detail: [*c]const u8) bool {
    if (dbus.c.strcmp(name, "org.bluez.Error.InProgress") == 0) return true;
    const d = std.mem.span(@as([*:0]const u8, @ptrCast(detail)));
    return std.mem.indexOf(u8, d, "br-connection-busy") != null;
}

/// Records where a modal should return to, but only the first time one is
/// entered from a normal state (`.list`/`.scanning`). Fix round 1, finding
/// I1: `resume_mode` was previously only set on the connect path, so every
/// other failure (disconnect, forget, scan toggle, a refresh mid-scan, the
/// connect retry itself) dropped the user to `.list` even while a scan was
/// still running on the adapter with no way back to `.scanning` from the
/// UI's point of view. Guarding against `.err`/`.working` means a failure
/// that happens *while already in a modal* (e.g. the retry-connect failing
/// while `.working`) can't clobber the resume target the outer modal set.
fn captureResumeMode(app: *App) void {
    if (app.mode != .err and app.mode != .working) app.resume_mode = app.mode;
}

/// Single entry point for "something failed, show it": captures the resume
/// target before switching, so every failure site returns to wherever the
/// user actually was.
///
/// Final review, finding I2 (structural fix): also marks `app.needs_refresh`
/// whenever a failure exits `.working` - `pairAsync`/`connectAsync` can
/// leave the device in a different `paired`/`connected` state than
/// `app.devices` still shows (pairing that succeeded before a later step
/// failed, most notably), and the row must not go on reading stale state
/// with no advertised way out. Fix round 1's I2 patch added `refreshDevices`
/// at the two exits the reviewer named at the time; a later review found a
/// third, unnamed one reachable through an ordinary flow - the actual
/// requirement was always "every exit from `.working`", which only holds by
/// construction if `fail` itself guarantees it, not if every call site has
/// to remember to ask for it. The frame loop performs the actual refresh at
/// the top of its next iteration (see `runUi`) rather than here, so this
/// can never recurse into itself if the refresh itself fails - by the time
/// that runs, `app.mode` is already `.err`, not `.working`, so a nested
/// `fail` call doesn't re-arm the flag.
fn fail(app: *App, text: [*c]const u8) void {
    if (app.mode == .working) app.needs_refresh = true;
    captureResumeMode(app);
    setStatus(app, text);
    app.mode = .err;
}

/// True when discovery is - or, from the user's point of view, still ought
/// to be - running: either `mode` is directly `.scanning`, or an error modal
/// is up whose `resume_mode` is `.scanning` (dismissing it would return to
/// `.scanning`, so the adapter was never actually told to stop). Fix round 2,
/// finding G2: the exit-time `stopScan` guard previously checked only
/// `mode == .scanning`, missing exactly this case - e.g. a scan-tick
/// `refreshDevices` failure, which routes through `fail` and leaves
/// `mode = .err` / `resume_mode = .scanning` - if the process exits via
/// `SDL_QUIT` before the modal is dismissed.
fn isScanning(app: *App) bool {
    return app.mode == .scanning or (app.mode == .err and app.resume_mode == .scanning);
}

/// Re-lists devices, freeing the previous slice first - the hot allocation
/// path (Task 8 brief: this runs every ~500ms while scanning) - and clamps
/// `selected` so it never points past the end of a shrunk list (e.g. after
/// `forget`).
fn refreshDevices(app: *App) void {
    var err = dbus.Error{};
    defer err.deinit();
    const new_list = bluez.list(app.gpa, app.conn, &err) catch {
        fail(app, err.text());
        return;
    };
    bluez.freeList(app.gpa, app.devices);
    app.devices = new_list;
    if (app.devices.len == 0) {
        app.selected = 0;
    } else if (app.selected >= app.devices.len) {
        app.selected = app.devices.len - 1;
    }
}

/// Re-lists PipeWire sinks, freeing the previous slice first - same
/// ownership shape as `refreshDevices` and for the same reason: this is the
/// one place that reloads `app.sinks`, so every caller (tab entry, `setDefault`)
/// gets the free-before-replace and `sinks_selected` clamp for free instead
/// of having to remember either at its own call site.
///
/// Fix round 2, finding M8: a failure here degrades to an empty `app.sinks`
/// rather than routing through `fail()` - the spec calls for "PipeWire
/// absence degrades the Audio tab to a message; the Devices tab still
/// works", not an error modal blocking the whole app over a tab that has
/// its own honest empty state (`renderAudio`'s "(no audio sinks found)",
/// fix round 1's M2) already built for exactly this.
fn refreshSinks(app: *App) void {
    const new_list: []audio.Sink = audio.sinks(app.gpa) catch &.{};
    audio.freeSinks(app.gpa, app.sinks);
    app.sinks = new_list;
    if (app.sinks.len == 0) {
        app.sinks_selected = 0;
    } else if (app.sinks_selected >= app.sinks.len) {
        app.sinks_selected = app.sinks.len - 1;
    }
}

/// Starts an async pair or connect on the currently-selected device: stops
/// any in-progress scan first (fix round 1, finding I6 - the same
/// InProgress/"br-connection-busy" race applies to `Pair` as much as
/// `Connect`, since both are BlueZ device operations that can collide with
/// discovery on the same adapter), captures `resume_mode`, and enters
/// `.working`. An immediate (synchronous) failure to even issue the call
/// routes through `fail` like every other failure site.
///
/// Safe to call in isolation (final review, finding M4): guards
/// `app.selected` against an empty/out-of-range `app.devices` rather than
/// trusting every caller to have checked first, and releases any `Pending`
/// already sitting in `app.pending` before overwriting it - both
/// preconditions happen to hold at the one call site today, but a helper
/// with "the caller must have already checked" preconditions is exactly how
/// this file's worst bugs have shown up so far.
fn beginAsync(app: *App, kind: PendingKind) void {
    if (app.selected >= app.devices.len) return;
    if (app.pending) |*p| p.deinit();
    app.pending = null;

    const dev = app.devices[app.selected];
    if (app.mode == .scanning) {
        var stop_err = dbus.Error{};
        defer stop_err.deinit();
        bluez.stopScan(app.conn, &stop_err) catch {};
        app.mode = .list;
    }
    const pending = (switch (kind) {
        .pair => bluez.pairAsync(app.conn, dev),
        .connect => bluez.connectAsync(app.conn, dev),
    }) catch |e| {
        fail(app, @errorName(e).ptr);
        return;
    };
    app.pending = pending;
    app.pending_kind = kind;
    app.pending_index = app.selected;
    app.pending_is_audio = dev.isAudio();
    copyAddress(&app.pending_address, dev.address);
    app.pending_retried = false;
    app.retry_scheduled = false;
    captureResumeMode(app);
    app.mode = .working;
}

/// Devices-tab actions: move selection, pair/connect/disconnect, forget,
/// toggle scanning, switch to the audio tab, or exit. Pair and connect are
/// the only non-blocking ones - see `App.pending`/`PendingKind` and
/// `updatePending`.
fn devicesAction(app: *App, btn: ui.Button) void {
    // Fix round 2, finding I5: any button other than a qualifying second
    // `.x` disarms a pending forget-confirmation - covers moving the
    // selection, starting a connect/pair, toggling scan, or switching tabs,
    // all of which mean the user has moved on rather than confirming.
    if (app.forget_armed and btn != .x) app.forget_armed = false;

    switch (btn) {
        .up => {
            if (app.selected > 0) app.selected -= 1;
        },
        .down => {
            if (app.selected + 1 < app.devices.len) app.selected += 1;
        },
        .a => {
            if (app.devices.len == 0) return;
            const dev = app.devices[app.selected];
            if (dev.connected) {
                var err = dbus.Error{};
                defer err.deinit();
                bluez.disconnect(app.conn, dev, &err) catch {
                    fail(app, err.text());
                    return;
                };
                refreshDevices(app);
            } else if (dev.paired) {
                beginAsync(app, .connect);
            } else {
                // Team-lead ruling: pairing has no key of its own - `a` on
                // an unpaired device pairs first, then chains into connect
                // on success (see `updatePending`). The plan's Task 8 action
                // list omitted pairing entirely; this is what actually
                // exercises the Task 4 pairing agent from the UI.
                beginAsync(app, .pair);
            }
        },
        .x => {
            if (app.devices.len == 0) return;
            const dev = app.devices[app.selected];
            const now = c.SDL_GetTicks();
            // Team-lead ruling, finding I5: was one press, no confirmation -
            // on a list that can reorder underneath `selected` every ~500ms
            // during a scan, that let a single stray `X` destroy a real
            // pairing (the exact risk this project went to lengths during
            // testing never to take with the owner's own headset). A second
            // press only commits if it's still armed, for *this* device
            // (address, not index - the list may have reordered since the
            // first press), within the window; anything else (re)arms
            // instead of forgetting.
            const confirmed = app.forget_armed and
                now -% app.forget_armed_at_ms < forget_confirm_window_ms and
                std.mem.eql(u8, std.mem.sliceTo(&app.forget_armed_address, 0), dev.address);
            if (!confirmed) {
                app.forget_armed = true;
                app.forget_armed_at_ms = now;
                copyAddress(&app.forget_armed_address, dev.address);
                const label: [:0]const u8 = if (dev.alias.len == 0) dev.address else dev.alias;
                var buf: [160:0]u8 = undefined;
                const msg: [:0]const u8 = std.fmt.bufPrintZ(&buf, "press X again to forget {s}", .{label}) catch "press X again to forget";
                setStatus(app, msg.ptr);
                return;
            }
            app.forget_armed = false;
            var err = dbus.Error{};
            defer err.deinit();
            bluez.forget(app.conn, dev, &err) catch {
                fail(app, err.text());
                return;
            };
            refreshDevices(app);
        },
        .y => {
            var err = dbus.Error{};
            defer err.deinit();
            if (app.mode == .scanning) {
                bluez.stopScan(app.conn, &err) catch {
                    fail(app, err.text());
                    return;
                };
                app.mode = .list;
            } else {
                bluez.startScan(app.conn, &err) catch {
                    fail(app, err.text());
                    return;
                };
                app.mode = .scanning;
                app.last_refresh_ms = c.SDL_GetTicks();
                refreshDevices(app);
            }
        },
        .b => app.quit = true,
        .r1 => {
            app.tab = .audio;
            refreshSinks(app);
        },
        else => {},
    }
}

/// Audio tab actions: move selection, set the selected sink as default, or
/// return to devices. `setDefault` is best-effort and cannot fail the UI
/// (see `audio.setDefault`'s doc comment), so unlike `devicesAction` there's
/// no error path here to route through `fail` - just a refresh afterwards
/// so the `<- output` marker moves to the new default immediately.
fn audioAction(app: *App, btn: ui.Button) void {
    switch (btn) {
        .up => {
            if (app.sinks_selected > 0) app.sinks_selected -= 1;
        },
        .down => {
            if (app.sinks_selected + 1 < app.sinks.len) app.sinks_selected += 1;
        },
        .a => {
            if (app.sinks_selected >= app.sinks.len) return;
            audio.setDefault(app.sinks[app.sinks_selected]);
            // Fix round 1, finding I2: an explicit user choice here must win
            // over a still-pending auto-route, or `pollAutoRoute` could yank
            // the default back to the just-connected Bluetooth sink a few
            // seconds after the user deliberately picked something else.
            app.awaiting_sink = false;
            refreshSinks(app);
        },
        .l1 => app.tab = .devices,
        .b => app.quit = true,
        else => {},
    }
}

fn handleInput(app: *App, btn: ui.Button) void {
    if (btn == .quit) {
        app.quit = true;
        return;
    }

    if (app.mode == .err) {
        app.mode = app.resume_mode;
        return;
    }

    if (app.mode == .working) {
        // Only cancel-and-back-out is live while a pair or connect is in
        // flight; every other input is ignored rather than risking an
        // action (like starting a scan, which reallocates `app.devices`)
        // against a `Pending` that still references the old device by index.
        if (btn == .b) {
            // Final review, finding I1: `Pending.deinit` only cancels *our*
            // D-Bus call - it tells `bluetoothd` nothing, so a bare cancel
            // here left the device pairing anyway (our own agent, still
            // registered, auto-accepts whatever finishes it in the
            // background). `CancelPairing` actually tells BlueZ to stop.
            // Best-effort: if it fails, `deinit` below still releases our
            // side, and the row will just show whatever state BlueZ landed
            // on once refreshed.
            if (app.pending_kind == .pair and app.pending_index < app.devices.len) {
                var cancel_err = dbus.Error{};
                defer cancel_err.deinit();
                bluez.cancelPairing(app.conn, app.devices[app.pending_index], &cancel_err) catch {
                    _ = c.printf("cancelPairing failed (best-effort): %s\n", cancel_err.text());
                };
            }
            if (app.pending) |*p| p.deinit();
            app.pending = null;
            app.retry_scheduled = false;
            // Finding I2: leaving `.working` must always refresh, not just
            // on connect-success - otherwise a cancelled-but-completed pair
            // leaves the row reading unpaired while BlueZ now disagrees,
            // and `a` re-routes into `Pair` again (AlreadyExists) with no
            // way out except `y`, which the footer doesn't advertise. This
            // path exits `.working` without going through `fail` (the user
            // chose to cancel, nothing failed), so it can't rely on `fail`'s
            // `needs_refresh` flag and refreshes explicitly instead.
            refreshDevices(app);
            if (app.mode == .working) app.mode = app.resume_mode;
        }
        return;
    }

    switch (app.tab) {
        .devices => devicesAction(app, btn),
        .audio => audioAction(app, btn),
    }
}

/// Polls the in-flight `Pair`/`Connect`, and drives the one-shot retry for a
/// transient `InProgress`/"br-connection-busy" failure. Never blocks: it
/// only acts when `pending.done()` is already true, or when the retry delay
/// has elapsed. A successful `Pair` chains straight into a `Connect`
/// (`pending_kind` flips from `.pair` to `.connect`, `mode` stays
/// `.working`) rather than returning to the caller - see the team-lead
/// ruling in `devicesAction`'s `.a` handler.
fn updatePending(app: *App) void {
    if (app.mode != .working) return;
    const ticks = c.SDL_GetTicks();

    if (app.pending) |*p| {
        if (!p.done()) return;
        const reply = p.take();
        // Final review, finding M1: `take()` was hardened to return null
        // rather than assert/abort when the call it's asked to steal from
        // isn't actually complete (see the live `Pending.deinit` crash this
        // project already hit once) - but that only matters if this caller
        // actually honours it. `done()` just returned true above, so
        // `p.call` should already be null here; if it somehow isn't, this
        // was called too early and the `Pending` is still live and owned -
        // leave it alone and retry next frame rather than dropping it via
        // an unconditional `app.pending = null`, which would leak the
        // underlying `DBusPendingCall`.
        if (p.call != null) return;
        app.pending = null;

        const r = reply orelse {
            fail(app, "no reply");
            return;
        };
        defer dbus.c.dbus_message_unref(r);

        if (dbus.errorName(r)) |name| {
            const detail = replyErrorText(r);
            if (!app.pending_retried and isTransient(name, detail)) {
                app.pending_retried = true;
                app.retry_scheduled = true;
                // Finding M5: unchecked `u32` add is UB at the tick
                // rollover under ReleaseSmall (no overflow trap). `+%`
                // makes the wraparound defined instead of relying on
                // whatever LLVM happens to emit for the checked op.
                app.retry_at_ms = ticks +% connect_retry_delay_ms;
            } else {
                fail(app, detail);
            }
            return;
        }

        // Success.
        switch (app.pending_kind) {
            .pair => {
                // Team-lead ruling: pairing chains straight into connect.
                // Trust it first so it reconnects on its own later without
                // this app running - best-effort, since trust is a
                // convenience, not a precondition for the connect that
                // follows, so its failure doesn't stop the chain.
                const dev = app.devices[app.pending_index];
                var trust_err = dbus.Error{};
                defer trust_err.deinit();
                bluez.setTrusted(app.conn, dev, true, &trust_err) catch {
                    _ = c.printf("setTrusted failed (continuing to connect anyway): %s\n", trust_err.text());
                };
                const pending2 = bluez.connectAsync(app.conn, dev) catch |e| {
                    // The device is genuinely paired now even though this
                    // connect attempt never got off the ground; `fail`
                    // itself flags the refresh (see its doc comment) rather
                    // than doing it here directly.
                    fail(app, @errorName(e).ptr);
                    return;
                };
                app.pending = pending2;
                app.pending_kind = .connect;
                app.pending_retried = false;
                // Stays `.working` - a pair-then-connect chain, not done yet.
            },
            .connect => {
                refreshDevices(app);
                if (app.mode == .working) app.mode = app.resume_mode;
                // Task 9 auto-route: arm the wait rather than polling here
                // directly - this function only runs when a `Pending` just
                // completed, but the sink can take a moment to appear after
                // BlueZ reports the connect done, so the actual polling
                // happens once per frame in `pollAutoRoute` for up to
                // `audio_route_timeout_ms` regardless of what else the user
                // does in the meantime. `pending_address` was already
                // captured in `beginAsync`.
                if (app.pending_is_audio) {
                    app.awaiting_sink = true;
                    app.awaiting_sink_started_ms = ticks;
                    app.awaiting_sink_last_poll_ms = ticks;
                }
            },
        }
        return;
    }

    if (app.retry_scheduled and ticks >= app.retry_at_ms) {
        app.retry_scheduled = false;
        const dev = app.devices[app.pending_index];
        app.pending = (switch (app.pending_kind) {
            .pair => bluez.pairAsync(app.conn, dev),
            .connect => bluez.connectAsync(app.conn, dev),
        }) catch |e| {
            fail(app, @errorName(e).ptr);
            return;
        };
    }
}

/// Builds the PipeWire node-name prefix BlueZ derives from a device's own
/// address - `bluez_output.` followed by the MAC with `:` replaced by `_`
/// (see audio.zig's parseSinks test data: address `4C:87:5D:FD:3E:42` names
/// the sink `bluez_output.4C_87_5D_FD_3E_42.1`). Writes into `buf` and
/// returns the written slice, or null if it doesn't fit (never in practice
/// at this buffer size, but a bad match is worse than no match).
fn bluezSinkPrefix(buf: []u8, address: []const u8) ?[]u8 {
    const prefix = "bluez_output.";
    if (prefix.len + address.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    for (address, 0..) |ch, i| {
        buf[prefix.len + i] = if (ch == ':') '_' else ch;
    }
    return buf[0 .. prefix.len + address.len];
}

/// Case-insensitive prefix match - BlueZ's own casing for the hex in a sink
/// name has not been confirmed against `bluez.Device.address`'s casing, so
/// the comparison can't assume they agree.
fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |ch, i| {
        if (std.ascii.toUpper(haystack[i]) != std.ascii.toUpper(ch)) return false;
    }
    return true;
}

/// Non-blocking half of Task 9's auto-route: called once per frame from the
/// main loop. Does nothing most frames (either no route is pending, or the
/// last `pw-dump` check was too recent) - it only actually shells out at
/// most once every `audio_poll_interval_ms`, computed with wrap-safe `-%`
/// subtraction throughout (matching `updatePending`'s `retry_at_ms` - Task 9
/// fix round 1, finding M3) rather than a plain `-`/`>=` that could trap or
/// misbehave right at the `SDL_GetTicks` rollover.
///
/// Matches sinks against `app.pending_address` (the device that was just
/// connected) rather than taking the first Bluetooth sink found: fix round
/// 1, finding I3 (team-lead ruling) - with two Bluetooth audio devices
/// around, an unrelated pre-existing sink taking the very first poll would
/// silently strand the device the user just connected, which is exactly the
/// "connected but silent" bug this project exists to fix. Once
/// `audio_route_timeout_ms` has elapsed with no address match, it falls
/// back to any Bluetooth sink once - a naming scheme this match doesn't
/// recognise still degrades to the brief's original behaviour instead of
/// failing shut.
///
/// A `pw-dump` failure is treated the same as "no Bluetooth sink yet" and
/// retried on the next tick rather than routed through `fail`: this runs in
/// the background while the user may be doing anything else in the UI, and
/// a transient PipeWire hiccup here shouldn't pop an error modal over
/// whatever they're looking at. A successful route doesn't refresh
/// `app.sinks` directly either (fix round 1, finding I1) - it sets
/// `needs_sink_refresh` for the frame loop to pick up, the same structural
/// pattern `fail` already uses for `needs_refresh`.
fn pollAutoRoute(app: *App) void {
    if (!app.awaiting_sink) return;
    const ticks = c.SDL_GetTicks();
    const elapsed = ticks -% app.awaiting_sink_started_ms;
    const expired = elapsed >= audio_route_timeout_ms;

    if (!expired and ticks -% app.awaiting_sink_last_poll_ms < audio_poll_interval_ms) return;
    app.awaiting_sink_last_poll_ms = ticks;

    const list = audio.sinks(app.gpa) catch {
        if (expired) app.awaiting_sink = false;
        return;
    };
    defer audio.freeSinks(app.gpa, list);

    const address = std.mem.sliceTo(&app.pending_address, 0);
    var prefix_buf: [48]u8 = undefined;
    const prefix = bluezSinkPrefix(&prefix_buf, address);

    var fallback: ?audio.Sink = null;
    for (list) |s| {
        if (!s.is_bluetooth) continue;
        if (fallback == null) fallback = s;
        if (prefix) |p| {
            if (startsWithIgnoreCase(s.name, p)) {
                audio.setDefault(s);
                app.awaiting_sink = false;
                app.needs_sink_refresh = true;
                return;
            }
        }
    }

    if (expired) {
        if (fallback) |s| {
            audio.setDefault(s);
            app.needs_sink_refresh = true;
        }
        app.awaiting_sink = false;
    }
}

fn renderDevices(app: *App) void {
    const state_text: [:0]const u8 = switch (app.mode) {
        .list => "Ready",
        .scanning => "Scanning...",
        .working => if (app.pending_kind == .pair) "Pairing..." else "Connecting...",
        .err => "Error",
    };
    ui.text(app.ui, 8, 8, "Bluetooth", app.pal.fg);

    // Fix round 2, finding I5: while a forget is armed and still inside its
    // confirmation window, this replaces the ordinary state line with the
    // prompt `.x`'s handler wrote into `app.status` (the same scratch
    // buffer `fail`/`setStatus` use - guarded against `.err` below so an
    // unrelated failure's text, which also lives there, can't get shown
    // twice). Recomputing the window check here rather than trusting
    // `app.forget_armed` alone means the prompt actually disappears once
    // the window lapses, even if the user does nothing at all.
    const now = c.SDL_GetTicks();
    const show_forget_confirm = app.forget_armed and app.mode != .err and
        now -% app.forget_armed_at_ms < forget_confirm_window_ms;
    if (show_forget_confirm) {
        ui.text(app.ui, 8, 32, std.mem.sliceTo(&app.status, 0), app.pal.accent);
    } else {
        ui.text(app.ui, 8, 32, state_text, app.pal.dim);
    }

    // Clip to however many rows actually fit above the footer, scrolling
    // just enough to keep `selected` in view - a scan can return more
    // devices (task-4-report.md saw 11) than the 640x480 screen has room
    // for at row_height 28.
    const footer_h: c_int = 32;
    const rows_c: c_int = @divTrunc(ui.screen_h - ui.list_origin_y - footer_h, ui.row_height);
    const max_rows: usize = if (rows_c > 0) @intCast(rows_c) else 0;

    var offset: usize = 0;
    if (max_rows > 0 and app.selected >= max_rows) offset = app.selected - max_rows + 1;
    const end = @min(app.devices.len, offset + max_rows);

    for (app.devices[offset..end], 0..) |d, i| {
        const left: [:0]const u8 = if (d.alias.len == 0) d.address else d.alias;
        const right: [:0]const u8 = if (d.connected) "connected" else if (d.paired) "paired" else "";
        ui.listRow(app.ui, i, offset + i == app.selected, left, right, app.pal);
    }

    // Fix round 2, findings I6/M11: `R1` (the entire "connected but
    // silent" fix - the reason this project exists) was missing from this
    // line entirely, and `A`/`X`/`Y` stayed listed even while `.working`
    // ignores all three (see `handleInput`'s `.working` branch - only `.b`
    // is live there).
    const footer_text: [:0]const u8 = if (app.mode == .working)
        "B cancel"
    else
        "A connect/pair  X forget  Y scan  R1 audio  B exit";
    ui.text(app.ui, 8, ui.screen_h - 24, footer_text, app.pal.dim);
}

/// Audio tab: lists PipeWire sinks (`audio.sinks`, held in `app.sinks`),
/// marking the current default with a trailing `<- output` (an ASCII arrow
/// rather than a Unicode glyph - the theme font's glyph coverage for `←`
/// hasn't been checked on the real device, and this can't be visually
/// verified until the owner runs the interactive UI). Scrolls the same way
/// `renderDevices` does, clamped to however many rows fit above the footer.
fn renderAudio(app: *App) void {
    ui.text(app.ui, 8, 8, "Audio", app.pal.fg);

    // Fix round 1, finding M2: without this, an empty sink list (e.g.
    // `pw-dump` briefly returning nothing) rendered as a bare heading and
    // footer with dead space between them - indistinguishable from a UI
    // that's broken rather than one that's honestly reporting "nothing
    // here". `renderDevices` has an analogous always-on state line; this
    // only needs to appear in the one case that would otherwise look wrong.
    if (app.sinks.len == 0) {
        ui.text(app.ui, 8, ui.list_origin_y, "(no audio sinks found)", app.pal.dim);
    }

    const footer_h: c_int = 32;
    const rows_c: c_int = @divTrunc(ui.screen_h - ui.list_origin_y - footer_h, ui.row_height);
    const max_rows: usize = if (rows_c > 0) @intCast(rows_c) else 0;

    var offset: usize = 0;
    if (max_rows > 0 and app.sinks_selected >= max_rows) offset = app.sinks_selected - max_rows + 1;
    const end = @min(app.sinks.len, offset + max_rows);

    for (app.sinks[offset..end], 0..) |s, i| {
        // `s.description` comes from parseSinks' plain `gpa.dupe` (see
        // audio.zig) - not null-terminated, unlike bluez.Device's fields -
        // so it has to be copied through a null-terminated stack buffer
        // before it can go through `ui.listRow`. A description this long
        // would already run off a 640px-wide row, so silent truncation on
        // overflow is an acceptable fallback rather than a real loss.
        var desc_buf: [96:0]u8 = undefined;
        const desc: [:0]const u8 = std.fmt.bufPrintZ(&desc_buf, "{s}", .{s.description}) catch "(name too long)";
        const right: [:0]const u8 = if (s.is_default) "<- output" else "";
        ui.listRow(app.ui, i, offset + i == app.sinks_selected, desc, right, app.pal);
    }

    ui.text(app.ui, 8, ui.screen_h - 24, "A set as output  L1 devices  B exit", app.pal.dim);
}

/// BlueZ's own error text (`err.text()` / a reply's detail string) is
/// already user-legible, so it's shown verbatim - see the task-4 defect this
/// guards against: surfacing just `@errorName` and discarding the real
/// reason.
///
/// Fix round 1 (task-8-review.md finding I3): the modal previously drew
/// straight over the list with no backdrop - glyphs over glyphs, including
/// a selected row's filled accent band. A bordered panel in `pal.bg` behind
/// the text is the actual fix; `pal.accent` border makes it read as a
/// distinct panel rather than a color-matched cutout of the background.
fn renderErrorModal(app: *App) void {
    const x: c_int = 16;
    const y: c_int = 190;
    const w: c_int = ui.screen_w - 32;
    const h: c_int = 100;
    ui.fillRect(app.ui, x - 2, y - 2, w + 4, h + 4, app.pal.accent);
    ui.fillRect(app.ui, x, y, w, h, app.pal.bg);

    ui.text(app.ui, x + 8, y + 10, "ERROR", app.pal.accent);
    // Fix round 2, finding M2: `&app.status` is always the full 128-byte
    // array regardless of content, so `ui.hasText`'s zero-length check
    // (meant to skip TTF_RenderUTF8_Blended's "zero width" failure on a
    // genuinely empty string) could never actually see an empty status this
    // way. `sliceTo` finds the real, null-terminated length instead.
    ui.text(app.ui, x + 8, y + 38, std.mem.sliceTo(&app.status, 0), app.pal.fg);
    ui.text(app.ui, x + 8, y + 66, "press any button to continue", app.pal.dim);
}

fn render(app: *App) void {
    ui.beginFrame(app.ui, app.pal);
    switch (app.tab) {
        .devices => renderDevices(app),
        .audio => renderAudio(app),
    }
    if (app.mode == .err) renderErrorModal(app);
    ui.endFrame(app.ui);
}

/// The interactive screen: this is what a bare `btui` invocation (no dev
/// flags) now runs. Registers the pairing agent best-effort (a failure here
/// still leaves reconnect/forget/scan usable, so it doesn't abort startup),
/// then loops pump -> input -> pending/retry -> periodic scan refresh ->
/// render until the user exits.
fn runUi(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    const font_path = testFontPath(gpa) orelse return error.NoFont;
    defer gpa.free(font_path);

    const sdl_ui = try ui.init(font_path);
    defer ui.deinit(sdl_ui);

    bluez.registerAgent(conn) catch |e| {
        _ = c.printf("agent registration failed: %s\n", @errorName(e).ptr);
    };

    // Fix round 1, RULING I5: bring the adapter up best-effort. A fresh boot
    // commonly has Bluetooth powered off, in which case `list` comes back
    // empty and every action fails with an error the user has no way to
    // resolve from inside the app - the spec's self-sufficiency clause means
    // the app should recover from that itself rather than defer it to
    // packaging (Task 10). Best-effort per the ruling: a failure here is
    // logged but does not stop the UI from starting.
    var poweron_err = dbus.Error{};
    defer poweron_err.deinit();
    bluez.powerOn(conn, &poweron_err) catch {
        _ = c.printf("power on failed: %s\n", poweron_err.text());
    };

    var app = App{
        .gpa = gpa,
        .conn = conn,
        .ui = sdl_ui,
        .pal = theme.palette(),
    };
    // These four `defer`s run last-declared-first-executed (LIFO), i.e. the
    // reverse of the order they're written in below: sinks are freed first,
    // then the device list, then discovery is stopped if it's still
    // running, and only then is the still-live `pending` cancelled last -
    // fix round 2, finding M6 (this comment previously described the
    // opposite order, matching declaration order instead of actual
    // execution order).
    defer if (app.pending) |*p| p.deinit();
    // Fix round 1, finding I4 (widened by fix round 2, finding G2 - see
    // `isScanning`): without this, quitting while discovery is still
    // running (or ought to still be, from the error-modal case) leaves
    // BlueZ discovering indefinitely after btui exits - battery drain, and
    // a state muOS's frontend may not expect. Best-effort: nothing useful
    // to do with a failure here on the way out.
    defer if (isScanning(&app)) {
        var stop_err = dbus.Error{};
        defer stop_err.deinit();
        bluez.stopScan(conn, &stop_err) catch {};
    };
    defer bluez.freeList(gpa, app.devices);
    defer audio.freeSinks(gpa, app.sinks);

    var initial_list_err = dbus.Error{};
    defer initial_list_err.deinit();
    app.devices = bluez.list(gpa, conn, &initial_list_err) catch blk: {
        fail(&app, initial_list_err.text());
        break :blk &.{};
    };

    while (!app.quit) {
        // Structural half of finding I2's fix: `fail` flags this instead of
        // refreshing directly, so every current and future exit from
        // `.working` via failure gets one, without each call site having to
        // remember to ask for it. Checked first, before this frame's own
        // input/pending handling, so the row is never stale for a frame
        // longer than it has to be.
        if (app.needs_refresh) {
            app.needs_refresh = false;
            refreshDevices(&app);
        }
        // Fix round 1, finding I1: `pollAutoRoute` (below) can complete a
        // route while the audio tab is already open, showing the stale
        // pre-route snapshot until something else happened to refresh it -
        // this is the audio-tab counterpart to `needs_refresh` above, and
        // is what actually corrects that.
        if (app.needs_sink_refresh) {
            app.needs_sink_refresh = false;
            refreshSinks(&app);
        }

        conn.pump();

        while (ui.poll(app.ui)) |btn| {
            handleInput(&app, btn);
        }

        updatePending(&app);
        pollAutoRoute(&app);

        if (app.mode == .scanning) {
            const ticks = c.SDL_GetTicks();
            // Fix round 2, finding M1: `-%` matches the wrap-safety already
            // used everywhere else timestamps are subtracted in this file
            // (`retry_at_ms`, `pollAutoRoute`'s `-%` throughout) - a plain
            // `-` here traps under ReleaseSafe/Debug at the tick rollover.
            if (ticks -% app.last_refresh_ms >= scan_refresh_ms) {
                refreshDevices(&app);
                app.last_refresh_ms = ticks;
            }
        }

        render(&app);
        c.SDL_Delay(16);
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    // Fix round 2, finding I4: stdout is only line-buffered when it's a tty;
    // under muOS packaging (no tty at all) it's fully buffered by default,
    // so every `c.printf` diagnostic in this file - not just the
    // agent-callback logging `bluez.zig` already flushes explicitly at each
    // call site - is lost on a crash or `kill`, exactly the failure that
    // logging was fixed for, but as an invariant here instead of a
    // per-site fix. Set once, before anything else runs, so it covers every
    // mode this binary can be invoked in, not just the interactive UI.
    _ = c.setvbuf(c.stdout, null, c._IOLBF, 0);

    const gpa = std.heap.page_allocator;

    // SDL/UI test modes are self-contained and deliberately checked before
    // the D-Bus connect below: Step 1 of Task 7 proves a window opens at all,
    // independent of anything else in the program.
    if (hasFlag(init.args, "--window-test")) {
        ui.windowTest() catch |e| {
            _ = c.printf("window test failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (hasFlag(init.args, "--input-test")) {
        const font_path = testFontPath(gpa) orelse return;
        defer gpa.free(font_path);
        ui.inputTest(font_path, 20_000) catch |e| {
            _ = c.printf("input test failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (hasFlag(init.args, "--ui-test")) {
        const font_path = testFontPath(gpa) orelse return;
        defer gpa.free(font_path);
        ui.uiTest(font_path, gpa, 8_000) catch |e| {
            _ = c.printf("ui test failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    var err = dbus.Error{};
    const conn = dbus.connectSystem(&err) catch {
        _ = c.printf("bus connect failed: %s\n", err.text());
        return;
    };

    if (hasFlag(init.args, "--dump")) {
        dumpMode(gpa, conn) catch |e| {
            _ = c.printf("dump failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (hasFlag(init.args, "--scan")) {
        scanMode(gpa, conn) catch |e| {
            _ = c.printf("scan failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (flagValue(init.args, "--connect")) |address| {
        connectMode(gpa, conn, address) catch |e| {
            _ = c.printf("connect failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (flagValue(init.args, "--forget")) |address| {
        forgetMode(gpa, conn, address) catch |e| {
            _ = c.printf("forget failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    if (hasFlag(init.args, "--agent")) {
        agentMode(conn) catch |e| {
            _ = c.printf("agent failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    // No dev flag matched: this is the real entry point muOS launches with
    // no arguments at all.
    runUi(gpa, conn) catch |e| {
        _ = c.printf("ui failed: %s\n", @errorName(e).ptr);
    };
}
