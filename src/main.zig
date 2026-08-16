// btui - Bluetooth manager for muOS. Entry point and mode dispatch.
const std = @import("std");
const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
    @cInclude("dbus/dbus.h");
    @cInclude("stdio.h");
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

/// `--dump` is the project's main development feedback loop: it prints the
/// device list over SSH with no UI involved.
fn dumpMode(gpa: std.mem.Allocator, conn: dbus.Connection) !void {
    const devices = try bluez.list(gpa, conn);
    defer bluez.freeList(gpa, devices);
    _ = c.printf("devices: %d\n", @as(c_int, @intCast(devices.len)));
    for (devices) |d| {
        _ = c.printf("  %-18s %-24s paired=%d connected=%d icon=%s\n", d.address.ptr, d.alias.ptr, @as(c_int, @intFromBool(d.paired)), @as(c_int, @intFromBool(d.connected)), d.icon.ptr);
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var err = dbus.Error{};
    const conn = dbus.connectSystem(&err) catch {
        _ = c.printf("bus connect failed: %s\n", err.text());
        return;
    };

    if (hasFlag(init.args, "--dump")) {
        dumpMode(std.heap.page_allocator, conn) catch |e| {
            _ = c.printf("dump failed: %s\n", @errorName(e).ptr);
        };
        return;
    }

    _ = c.printf("connected to system bus\n");
}
