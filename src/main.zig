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

/// `--dump` is the project's main development feedback loop: it prints the
/// device list over SSH with no UI involved.
fn dumpMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);
    printDevices(devices);
    printSinks(gpa);
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

pub fn main(init: std.process.Init.Minimal) void {
    var err = dbus.Error{};
    const conn = dbus.connectSystem(&err) catch {
        _ = c.printf("bus connect failed: %s\n", err.text());
        return;
    };
    const gpa = std.heap.page_allocator;

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

    _ = c.printf("connected to system bus\n");
}
