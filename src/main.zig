// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("dbus/dbus.h");
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
    const devices = try bluez.list(gpa, conn);
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

    const devices = try bluez.list(gpa, conn);
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
    const devices = try bluez.list(gpa, conn);
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

    const after = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, after);
    printDevices(after);
}

/// Implemented and code-reviewed but deliberately never run against a real
/// address: see Ruling B in the task-4 brief - the device's paired headset
/// can only be re-paired with physical access we don't have.
fn forgetMode(gpa: std.mem.Allocator, conn: dbus.Connection, address: []const u8) !void {
    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);

    const dev = findByAddress(devices, address) orelse {
        _ = c.printf("no device with address %s\n", address.ptr);
        return;
    };

    var err = dbus.Error{};
    defer err.deinit();
    bluez.forget(conn, dev, &err) catch |e| {
        _ = c.printf("forget failed: %s (%s)\n", @errorName(e).ptr, err.text());
        return;
    };

    const after = try bluez.list(gpa, conn);
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

const scan_refresh_ms: u32 = 500;
const connect_retry_delay_ms: u32 = 1000;

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

    pending: ?dbus.Pending = null,
    pending_index: usize = 0,
    pending_is_audio: bool = false,
    pending_retried: bool = false,
    retry_scheduled: bool = false,
    retry_at_ms: u32 = 0,

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

/// Re-lists devices, freeing the previous slice first - the hot allocation
/// path (Task 8 brief: this runs every ~500ms while scanning) - and clamps
/// `selected` so it never points past the end of a shrunk list (e.g. after
/// `forget`).
fn refreshDevices(app: *App) void {
    const new_list = bluez.list(app.gpa, app.conn) catch |e| {
        setStatus(app, @errorName(e).ptr);
        app.mode = .err;
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

/// Devices-tab actions: move selection, connect/disconnect, forget, toggle
/// scanning, switch to the audio tab, or exit. Connect is the only
/// non-blocking one - see `App.pending` and `updatePending`.
fn devicesAction(app: *App, btn: ui.Button) void {
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
                    setStatus(app, err.text());
                    app.mode = .err;
                    return;
                };
                refreshDevices(app);
            } else {
                const pending = bluez.connectAsync(app.conn, dev) catch |e| {
                    setStatus(app, @errorName(e).ptr);
                    app.mode = .err;
                    return;
                };
                app.pending = pending;
                app.pending_index = app.selected;
                app.pending_is_audio = dev.isAudio();
                app.pending_retried = false;
                app.retry_scheduled = false;
                app.resume_mode = app.mode;
                app.mode = .working;
            }
        },
        .x => {
            if (app.devices.len == 0) return;
            const dev = app.devices[app.selected];
            var err = dbus.Error{};
            defer err.deinit();
            bluez.forget(app.conn, dev, &err) catch {
                setStatus(app, err.text());
                app.mode = .err;
                return;
            };
            refreshDevices(app);
        },
        .y => {
            var err = dbus.Error{};
            defer err.deinit();
            if (app.mode == .scanning) {
                bluez.stopScan(app.conn, &err) catch {
                    setStatus(app, err.text());
                    app.mode = .err;
                    return;
                };
                app.mode = .list;
            } else {
                bluez.startScan(app.conn, &err) catch {
                    setStatus(app, err.text());
                    app.mode = .err;
                    return;
                };
                app.mode = .scanning;
                app.last_refresh_ms = c.SDL_GetTicks();
                refreshDevices(app);
            }
        },
        .b => app.quit = true,
        .r1 => app.tab = .audio,
        else => {},
    }
}

/// Audio tab is Task 9's job (rendering sinks, setting the default output).
/// This stub only owns tab navigation so a user who presses `r1` from the
/// devices tab isn't stranded on a blank screen before Task 9 lands.
fn audioAction(app: *App, btn: ui.Button) void {
    switch (btn) {
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
        // Only cancel-and-back-out is live while a connect is in flight;
        // every other input is ignored rather than risking an action (like
        // starting a scan, which reallocates `app.devices`) against a
        // `Pending` that still references the old device by index.
        if (btn == .b) {
            if (app.pending) |*p| p.deinit();
            app.pending = null;
            app.retry_scheduled = false;
            app.mode = app.resume_mode;
        }
        return;
    }

    switch (app.tab) {
        .devices => devicesAction(app, btn),
        .audio => audioAction(app, btn),
    }
}

