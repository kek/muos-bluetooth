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

/// `--dump` is the project's main development feedback loop: it prints the
/// device list over SSH with no UI involved.
fn dumpMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);
    printDevices(devices);
}

/// Starts discovery, gives the adapter a few seconds to hear back from
/// nearby devices, then stops and prints the device list like `--dump`.
fn scanMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    try bluez.startScan(conn);
    _ = c.sleep(8);
    try bluez.stopScan(conn);

    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);
    printDevices(devices);
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
    try bluez.forget(conn, dev);

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

    _ = c.printf("connected to system bus\n");
}