/// Polls the in-flight `Connect`, and drives the one-shot retry for a
/// transient `InProgress`/"br-connection-busy" failure. Never blocks: it
/// only acts when `pending.done()` is already true, or when the retry delay
/// has elapsed.
fn updatePending(app: *App) void {
    if (app.mode != .working) return;
    const ticks = c.SDL_GetTicks();

    if (app.pending) |*p| {
        if (!p.done()) return;
        const reply = p.take();
        app.pending = null;

        const r = reply orelse {
            setStatus(app, "no reply");
            app.mode = .err;
            return;
        };
        defer dbus.c.dbus_message_unref(r);

        if (dbus.errorName(r)) |name| {
            const detail = replyErrorText(r);
            if (!app.pending_retried and isTransient(name, detail)) {
                app.pending_retried = true;
                app.retry_scheduled = true;
                app.retry_at_ms = ticks + connect_retry_delay_ms;
            } else {
                setStatus(app, detail);
                app.mode = .err;
            }
            return;
        }

        // Success. TODO(Task 9): when app.pending_is_audio, poll
        // audio.sinks for up to 5s for a bluetooth sink and audio.setDefault
        // it here - the auto-routing behaviour from the task-9 brief.
        refreshDevices(app);
        if (app.mode == .working) app.mode = app.resume_mode;
        return;
    }

    if (app.retry_scheduled and ticks >= app.retry_at_ms) {
        app.retry_scheduled = false;
        const dev = app.devices[app.pending_index];
        app.pending = bluez.connectAsync(app.conn, dev) catch |e| {
            setStatus(app, @errorName(e).ptr);
            app.mode = .err;
            return;
        };
    }
}

fn renderDevices(app: *App) void {
    const state_text: [:0]const u8 = switch (app.mode) {
        .list => "Ready",
        .scanning => "Scanning...",
        .working => "Connecting...",
        .err => "Error",
    };
    ui.text(app.ui, 8, 8, "Bluetooth", app.pal.fg);
    ui.text(app.ui, 8, 32, state_text, app.pal.dim);

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

    ui.text(app.ui, 8, ui.screen_h - 24, "A connect  X forget  Y scan  B exit", app.pal.dim);
}

/// Placeholder for the audio tab - Task 9 replaces this with the real sink
/// list and default-output marker.
fn renderAudioStub(app: *App) void {
    ui.text(app.ui, 8, 8, "Audio", app.pal.fg);
    ui.text(app.ui, 8, ui.list_origin_y, "(audio tab: Task 9)", app.pal.dim);
    ui.text(app.ui, 8, ui.screen_h - 24, "L1 devices  B exit", app.pal.dim);
}

/// BlueZ's own error text (`err.text()` / a reply's detail string) is
/// already user-legible, so it's shown verbatim - see the task-4 defect this
/// guards against: surfacing just `@errorName` and discarding the real
/// reason.
fn renderErrorModal(app: *App) void {
    ui.text(app.ui, 8, 200, "ERROR", app.pal.accent);
    ui.text(app.ui, 8, 228, &app.status, app.pal.fg);
    ui.text(app.ui, 8, 256, "press any button to continue", app.pal.dim);
}

fn render(app: *App) void {
    ui.beginFrame(app.ui, app.pal);
    switch (app.tab) {
        .devices => renderDevices(app),
        .audio => renderAudioStub(app),
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

    var app = App{
        .gpa = gpa,
        .conn = conn,
        .ui = sdl_ui,
        .pal = theme.palette(),
    };
    // Runs last-declared-first-executed (LIFO): pending is cancelled before
    // the device list it may still reference by index is freed.
    defer if (app.pending) |*p| p.deinit();
    defer bluez.freeList(gpa, app.devices);

    app.devices = bluez.list(gpa, conn) catch |e| blk: {
        setStatus(&app, @errorName(e).ptr);
        app.mode = .err;
        break :blk &.{};
    };

    while (!app.quit) {
        conn.pump();

        while (ui.poll(app.ui)) |btn| {
            handleInput(&app, btn);
        }

        updatePending(&app);

        if (app.mode == .scanning) {
            const ticks = c.SDL_GetTicks();
            if (ticks - app.last_refresh_ms >= scan_refresh_ms) {
                refreshDevices(&app);
                app.last_refresh_ms = ticks;
            }
        }

        render(&app);
        c.SDL_Delay(16);
    }
}

pub fn main(init: std.process.Init.Minimal) void {
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
